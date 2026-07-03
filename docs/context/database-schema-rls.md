# Context Doc: Database Schema & RLS

_Last verified: 2026-06-18 (against `priv/repo/structure.sql`)_

## Status
Live. Schema below is regenerated from `priv/repo/structure.sql`. The RLS / Ecto enforcement model is current.

## What This Is
The PostgreSQL schema (encrypted-at-rest, multi-vault, uuidv7 PKs) with Row-Level Security policies and the Ecto integration strategy for tenant isolation.

## Schema — Key Facts (these differ from older drafts)

- **PKs are `uuid DEFAULT uuidv7()`** — NOT BIGSERIAL/BIGINT. All FKs are `uuid`. (Prod was migrated off integer PKs; see `docs/context/pg18-uuidv7-prod-crashloop-2026-06-11.md`.)
- **Timestamp column is `created_at`** on most tables (a few OAuth/device tables still use `inserted_at` — noted inline).
- **Plaintext columns are GONE.** `notes`/`attachments`/`vaults` store `*_ciphertext` + `*_nonce` (AES-GCM) for the value, plus `*_hmac` for the columns that must be searchable/uniquely-indexed (path, folder, tags). There is no `path`/`title`/`content`/`folder`/`tags` plaintext column anywhere. See `docs/context/encryption-operations.md`.
- **`vaults` table + `vault_id` FK** — a user can have multiple vaults; `notes`/`chunks`/`attachments` are scoped by both `user_id` and `vault_id`.
- **~28 tables total** (full list below). The four-table sketch in older drafts was fiction.

### Full table list (`priv/repo/structure.sql`)

`api_key_vaults`, `api_keys`, `attachments`, `chunks`, `client_logs`, `client_origin_stats`, `device_authorizations`, `device_refresh_tokens`, `email_suppressions`, `instance_settings`, `invites`, `notes`, `oauth_authorization_codes`, `oauth_clients`, `oauth_refresh_tokens`, `oban_jobs`, `password_reset_tokens`, `plans`, `refresh_tokens`, `storage_objects`, `subscriptions`, `system_canaries`, `terms_versions`, `usage_meters`, `user_agreements`, `user_limit_overrides`, `users`, `vaults`.

### Core tables (verbatim shape from structure.sql)

```sql
-- structure.sql:556
CREATE TABLE public.users (
    id uuid DEFAULT uuidv7() NOT NULL,
    email text NOT NULL,
    display_name text,
    created_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    external_id text,                 -- Clerk user id (SaaS)
    plan_id uuid,
    password_hash character varying(255),
    role character varying(255) DEFAULT 'member' NOT NULL,
    encrypted_dek bytea,              -- per-user DEK, wrapped by master key / KMS CMK
    dek_version integer DEFAULT 1 NOT NULL,
    key_provider character varying(255) DEFAULT 'local' NOT NULL,
    dek_rotation_locked_at timestamp without time zone,
    normalized_email text,
    phone_verified_at timestamp without time zone,
    deleted_at timestamp without time zone,
    inactivity_warning_60_at timestamp without time zone,
    inactivity_warning_80_at timestamp without time zone,
    suspended_at timestamp with time zone
);

-- structure.sql:583  (multi-vault — name is encrypted, hmac for lookup)
CREATE TABLE public.vaults (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    description text,
    slug text NOT NULL,
    client_id text,
    is_default boolean DEFAULT false NOT NULL,
    deleted_at timestamp(0) without time zone,
    created_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    name_ciphertext bytea NOT NULL,
    name_nonce bytea NOT NULL,
    name_hmac bytea NOT NULL,
    dek_version integer DEFAULT 1 NOT NULL
);

-- structure.sql:229  (encrypted at rest; path/folder/tags also HMAC'd for indexing;
-- only the frontmatter dates fm_timestamp/fm_created are stored plaintext, for range
-- queries -- OKF wave 2026-07-02; type is encrypted + type_hmac blind index,
-- description/resource encrypted display-only)
CREATE TABLE public.notes (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    vault_id uuid NOT NULL,
    version integer DEFAULT 1 NOT NULL,       -- server-controlled, optimistic concurrency
    content_hash text,                         -- hash of plaintext, skip-if-unchanged on sync
    embed_hash text,                           -- content_hash at last successful embed (idempotency)
    mtime double precision,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    content_ciphertext bytea NOT NULL, content_nonce bytea NOT NULL,
    title_ciphertext bytea NOT NULL,   title_nonce bytea NOT NULL,
    tags_ciphertext bytea NOT NULL,    tags_nonce bytea NOT NULL,
    path_ciphertext bytea NOT NULL,    path_nonce bytea NOT NULL,    path_hmac bytea NOT NULL,
    folder_ciphertext bytea NOT NULL,  folder_nonce bytea NOT NULL,  folder_hmac bytea NOT NULL,
    tags_hmac bytea[] DEFAULT ARRAY[]::bytea[],  -- one HMAC per tag, GIN-indexed
    dek_version integer DEFAULT 1 NOT NULL
);

-- structure.sql:99  (chunk metadata; vectors + contextualized text live in Qdrant)
CREATE TABLE public.chunks (
    id uuid DEFAULT uuidv7() NOT NULL,
    note_id uuid NOT NULL,
    user_id uuid NOT NULL,
    vault_id uuid NOT NULL,
    "position" smallint NOT NULL,
    heading_path text,
    char_start integer NOT NULL,
    char_end integer NOT NULL,
    qdrant_point_id uuid NOT NULL,
    created_at timestamp(0) without time zone NOT NULL
);

-- structure.sql:71  (bytes live in S3/MinIO or storage_objects; path encrypted)
CREATE TABLE public.attachments (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    vault_id uuid NOT NULL,
    mime_type text,
    size_bytes bigint,
    mtime double precision,
    deleted_at timestamp(0) without time zone,
    created_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    content_hash text,
    content_nonce bytea,
    storage_key character varying(255),         -- S3 object key (or storage_objects.storage_key)
    path_ciphertext bytea NOT NULL, path_nonce bytea NOT NULL, path_hmac bytea NOT NULL,
    encryption_version integer DEFAULT 0 NOT NULL,
    dek_version integer DEFAULT 1 NOT NULL,
    dek_version_pending integer
);

-- structure.sql:55
CREATE TABLE public.api_keys (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    key_hash text NOT NULL,                     -- hash of raw key, raw never stored
    name text,
    last_used timestamp(0) without time zone,
    created_at timestamp(0) without time zone NOT NULL
);
-- api_keys are scoped to vaults via the join table api_key_vaults(api_key_id, vault_id).
```

