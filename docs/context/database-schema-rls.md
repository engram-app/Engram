# Context Doc: Database Schema & RLS

_Last verified: 2026-04-03_

## Status
Working — design finalized, implementation in progress.

## What This Is
Complete PostgreSQL schema with Row-Level Security policies and the Ecto integration strategy for tenant isolation.

## Schema

```sql
CREATE TABLE users (
  id BIGSERIAL PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  display_name TEXT,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE notes (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id),
  path TEXT NOT NULL,
  title TEXT,
  content TEXT,
  folder TEXT,
  tags TEXT[],
  version INTEGER NOT NULL DEFAULT 1,       -- monotonic, incremented on every upsert (optimistic concurrency)
  content_hash TEXT,                         -- SHA256 of content, enables skip-if-unchanged during sync
  mtime DOUBLE PRECISION,
  deleted_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(user_id, path)
);

-- Chunk metadata (source of truth for what chunks exist; vectors + raw text live in Qdrant)
CREATE TABLE chunks (
  id BIGSERIAL PRIMARY KEY,
  note_id BIGINT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  user_id BIGINT NOT NULL REFERENCES users(id),
  position SMALLINT NOT NULL,               -- chunk order within note (0-indexed)
  heading_path TEXT,                         -- e.g., "## Benefits > ### Omega-3"
  char_start INTEGER NOT NULL,              -- start offset in note content
  char_end INTEGER NOT NULL,                -- end offset in note content
  qdrant_point_id UUID NOT NULL,            -- reference to Qdrant vector point
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(note_id, position)
);

CREATE TABLE attachments (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id),
  path TEXT NOT NULL,
  mime_type TEXT,
  size_bytes BIGINT,
  mtime DOUBLE PRECISION,
  deleted_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(user_id, path)
  -- content stored in AWS S3 (SaaS) or local filesystem (self-hosted), NOT in DB
);

CREATE TABLE api_keys (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id),
  key_hash TEXT NOT NULL,  -- SHA256 of raw key, raw never stored
  name TEXT,
  last_used TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

## Indexes

```sql
CREATE INDEX idx_notes_user_updated ON notes(user_id, updated_at);    -- changes-since query
CREATE INDEX idx_notes_user_folder ON notes(user_id, folder);          -- folder listing
CREATE INDEX idx_notes_user_deleted ON notes(user_id, deleted_at)
  WHERE deleted_at IS NOT NULL;                                        -- soft-delete cleanup
CREATE INDEX idx_chunks_note ON chunks(note_id);                       -- chunk lookup by note
CREATE INDEX idx_api_keys_hash ON api_keys(key_hash);                  -- auth lookup
```

## RLS Policies

```sql
ALTER TABLE notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE notes FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_notes ON notes
  USING (user_id::text = current_setting('app.current_tenant', true))
  WITH CHECK (user_id::text = current_setting('app.current_tenant', true));

-- Repeat for attachments, api_keys, chunks
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

  # Layer 1: Tenant-scoped transaction wrapper
  def with_tenant(tenant_id, fun) do
    Process.put(:engram_tenant, tenant_id)
    try do
      transaction(fn ->
        query!("SET LOCAL app.current_tenant = $1", [to_string(tenant_id)])
        fun.()
      end)
    after
      Process.delete(:engram_tenant)
    end
  end

  # Layer 2: Safety net — raises if tenant-scoped table queried without context
  @tenant_tables ~w(notes chunks attachments api_keys)a

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
    # Check if query targets a tenant-scoped table
    # Implementation: inspect the Ecto.Query source and match against @tenant_tables
  end
end
```

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
  user_a = insert(:user)
  user_b = insert(:user)

  {:ok, _} = Repo.with_tenant(user_a.id, fn ->
    Repo.insert!(%Note{user_id: user_a.id, path: "secret.md", content: "private"})
  end)

  {:ok, notes} = Repo.with_tenant(user_b.id, fn ->
    Repo.all(Note)
  end)
  assert notes == []

  assert_raise Engram.TenantError, fn ->
    Repo.all(Note)
  end
end
```

## Key Design Notes

- **Sync versioning:** `version` is a server-controlled monotonic counter. Plugin sends known version on push; mismatch returns 409 with current state. `content_hash` (SHA256) enables skip-if-unchanged.
- **Chunk storage (hybrid):** Postgres `chunks` = source of truth for boundaries/positions. Qdrant = vectors + contextualized text. Enables parent-child retrieval.
- **IDs:** BIGSERIAL for internal FKs only. API uses `path` as identifier. Add `public_id UUID` column if share links needed later.

## References
- Ecto schemas: `lib/engram/` (notes.ex, chunks.ex, etc.)
- Migrations: `priv/repo/migrations/`