> The remaining tables (auth/OAuth/device flow, billing — `plans`/`subscriptions`/`usage_meters`/`user_limit_overrides`, legal — `terms_versions`/`user_agreements`, crypto canary — `system_canaries`, ops — `client_logs`/`client_origin_stats`/`email_suppressions`/`instance_settings`/`invites`, `oban_jobs`, `storage_objects`) are defined in `priv/repo/structure.sql`. When in doubt, read structure.sql — it is the generated source of truth.

## Indexes (selected, from structure.sql)

```sql
-- notes: lookups are HMAC-based (no plaintext path/folder to index)
CREATE UNIQUE INDEX notes_user_id_vault_id_path_hmac_index               -- structure.sql:1070
  ON public.notes (user_id, vault_id, path_hmac) WHERE (deleted_at IS NULL);
CREATE INDEX notes_user_id_vault_id_folder_hmac_index                    -- :1063
  ON public.notes (user_id, vault_id, folder_hmac);
CREATE INDEX notes_tags_hmac_index ON public.notes USING gin (tags_hmac); -- :1056
CREATE INDEX idx_notes_user_updated ON public.notes (user_id, updated_at); -- :1028  changes-since
CREATE INDEX idx_notes_user_deleted ON public.notes (user_id, deleted_at)  -- :1021
  WHERE (deleted_at IS NOT NULL);
CREATE INDEX idx_notes_embed_pending ON public.notes (embed_hash)          -- :1014  embed backlog
  WHERE ((deleted_at IS NULL) AND ((embed_hash IS NULL) OR (embed_hash <> content_hash)));
CREATE UNIQUE INDEX chunks_note_id_position_index ON public.chunks (note_id, "position"); -- :881
CREATE UNIQUE INDEX idx_api_keys_hash ON public.api_keys (key_hash);       -- :972  auth lookup
```

## RLS Policies

Six tables carry `FORCE ROW LEVEL SECURITY` + a `tenant_isolation_*` policy (structure.sql:1618-1690): **`notes`, `chunks`, `attachments`, `api_keys`, `vaults`, `user_agreements`**.

```sql
ALTER TABLE notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE ONLY notes FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_notes ON notes
  USING      ((user_id)::text = (SELECT current_setting('app.current_tenant', true)))
  WITH CHECK ((user_id)::text = (SELECT current_setting('app.current_tenant', true)));

-- Identical tenant_isolation_* policy on chunks, attachments, api_keys, vaults, user_agreements.
```

## DB Roles

```sql
CREATE ROLE engram_app NOINHERIT;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO engram_app;
-- App connects as engram_app (subject to RLS)
-- Migrations connect as engram_owner (bypasses RLS)
```

## Ecto RLS Enforcement Strategy

The RLS system has a subtle failure mode: if any code path queries a tenant-scoped table without calling `with_tenant/2`, `current_setting('app.current_tenant', true)` returns `''`, and RLS silently returns zero rows. No crash, no error — just missing data. This requires a layered defense:

```elixir
defmodule Engram.Repo do
  use Ecto.Repo, otp_app: :engram

  # Layer 1: Tenant-scoped transaction wrapper.
  # tenant_id is a UUID *string* (uuidv7 PKs). Sets both the process-dict guard
  # (for prepare_query) and the transaction-local app.current_tenant via
  # set_config(..., true) — the `true` (is_local) scopes it to the txn so it
  # disappears on commit/rollback (PgBouncer-safe). Nested calls for the same
  # tenant run fun directly; a nested call for a *different* tenant raises.
  def with_tenant(tenant_id, fun) when is_binary(tenant_id), do: ...

  # Layer 2: Safety net — raises if a tenant-scoped table is queried without context.
  # MUST match the six FORCE-RLS tables above (lib/engram/repo.ex:8).
  @tenant_tables ~w(notes chunks attachments api_keys vaults user_agreements)a

  @impl true
  def prepare_query(_operation, query, opts) do
    if tenant_required?(query) and is_nil(Process.get(:engram_tenant))
       and not Keyword.get(opts, :skip_tenant_check, false) do
      raise Engram.TenantError,
        "Tenant context not set! Use Repo.with_tenant/2 for tenant-scoped queries."
    end
    {query, opts}
  end

  defp tenant_required?(query) do
    # Inspect the Ecto.Query source and match against @tenant_tables
    # (compares against @tenant_table_strings — repo.ex:135).
  end
end
```

> Implementation note: the real `with_tenant/2` uses PostgreSQL `set_config('app.current_tenant', $1, true)` (transaction-local), not `SET LOCAL` as a separate statement, and the policy reads it back with `(SELECT current_setting(...))`. The conceptual model — process-dict guard + txn-local setting + RLS policy comparison — is exactly as described here.

## Enforcement Layers

| Layer | Where | What | Failure mode |
|-------|-------|------|-------------|
| **Auth Plug** | HTTP requests | Extracts `user_id` from Bearer token → `conn.assigns.user_id` | 401 if missing |
| **Socket.connect** | WebSocket | Extracts `user_id` from token → `socket.assigns.user_id` | Connection refused |
| **Context functions** | `Notes`, `Search`, etc. | Receive `user_id` as parameter, always call `Repo.with_tenant/2` | Compile-time pattern — all public context functions take `user_id` |
| **Oban workers** | Background jobs | Receive `user_id` in job args, call `Repo.with_tenant/2` | Job fails → Oban retries |
| **Repo.prepare_query** | Every DB query | Raises if tenant-scoped table queried without process-dict guard | Crash in dev/test, logged alert in prod |

## PgBouncer Safety

`SET LOCAL` is scoped to the explicit transaction inside `with_tenant/2`. When the transaction ends, the setting disappears. PgBouncer (transaction mode) returns a clean connection to the pool. No tenant leakage between requests.

## `skip_tenant_check` Escape Hatch

For rare cross-tenant queries (admin dashboard, cron cleanup jobs), pass `skip_tenant_check: true` in query opts. These queries run as `engram_owner` (bypasses RLS) or use explicit `WHERE user_id = ?` filtering. Usage should be audited in code review.

## Testing RLS with Ecto.Sandbox

Ecto.Sandbox wraps each test in a transaction that rolls back. `SET LOCAL` inside nested `with_tenant/2` calls creates savepoints — the tenant setting is respected correctly.

```elixir
test "tenant isolation via RLS" do
  user_a = insert(:user)   # uuidv7 id
  user_b = insert(:user)

  {:ok, _} = Repo.with_tenant(user_a.id, fn ->
    insert(:note, user_id: user_a.id)   # note content is encrypted; build via factory
  end)

  {:ok, notes} = Repo.with_tenant(user_b.id, fn -> Repo.all(Note) end)
  assert notes == []

  # No tenant context → prepare_query raises before the query runs.
  assert_raise Engram.TenantError, fn -> Repo.all(Note) end
end
```

## Key Design Notes

- **Sync versioning:** `version` is a server-controlled monotonic counter. Plugin sends known version on push; mismatch returns 409 with current state. `content_hash` enables skip-if-unchanged; `embed_hash` (= content_hash at last successful embed) gates re-embedding.
- **Chunk storage (hybrid):** Postgres `chunks` = source of truth for boundaries/positions. Qdrant = vectors + contextualized text. Enables parent-child retrieval.
- **IDs:** `uuid DEFAULT uuidv7()` everywhere (time-ordered UUIDs — index-friendly, no sequence hotspot). Used both internally and in the API; no separate `public_id` needed.
- **Encryption at rest:** values are AES-GCM (`*_ciphertext` + `*_nonce`), AAD-bound, under a per-user DEK (`users.encrypted_dek`). Searchable/uniquely-indexed columns (path, folder, tags) carry an additional keyed `*_hmac`. See `docs/context/encryption-operations.md`.

## References
- Generated schema (source of truth): `priv/repo/structure.sql`
- Repo RLS enforcement: `lib/engram/repo.ex`
- Ecto schemas: `lib/engram/` (e.g. `notes/note.ex`, `vaults/vault.ex`)
- Migrations: `priv/repo/migrations/`
