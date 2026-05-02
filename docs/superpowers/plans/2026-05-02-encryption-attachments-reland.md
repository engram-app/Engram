# Phase A Re-land — Attachment Encryption + BYTEA→S3 Backfill (PR #58)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-land Phase A of the Tier 2 encryption plan WITHOUT the data-loss risk that forced the revert of PR #55. This PR adds encryption-at-rest for new attachments, leaves the `Engram.Storage.Database` BYTEA adapter operational, and ships a backfill mix task that migrates the 133 existing BYTEA-only attachments on FastRaid saas to encrypted MinIO objects. After this PR ships and the backfill runs successfully on prod, follow-up PR #59 cuts new writes over to S3-only and PR #60 drops the legacy column + adapter.

**Architecture:** Three-PR sequence. This plan covers ONLY PR #58. The previous attempt (PR #55, reverted as PR #57) tried to do all three in one shot and assumed BYTEA was already mirrored to S3 — it wasn't. This sequence is: (1) deploy additive code that supports both storage paths AND can encrypt-on-put when the active backend is S3; (2) run the BYTEA→S3 backfill task on prod via SSH; (3) verify all 133 saas rows have encrypted S3 objects + `encryption_version = 1`; (4) only then start PR #59. The dual-flow `get_attachment` already shipped on main (legacy code) reads BYTEA when `content` is non-nil, so legacy reads continue to work throughout.

**Tech Stack:** Elixir/Phoenix, Ecto migrations, AES-256-GCM via `Engram.Crypto.Envelope`, per-user DEK via `Engram.Crypto.{ensure_user_dek/1, get_dek/1}`, ExAws.S3 (MinIO local, Tigris prod), ExUnit + Mox, an ETS-backed in-memory storage adapter for tests.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `priv/repo/migrations/<ts>_add_attachment_encryption_columns.exs` | Create | Additive migration: `encryption_version` (int default 0) + `content_nonce` (bytea). NO column drops. Partial index on legacy plaintext rows for backfill scan. |
| `lib/engram/attachments/attachment.ex` | Modify | Add `encryption_version` + `content_nonce` to schema + changeset. Validate `encryption_version IN (0, 1)`. Validate `content_nonce` required iff `encryption_version = 1`. |
| `lib/engram/attachments.ex` | Modify | (a) `upsert_attachment`: when active adapter is S3, encrypt plaintext before `store_external` and persist `content_nonce` + `encryption_version = 1`. When adapter is Database (BYTEA), keep existing plaintext path (encryption_version stays 0). (b) `get_attachment`: when reading from S3 with `encryption_version = 1`, decrypt before returning. |
| `lib/engram/workers/backfill_bytea_to_s3.ex` | Create | Oban worker (queue: `crypto_backfill`). Cursor-driven batch of N rows, idempotent (skips rows with `encryption_version = 1`), reads BYTEA via `Repo`, encrypts, writes to S3, updates `encryption_version` + `content_nonce`. Does NOT clear the BYTEA column (#59 does). |
| `lib/mix/tasks/engram.backfill_bytea_to_s3.ex` | Create | Thin mix task that scans for vaults with at least one legacy plaintext attachment and enqueues one worker job per (user_id, vault_id) cursor=0. |
| `test/engram/workers/backfill_bytea_to_s3_test.exs` | Create | ExUnit tests: (1) backfill of one row produces matching S3 object + flips version, (2) re-running is idempotent, (3) missing DEK is auto-provisioned, (4) S3 put failure → row left unchanged, (5) batch boundary advances cursor. |
| `test/engram/attachments_test.exs` | Modify | Add tests for: encrypted-S3 round-trip on new uploads, legacy BYTEA read path still works after migration, mixed-vault read returns plaintext for both. |
| `test/support/storage_in_memory.ex` | Create | ETS-backed `Engram.Storage` impl, default for tests via `config/test.exs`. Same as PR #55's version (resurrect from git). |
| `config/test.exs` | Modify | Default `:storage` to `Engram.Storage.InMemory`. |
| `e2e/tests/api_only/test_19_write_isolation.py` | Modify | Add probe asserting that when `STORAGE_BACKEND=s3` is set in CI, a freshly-uploaded attachment's MinIO object bytes are ciphertext (header check), not plaintext. |
| `e2e/helpers/crypto_probe.py` | Create | `assert_attachment_ciphertext_at_rest(vault_id, path)` helper; reuses the pattern from PR #55's probe. |
| `docker-compose.ci.yml` | Modify | Re-add MinIO + minio-init services; engram service depends on `minio-init: condition: service_completed_successfully`; env vars `STORAGE_BACKEND=s3`, `STORAGE_BUCKET=engram-saas-attachments`, `STORAGE_HOST=minio`, etc. (resurrect from git history of PR #55). |
| `e2e/helpers/cleanup.py` | Modify | Add `cleanup_minio_bucket()` and wire into `full_cleanup()`. (resurrect from git history) |
| `e2e/conftest.py` | Modify | Import + invoke `cleanup_minio_bucket` in session teardown. (resurrect) |
| `.github/workflows/ci.yml` | Modify | Add `CI_MINIO_CONTAINER: ${{ env.CI_PROJECT }}-minio-1` env var alongside each `CI_POSTGRES_CONTAINER`. (resurrect) |
| `mix.exs` | Modify | Bump version `0.5.13` → `0.5.14`. |
| `docs/context/encryption-operations.md` | Modify | Add Phase A status line + production runbook section for the BYTEA→S3 backfill (SSH steps, verification queries, rollback). |

**Why no `Engram.Storage.Database` deletion in this PR:** prod still relies on it for legacy reads. It dies in PR #60.

**Why no `content` column drop in this PR:** prod has 133 rows holding plaintext payloads in BYTEA. The drop would lose them. PR #60 drops the column AFTER backfill is verified + PR #59 has run for one deploy cycle.

---

## Production Runbook (executed AFTER this PR merges + deploys 0.5.14 to FastRaid)

> Operator runs this from their workstation. The PR doesn't run anything destructive automatically — backfill is opt-in via mix task.

1. **Pre-flight: confirm 0.5.14 deployed**
   ```
   curl -sf http://10.0.20.214:8000/api/health | jq -r .version
   # Expect: "0.5.14"
   ```
2. **Pre-flight: confirm legacy row count + S3 bucket state**
   ```
   ssh root@10.0.20.214 "docker exec engram-saas-postgres psql -U engram -d engram -c \
     \"SELECT count(*) FILTER (WHERE content IS NOT NULL) AS bytea, \
       count(*) FILTER (WHERE encryption_version = 1) AS encrypted, \
       count(*) AS total FROM attachments;\""
   # Expect on saas: bytea=133 encrypted=0 total=133
   # Expect on selfhost: bytea=0 encrypted=0 total=0

   ssh root@10.0.20.214 "docker exec minio sh -c \
     'mc alias set local http://localhost:9000 \$MINIO_ROOT_USER \$MINIO_ROOT_PASSWORD >/dev/null && \
      mc ls --recursive local/engram-saas-attachments/ | wc -l'"
   # Expect: 0
   ```
3. **Set STORAGE_BACKEND=s3 on engram-saas Unraid template** (so post-backfill new uploads go to S3, encrypted):
   - Edit `/boot/config/plugins/dockerMan/templates-user/my-engram-saas.xml`
   - Add `<Config Name="STORAGE_BACKEND" ... Default="s3" Mode="" ...>s3</Config>`
   - Add `STORAGE_BUCKET=engram-saas-attachments`, `STORAGE_HOST=minio`, `STORAGE_PORT=9000`, `STORAGE_SCHEME=http://`, `STORAGE_ACCESS_KEY_ID`, `STORAGE_SECRET_ACCESS_KEY` (copy from MinIO root user/password)
   - Apply via Unraid Docker tab → Force Update → engram-saas
   - Confirm container restarted: `docker exec engram-saas env | grep STORAGE_BACKEND` → `STORAGE_BACKEND=s3`
4. **Smoke test: upload one new attachment via plugin, verify it lands in MinIO encrypted**
   ```
   ssh root@10.0.20.214 "docker exec minio sh -c \
     'mc alias set local http://localhost:9000 \$MINIO_ROOT_USER \$MINIO_ROOT_PASSWORD >/dev/null && \
      mc ls --recursive local/engram-saas-attachments/ | head -5'"
   # Expect: at least one object listed
   ```
   Open the smoke-test attachment via the plugin/web UI — should round-trip identically (decrypt path works).
5. **Run backfill mix task inside the engram-saas container**
   ```
   ssh root@10.0.20.214 "docker exec engram-saas /app/bin/engram eval \
     'Mix.Task.run(\"engram.backfill_bytea_to_s3\")'"
   # Output: "Enqueued N jobs for M vaults" (one job per vault with legacy attachments)
   ```
6. **Wait for Oban queue to drain (max ~5 min for 133 small files)**
   ```
   ssh root@10.0.20.214 "docker exec engram-saas-postgres psql -U engram -d engram -c \
     \"SELECT count(*) FROM oban_jobs WHERE worker = 'Engram.Workers.BackfillByteaToS3' AND state IN ('available','executing','retryable');\""
   # Wait until: 0
   ```
7. **Verification gate**
   ```
   ssh root@10.0.20.214 "docker exec engram-saas-postgres psql -U engram -d engram -c \
     \"SELECT count(*) FILTER (WHERE encryption_version = 1) AS encrypted, count(*) AS total FROM attachments;\""
   # Expect: encrypted=133 total=133

   ssh root@10.0.20.214 "docker exec minio sh -c \
     'mc alias set local http://localhost:9000 \$MINIO_ROOT_USER \$MINIO_ROOT_PASSWORD >/dev/null && \
      mc ls --recursive local/engram-saas-attachments/ | wc -l'"
   # Expect: 133
   ```
8. **Spot-check round-trip:** download 3 random attachments via the plugin, confirm bytes match expectation (image opens, PDF renders).
9. **Done — PR #58 complete.** Open PR #59 (cut writes to S3-only, retain dual-read).

**Rollback:** if step 7 verification fails or step 8 round-trips fail, BYTEA copies still exist in DB (backfill never deletes BYTEA). To roll back: unset `STORAGE_BACKEND=s3` env on the Unraid template (returns to BYTEA writes); investigate failed S3 puts via Oban telemetry / `mc ls`. The `encryption_version` column can be reset to 0 manually if needed; partial re-runs of the backfill are idempotent.

---

## Task 1: Resurrect ETS-backed test storage adapter

**Files:**
- Create: `backend/test/support/storage_in_memory.ex`
- Modify: `backend/config/test.exs`

- [ ] **Step 1: Verify the file is not present (post-revert)**

Run: `ls backend/test/support/storage_in_memory.ex 2>&1`
Expected: `No such file or directory`

- [ ] **Step 2: Create the in-memory adapter**

```elixir
# backend/test/support/storage_in_memory.ex
defmodule Engram.Storage.InMemory do
  @moduledoc """
  ETS-backed in-memory storage adapter for tests.

  Default stub for `Engram.MockStorage` — tests that need to assert on
  storage interactions still use `Mox.expect/3` directly; tests that
  just want a working backend get pass-through behaviour for free.
  """

  @behaviour Engram.Storage

  @table :engram_test_storage_in_memory

  @doc "Lazily ensures the ETS table exists. Idempotent and safe to call concurrently."
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:public, :named_table, :set])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  @impl true
  def put(key, binary, _opts \\ []) do
    ensure_table()
    :ets.insert(@table, {key, binary})
    :ok
  end

  @impl true
  def get(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, binary}] -> {:ok, binary}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete(key) do
    ensure_table()
    :ets.delete(@table, key)
    :ok
  end

  @impl true
  def exists?(key) do
    ensure_table()
    :ets.member(@table, key)
  end
end
```

- [ ] **Step 3: Default test config to InMemory adapter**

Edit `backend/config/test.exs` — find the existing `config :engram, :storage, ...` line (or add one if missing). Confirm it reads:

```elixir
config :engram, :storage, Engram.Storage.InMemory
```

If the line is absent, add it adjacent to the other `config :engram, ...` lines.

- [ ] **Step 4: Run the existing attachment test suite to confirm no regressions**

Run: `cd backend && mix test test/engram/attachments_test.exs`
Expected: all current tests pass (the InMemory adapter satisfies the contract).

- [ ] **Step 5: Commit**

```bash
cd backend
git add test/support/storage_in_memory.ex config/test.exs
git commit -m "test: add ETS-backed in-memory storage adapter for default test config"
```

---

## Task 2: Migration adds encryption_version + content_nonce columns

**Files:**
- Create: `backend/priv/repo/migrations/<ts>_add_attachment_encryption_columns.exs`

- [ ] **Step 1: Generate the migration file**

Run: `cd backend && mix ecto.gen.migration add_attachment_encryption_columns`
Expected: a file `priv/repo/migrations/<TIMESTAMP>_add_attachment_encryption_columns.exs` is created. Note the timestamp.

- [ ] **Step 2: Write the migration body**

Replace the generated empty body with:

```elixir
defmodule Engram.Repo.Migrations.AddAttachmentEncryptionColumns do
  use Ecto.Migration

  def change do
    alter table(:attachments) do
      add :encryption_version, :integer, default: 0, null: false
      add :content_nonce, :binary
    end

    # Partial index on legacy plaintext rows so the backfill scan is cheap
    # even after most rows are migrated.
    create index(:attachments, [:vault_id, :id],
             where: "encryption_version = 0 AND content IS NOT NULL",
             name: :attachments_legacy_plaintext_idx
           )
  end
end
```

- [ ] **Step 3: Run the migration locally to verify it applies cleanly**

Run: `cd backend && mix ecto.migrate`
Expected: migration runs, no errors. Verify with `mix ecto.migrations | grep encryption` showing `up` status.

- [ ] **Step 4: Run the migration's down path to confirm reversibility**

Run: `cd backend && mix ecto.rollback` (rolls back exactly one migration — the one we just added)
Expected: migration rolls back cleanly. Run `mix ecto.migrate` again to re-apply for subsequent tasks.

- [ ] **Step 5: Commit**

```bash
cd backend
git add priv/repo/migrations/*_add_attachment_encryption_columns.exs
git commit -m "feat(encryption): add attachment encryption_version + content_nonce cols"
```

---

## Task 3: Schema field additions + changeset validations

**Files:**
- Modify: `backend/lib/engram/attachments/attachment.ex`
- Modify: `backend/test/engram/attachments_test.exs` (one new validation test)

- [ ] **Step 1: Write the failing test for encryption_version validation**

Add to `backend/test/engram/attachments_test.exs` (in an existing `describe` block or a new one named `"changeset validations"`):

```elixir
test "rejects encryption_version outside [0, 1]" do
  user = insert(:user)
  vault = insert(:vault, user: user)

  attrs = %{
    path: "x.png",
    content_hash: "abc",
    mime_type: "image/png",
    size_bytes: 10,
    user_id: user.id,
    vault_id: vault.id,
    encryption_version: 7
  }

  changeset = Engram.Attachments.Attachment.changeset(%Engram.Attachments.Attachment{}, attrs)
  refute changeset.valid?
  assert "is invalid" in errors_on(changeset).encryption_version
end

test "requires content_nonce when encryption_version = 1" do
  user = insert(:user)
  vault = insert(:vault, user: user)

  attrs = %{
    path: "x.png",
    content_hash: "abc",
    mime_type: "image/png",
    size_bytes: 10,
    user_id: user.id,
    vault_id: vault.id,
    encryption_version: 1,
    content_nonce: nil
  }

  changeset = Engram.Attachments.Attachment.changeset(%Engram.Attachments.Attachment{}, attrs)
  refute changeset.valid?
  assert "must be present when encryption_version = 1" in errors_on(changeset).content_nonce
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/engram/attachments_test.exs -t "encryption_version" --trace`
Expected: FAIL — `encryption_version` is not yet a field on the schema.

- [ ] **Step 3: Add fields and validations to the schema**

Update `backend/lib/engram/attachments/attachment.ex`:

```elixir
defmodule Engram.Attachments.Attachment do
  use Ecto.Schema
  import Ecto.Changeset

  @max_attachment_bytes 5 * 1024 * 1024

  schema "attachments" do
    field :path, :string
    field :content, :binary
    field :content_hash, :string
    field :mime_type, :string
    field :size_bytes, :integer
    field :mtime, :float
    field :storage_key, :string
    field :deleted_at, :utc_datetime
    field :encryption_version, :integer, default: 0
    field :content_nonce, :binary

    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :path,
      :content,
      :content_hash,
      :mime_type,
      :size_bytes,
      :mtime,
      :user_id,
      :vault_id,
      :storage_key,
      :deleted_at,
      :encryption_version,
      :content_nonce
    ])
    |> validate_required([:path, :user_id, :vault_id, :content_hash, :mime_type, :size_bytes])
    |> validate_inclusion(:encryption_version, [0, 1])
    |> validate_number(:size_bytes, less_than_or_equal_to: @max_attachment_bytes)
    |> validate_nonce_consistency()
    |> unique_constraint([:user_id, :vault_id, :path], name: :attachments_user_vault_path_active_index)
  end

  def max_attachment_bytes, do: @max_attachment_bytes

  defp validate_nonce_consistency(changeset) do
    version = get_field(changeset, :encryption_version) || 0
    nonce = get_field(changeset, :content_nonce)

    cond do
      version == 1 and is_nil(nonce) ->
        add_error(changeset, :content_nonce, "must be present when encryption_version = 1")

      version == 0 and not is_nil(nonce) ->
        add_error(changeset, :content_nonce, "must be nil when encryption_version = 0")

      true ->
        changeset
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/engram/attachments_test.exs -t "encryption_version" --trace`
Expected: PASS for both new tests.

- [ ] **Step 5: Run the full attachments test file to catch regressions**

Run: `cd backend && mix test test/engram/attachments_test.exs`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd backend
git add lib/engram/attachments/attachment.ex test/engram/attachments_test.exs
git commit -m "feat(encryption): attachment schema validates encryption_version + nonce"
```

---

## Task 4: Encrypt-on-put when active backend is S3

**Files:**
- Modify: `backend/lib/engram/attachments.ex`
- Modify: `backend/test/engram/attachments_test.exs`

- [ ] **Step 1: Write the failing test for encrypted S3 round-trip**

Add to `backend/test/engram/attachments_test.exs`, after asserting at the top of the file that `Mox` is imported and `:set_mox_from_context` is wired up:

```elixir
describe "encrypted S3 storage path" do
  # Module-level `setup :set_mox_from_context` should already exist near the top
  # of this test file (added by earlier MOX-using tests). If not, add it once
  # in the module's setup chain — do NOT call set_mox_from_context inline.

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)

    Mox.stub_with(Engram.MockStorage, Engram.Storage.InMemory)
    :ok
  end

  test "encrypts attachment content before put when active backend is S3" do
    user = insert(:user) |> Engram.Repo.reload!()
    vault = insert(:vault, user: user)
    plaintext = "secret bytes"
    b64 = Base.encode64(plaintext)

    test_pid = self()

    Mox.expect(Engram.MockStorage, :put, fn _key, bytes, _opts ->
      send(test_pid, {:put_bytes, bytes})
      :ok
    end)

    {:ok, _att} =
      Engram.Attachments.upsert_attachment(user, vault, %{
        "path" => "secret.bin",
        "content_base64" => b64,
        "mtime" => 0.0
      })

    assert_receive {:put_bytes, stored}, 500
    refute stored == plaintext
    assert byte_size(stored) >= byte_size(plaintext) + 16
  end

  test "round-trips encrypted attachment via get_attachment" do
    user = insert(:user) |> Engram.Repo.reload!()
    vault = insert(:vault, user: user)
    plaintext = "round trip me"
    b64 = Base.encode64(plaintext)

    {:ok, _att} =
      Engram.Attachments.upsert_attachment(user, vault, %{
        "path" => "rt.bin",
        "content_base64" => b64,
        "mtime" => 0.0
      })

    {:ok, fetched} = Engram.Attachments.get_attachment(user, vault, "rt.bin")
    assert fetched.content == plaintext
    assert fetched.encryption_version == 1
    assert is_binary(fetched.content_nonce)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && mix test test/engram/attachments_test.exs -t "encrypted S3 storage path" --trace`
Expected: FAIL — current `upsert_attachment` writes plaintext to storage when adapter is non-Database.

- [ ] **Step 3: Wire encryption into upsert_attachment**

Update `backend/lib/engram/attachments.ex` — replace the existing `upsert_attachment/3` and supporting helpers with the encrypted-on-put variant:

```elixir
alias Engram.Crypto
alias Engram.Crypto.Envelope

def upsert_attachment(user, vault, attrs) do
  path = (attrs["path"] || attrs[:path]) |> PathSanitizer.sanitize()
  content_b64 = attrs["content_base64"] || attrs[:content_base64]
  mtime = attrs["mtime"] || attrs[:mtime]
  explicit_mime = attrs["mime_type"] || attrs[:mime_type]

  with {:ok, plaintext} <- decode_base64(content_b64),
       :ok <- validate_size(plaintext),
       {:ok, key, changeset_attrs, blob_to_store} <-
         prepare_upload(user, vault, path, plaintext, mtime, explicit_mime),
       :ok <- store_external(key, blob_to_store, changeset_attrs.mime_type) do
    Repo.with_tenant(user.id, fn ->
      existing =
        Repo.one(
          from(a in Attachment,
            where: a.path == ^path and a.user_id == ^user.id and a.vault_id == ^vault.id
          )
        )

      case existing do
        nil ->
          %Attachment{}
          |> Attachment.changeset(changeset_attrs)
          |> Repo.insert()

        att ->
          att
          |> Attachment.changeset(changeset_attrs)
          |> Repo.update()
      end
    end)
    |> unwrap_tenant()
  end
end

defp prepare_upload(user, vault, path, plaintext, mtime, explicit_mime) do
  mime = explicit_mime || detect_mime(path)
  hash = :crypto.hash(:md5, plaintext) |> Base.encode16(case: :lower)
  key = Storage.key(user.id, vault.id, path)
  backend = Storage.adapter()

  base_attrs = %{
    path: path,
    content_hash: hash,
    mime_type: mime,
    size_bytes: byte_size(plaintext),
    mtime: mtime,
    user_id: user.id,
    vault_id: vault.id,
    storage_key: key,
    deleted_at: nil
  }

  cond do
    backend == Storage.Database ->
      {:ok, key, Map.put(base_attrs, :content, plaintext), :skip}

    true ->
      with {:ok, user} <- Crypto.ensure_user_dek(user),
           {:ok, dek} <- Crypto.get_dek(user) do
        {ciphertext, nonce} = Envelope.encrypt(plaintext, dek)

        attrs =
          base_attrs
          |> Map.put(:encryption_version, 1)
          |> Map.put(:content_nonce, nonce)

        {:ok, key, attrs, ciphertext}
      end
  end
end

defp store_external(_key, :skip, _mime), do: :ok

defp store_external(key, binary, mime) do
  case Storage.adapter().put(key, binary, content_type: mime) do
    :ok -> :ok
    {:error, reason} -> {:error, {:storage, reason}}
  end
end
```

Note: `prepare_upload` now returns a 4-tuple `{:ok, key, changeset_attrs, blob_to_store}` where `blob_to_store` is `:skip` for the BYTEA path (no external write) or the ciphertext binary for the S3 path. Remove the now-dead `maybe_include_content/3` helpers.

- [ ] **Step 4: Run the encrypted-path tests**

Run: `cd backend && mix test test/engram/attachments_test.exs -t "encrypted S3 storage path" --trace`
Expected: PASS.

- [ ] **Step 5: Run the full attachments test file**

Run: `cd backend && mix test test/engram/attachments_test.exs`
Expected: all tests pass — legacy BYTEA path tests still green, encrypted path tests green.

- [ ] **Step 6: Commit**

```bash
cd backend
git add lib/engram/attachments.ex test/engram/attachments_test.exs
git commit -m "feat(encryption): encrypt-on-put for attachments via Crypto.Envelope"
```

---

## Task 5: Decrypt-on-get for encryption_version = 1

**Files:**
- Modify: `backend/lib/engram/attachments.ex`
- Modify: `backend/test/engram/attachments_test.exs`

- [ ] **Step 1: Add a failing test for legacy BYTEA bypass during reads**

Add to the `"encrypted S3 storage path"` describe block (or a new `"read paths"` block):

```elixir
test "legacy BYTEA row is returned without decrypt attempt" do
  user = insert(:user)
  vault = insert(:vault, user: user)

  prev = Application.get_env(:engram, :storage)
  Application.put_env(:engram, :storage, Engram.Storage.Database)
  on_exit(fn -> Application.put_env(:engram, :storage, prev) end)

  {:ok, _att} =
    Engram.Attachments.upsert_attachment(user, vault, %{
      "path" => "legacy.bin",
      "content_base64" => Base.encode64("legacy plaintext"),
      "mtime" => 0.0
    })

  {:ok, fetched} = Engram.Attachments.get_attachment(user, vault, "legacy.bin")
  assert fetched.content == "legacy plaintext"
  assert fetched.encryption_version == 0
  assert is_nil(fetched.content_nonce)
end
```

- [ ] **Step 2: Run test to verify it passes (no decrypt attempt for BYTEA path)**

Run: `cd backend && mix test test/engram/attachments_test.exs -t "legacy BYTEA" --trace`
Expected: PASS — BYTEA short-circuit on `not is_nil(content)` already lives at line 78 in the current `get_attachment`.

(This is a regression-locking test — it's pre-passing but documents the invariant.)

- [ ] **Step 3: Add a failing test for missing-DEK error during decrypt**

```elixir
test "encrypted row with missing DEK returns {:error, :decrypt_failed}" do
  user = insert(:user)
  vault = insert(:vault, user: user)

  # Insert an encrypted-shape row but with a bogus content_nonce that won't decrypt
  fake_nonce = :crypto.strong_rand_bytes(12)

  {:ok, _att} =
    Engram.Repo.with_tenant(user.id, fn ->
      %Engram.Attachments.Attachment{}
      |> Engram.Attachments.Attachment.changeset(%{
        path: "ghost.bin",
        content_hash: "deadbeef",
        mime_type: "application/octet-stream",
        size_bytes: 12,
        user_id: user.id,
        vault_id: vault.id,
        storage_key: Engram.Storage.key(user.id, vault.id, "ghost.bin"),
        encryption_version: 1,
        content_nonce: fake_nonce
      })
      |> Engram.Repo.insert()
    end)
    |> case do
      {:ok, {:ok, att}} -> {:ok, att}
      other -> other
    end

  Engram.Storage.InMemory.put(
    Engram.Storage.key(user.id, vault.id, "ghost.bin"),
    :crypto.strong_rand_bytes(40)
  )

  assert {:error, :decrypt_failed} =
           Engram.Attachments.get_attachment(user, vault, "ghost.bin")
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `cd backend && mix test test/engram/attachments_test.exs -t "missing DEK" --trace`
Expected: FAIL — current code does not decrypt; it returns the bytes as-is.

- [ ] **Step 5: Wire decrypt into get_attachment**

In `backend/lib/engram/attachments.ex`, locate the existing `case Storage.adapter().get(key) do` clause inside `get_attachment/3` and replace it with:

```elixir
case Storage.adapter().get(key) do
  {:ok, binary} ->
    decrypt_if_needed(att, binary, user)

  {:error, :not_found} ->
    require Logger
    Logger.error("Attachment blob missing for live row: id=#{att.id} key=#{key}")
    {:error, {:storage, :blob_missing}}

  {:error, reason} ->
    {:error, {:storage, reason}}
end
```

Add this private helper immediately above `defp delete_external`:

```elixir
defp decrypt_if_needed(%Attachment{encryption_version: 0} = att, binary, _user) do
  {:ok, %{att | content: binary}}
end

defp decrypt_if_needed(%Attachment{encryption_version: 1, content_nonce: nonce} = att, ciphertext, user) do
  with {:ok, dek} <- Crypto.get_dek(user),
       {:ok, plaintext} <- Envelope.decrypt(ciphertext, nonce, dek) do
    {:ok, %{att | content: plaintext}}
  else
    :error -> {:error, :decrypt_failed}
    {:error, _} -> {:error, :decrypt_failed}
  end
end
```

- [ ] **Step 6: Run the failing test to confirm it passes**

Run: `cd backend && mix test test/engram/attachments_test.exs -t "missing DEK" --trace`
Expected: PASS.

- [ ] **Step 7: Run the full test file**

Run: `cd backend && mix test test/engram/attachments_test.exs`
Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
cd backend
git add lib/engram/attachments.ex test/engram/attachments_test.exs
git commit -m "feat(encryption): decrypt-on-get for attachment encryption_version=1"
```

---

## Task 6: Backfill Oban worker

**Files:**
- Create: `backend/lib/engram/workers/backfill_bytea_to_s3.ex`
- Create: `backend/test/engram/workers/backfill_bytea_to_s3_test.exs`

- [ ] **Step 1: Write the failing test — single-row backfill**

```elixir
# backend/test/engram/workers/backfill_bytea_to_s3_test.exs
defmodule Engram.Workers.BackfillByteaToS3Test do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Repo
  alias Engram.Workers.BackfillByteaToS3

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)

    stub_with(Engram.MockStorage, Engram.Storage.InMemory)
    :ok
  end

  defp insert_legacy_attachment(user, vault, path, plaintext) do
    Repo.with_tenant(user.id, fn ->
      %Attachment{}
      |> Attachment.changeset(%{
        path: path,
        content: plaintext,
        content_hash: :crypto.hash(:md5, plaintext) |> Base.encode16(case: :lower),
        mime_type: "application/octet-stream",
        size_bytes: byte_size(plaintext),
        user_id: user.id,
        vault_id: vault.id,
        storage_key: Engram.Storage.key(user.id, vault.id, path),
        encryption_version: 0
      })
      |> Repo.insert()
    end)
    |> case do
      {:ok, {:ok, att}} -> att
      other -> raise "factory insert failed: #{inspect(other)}"
    end
  end

  test "backfills one legacy BYTEA row to encrypted S3 + flips version" do
    user = insert(:user) |> Repo.reload!()
    vault = insert(:vault, user: user)
    att = insert_legacy_attachment(user, vault, "doc.pdf", "PDF-bytes-here")

    assert :ok =
             perform_job(BackfillByteaToS3, %{
               user_id: user.id,
               vault_id: vault.id,
               cursor: 0
             })

    reloaded = Repo.get!(Attachment, att.id, skip_tenant_check: true)
    assert reloaded.encryption_version == 1
    assert is_binary(reloaded.content_nonce)

    {:ok, ciphertext} = Engram.Storage.InMemory.get(reloaded.storage_key)
    refute ciphertext == "PDF-bytes-here"

    {:ok, user} = Crypto.ensure_user_dek(Repo.reload!(user))
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, plaintext} = Envelope.decrypt(ciphertext, reloaded.content_nonce, dek)
    assert plaintext == "PDF-bytes-here"
  end

  test "is idempotent — re-running on a v=1 row is a no-op" do
    user = insert(:user) |> Repo.reload!()
    vault = insert(:vault, user: user)
    _att = insert_legacy_attachment(user, vault, "doc.pdf", "PDF-bytes")

    assert :ok =
             perform_job(BackfillByteaToS3, %{user_id: user.id, vault_id: vault.id, cursor: 0})

    # Mox.expect(0) — second run must NOT call put again
    expect(Engram.MockStorage, :put, 0, fn _, _, _ -> :ok end)
    stub_with(Engram.MockStorage, Engram.Storage.InMemory)

    assert :ok =
             perform_job(BackfillByteaToS3, %{user_id: user.id, vault_id: vault.id, cursor: 0})
  end

  test "S3 put failure leaves row unchanged" do
    user = insert(:user) |> Repo.reload!()
    vault = insert(:vault, user: user)
    att = insert_legacy_attachment(user, vault, "fail.pdf", "x")

    expect(Engram.MockStorage, :put, fn _, _, _ -> {:error, :timeout} end)

    assert {:error, _} =
             perform_job(BackfillByteaToS3, %{user_id: user.id, vault_id: vault.id, cursor: 0})

    reloaded = Repo.get!(Attachment, att.id, skip_tenant_check: true)
    assert reloaded.encryption_version == 0
    assert is_nil(reloaded.content_nonce)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && mix test test/engram/workers/backfill_bytea_to_s3_test.exs --trace`
Expected: FAIL — `Engram.Workers.BackfillByteaToS3` is undefined.

- [ ] **Step 3: Implement the worker**

```elixir
# backend/lib/engram/workers/backfill_bytea_to_s3.ex
defmodule Engram.Workers.BackfillByteaToS3 do
  @moduledoc """
  Backfills legacy plaintext-BYTEA attachments into encrypted S3 objects.

  Idempotent: rows with encryption_version=1 are skipped. Cursor-driven
  batches keep memory bounded. The BYTEA `content` column is intentionally
  left in place — PR #59 nulls it out after a deploy cycle.
  """
  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5,
    unique: [fields: [:args, :worker], keys: [:user_id, :vault_id], states: [:available, :scheduled, :executing, :retryable]]

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Repo
  alias Engram.Storage

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id, "cursor" => cursor}}) do
    with {:ok, user} <- load_user(user_id),
         {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, dek} <- Crypto.get_dek(user) do
      rows = legacy_batch(user_id, vault_id, cursor)

      Enum.reduce_while(rows, :ok, fn att, _acc ->
        case encrypt_one(att, dek) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        :ok ->
          if length(rows) == @batch_size do
            next_cursor = List.last(rows).id

            __MODULE__.new(%{user_id: user_id, vault_id: vault_id, cursor: next_cursor})
            |> Oban.insert()

            :ok
          else
            :ok
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp load_user(user_id) do
    case Accounts.get_user(user_id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp legacy_batch(user_id, vault_id, cursor) do
    Repo.all(
      from(a in Attachment,
        where:
          a.user_id == ^user_id and a.vault_id == ^vault_id and
            a.encryption_version == 0 and not is_nil(a.content) and a.id > ^cursor,
        order_by: [asc: a.id],
        limit: ^@batch_size
      ),
      skip_tenant_check: true
    )
  end

  defp encrypt_one(%Attachment{} = att, dek) do
    {ciphertext, nonce} = Envelope.encrypt(att.content, dek)
    key = att.storage_key || Storage.key(att.user_id, att.vault_id, att.path)

    with :ok <- Storage.adapter().put(key, ciphertext, content_type: att.mime_type) do
      {:ok, _} =
        att
        |> Attachment.changeset(%{
          encryption_version: 1,
          content_nonce: nonce,
          storage_key: key
        })
        |> Repo.update(skip_tenant_check: true)

      :ok
    else
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && mix test test/engram/workers/backfill_bytea_to_s3_test.exs --trace`
Expected: PASS for all three tests.

- [ ] **Step 5: Commit**

```bash
cd backend
git add lib/engram/workers/backfill_bytea_to_s3.ex test/engram/workers/backfill_bytea_to_s3_test.exs
git commit -m "feat(encryption): BackfillByteaToS3 Oban worker (idempotent, cursor-driven)"
```

---

## Task 7: Mix task wrapper

**Files:**
- Create: `backend/lib/mix/tasks/engram.backfill_bytea_to_s3.ex`

- [ ] **Step 1: Implement the mix task**

```elixir
# backend/lib/mix/tasks/engram.backfill_bytea_to_s3.ex
defmodule Mix.Tasks.Engram.BackfillByteaToS3 do
  @shortdoc "Enqueues BackfillByteaToS3 Oban jobs for every (user, vault) with legacy plaintext attachments"

  @moduledoc """
  Scans `attachments` for rows with `encryption_version = 0 AND content IS NOT NULL`
  and enqueues one `Engram.Workers.BackfillByteaToS3` job per distinct (user_id, vault_id)
  pair, with `cursor: 0`. Re-running is safe — `unique` constraints on the worker
  prevent duplicate enqueues.

  Run inside the engram release container:

      docker exec engram-saas /app/bin/engram eval \\
        'Mix.Task.run("engram.backfill_bytea_to_s3")'
  """
  use Mix.Task

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Repo
  alias Engram.Workers.BackfillByteaToS3

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    pairs =
      Repo.all(
        from(a in Attachment,
          where: a.encryption_version == 0 and not is_nil(a.content),
          distinct: true,
          select: {a.user_id, a.vault_id}
        ),
        skip_tenant_check: true
      )

    enqueued =
      Enum.map(pairs, fn {user_id, vault_id} ->
        {:ok, _} =
          BackfillByteaToS3.new(%{user_id: user_id, vault_id: vault_id, cursor: 0})
          |> Oban.insert()
      end)

    IO.puts("Enqueued #{length(enqueued)} jobs across #{length(pairs)} (user, vault) pairs")
  end
end
```

- [ ] **Step 2: Compile to confirm no syntax errors**

Run: `cd backend && mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 3: Smoke-test the task locally**

```
cd backend
# Insert a legacy attachment via iex, then:
mix engram.backfill_bytea_to_s3
# Output: "Enqueued 1 jobs across 1 (user, vault) pairs"
```

(If you don't have a legacy row to test against, this step is acceptable to skip with a `# n/a` note in the commit message — the worker tests already cover behavior.)

- [ ] **Step 4: Commit**

```bash
cd backend
git add lib/mix/tasks/engram.backfill_bytea_to_s3.ex
git commit -m "feat(encryption): mix engram.backfill_bytea_to_s3 wrapper task"
```

---

## Task 8: E2E coverage — encrypted attachment ciphertext at rest

**Files:**
- Create: `backend/e2e/helpers/crypto_probe.py` (resurrect from PR #55)
- Modify: `backend/e2e/helpers/cleanup.py` (resurrect `cleanup_minio_bucket`)
- Modify: `backend/e2e/conftest.py` (wire bucket cleanup into session teardown)
- Modify: `backend/e2e/tests/api_only/test_19_write_isolation.py` (add probe assertion)
- Modify: `backend/docker-compose.ci.yml` (re-add MinIO + minio-init services)
- Modify: `backend/.github/workflows/ci.yml` (re-add `CI_MINIO_CONTAINER` env var)

This task is the largest by line-count but mostly resurrection. Use `git show e78076c -- <path>` to read the version that landed in PR #55 and merge it back in.

- [ ] **Step 1: Resurrect crypto_probe.py from PR #55**

Run: `cd backend && git show e78076c -- e2e/helpers/crypto_probe.py > e2e/helpers/crypto_probe.py.tmp`

Inspect the file, then `mv e2e/helpers/crypto_probe.py.tmp e2e/helpers/crypto_probe.py`.

If `git show` produces a diff-formatted output instead of file content, run `git checkout e78076c -- e2e/helpers/crypto_probe.py` instead (this restores the file from that commit's tree). Then `git restore --staged e2e/helpers/crypto_probe.py` to unstage it; the file content stays.

- [ ] **Step 2: Resurrect cleanup_minio_bucket helper**

Run: `cd backend && git show e78076c -- e2e/helpers/cleanup.py | head -200`

Manually port the `cleanup_minio_bucket` function and the `full_cleanup()` wiring back into the current `e2e/helpers/cleanup.py`. The function uses `mc alias set local ... && mc rm --recursive --force local/<bucket>/`.

- [ ] **Step 3: Resurrect conftest wiring**

Run: `cd backend && git show e78076c -- e2e/conftest.py`

Port the `cleanup_minio_bucket` import + invocation in session teardown back into `backend/e2e/conftest.py`.

- [ ] **Step 4: Resurrect docker-compose.ci.yml MinIO services**

Run: `cd backend && git show e78076c -- docker-compose.ci.yml`

Apply the MinIO + minio-init service additions back to the current file. Engram service must declare `depends_on: minio-init: condition: service_completed_successfully` and have `STORAGE_BACKEND=s3`, `STORAGE_BUCKET=engram-saas-attachments`, `STORAGE_HOST=minio`, `STORAGE_PORT=9000`, `STORAGE_SCHEME=http://`, `STORAGE_ACCESS_KEY_ID=minioadmin`, `STORAGE_SECRET_ACCESS_KEY=minioadmin` env vars.

- [ ] **Step 5: Add CI_MINIO_CONTAINER env to ci.yml**

In `backend/.github/workflows/ci.yml`, alongside each occurrence of `CI_POSTGRES_CONTAINER: ${{ env.CI_PROJECT }}-postgres-1` (in the `e2e-clerk`, `e2e-local`, `e2e-browser` job env blocks), add:

```yaml
CI_MINIO_CONTAINER: ${{ env.CI_PROJECT }}-minio-1
```

- [ ] **Step 6: Add ciphertext-at-rest assertion to test_19**

In `backend/e2e/tests/api_only/test_19_write_isolation.py`, add a new test:

```python
def test_attachment_ciphertext_at_rest(api_client, vault_a):
    """When STORAGE_BACKEND=s3, freshly-uploaded attachment bytes in MinIO are ciphertext."""
    from e2e.helpers.crypto_probe import assert_attachment_ciphertext_at_rest

    plaintext = b"the quick brown fox jumps over the lazy dog"
    api_client.upload_attachment(vault_a, "fox.txt", plaintext)

    # Probe MinIO directly, fail if container unreachable in CI
    assert_attachment_ciphertext_at_rest(vault_a.id, "fox.txt", expected_min_size=len(plaintext) + 16)
```

(Adjust import paths + helper signatures to match the resurrected `crypto_probe.py`.)

- [ ] **Step 7: Run E2E suite locally to confirm it boots**

This step requires the local CI stack — run only if you have docker-compose set up:

```
cd backend
make ci-up
make e2e SCENARIO=test_19
make ci-down
```

Expected: `test_attachment_ciphertext_at_rest` passes. If you don't have the stack locally, defer to CI.

- [ ] **Step 8: Commit**

```bash
cd backend
git add e2e/helpers/crypto_probe.py e2e/helpers/cleanup.py e2e/conftest.py \
        e2e/tests/api_only/test_19_write_isolation.py \
        docker-compose.ci.yml .github/workflows/ci.yml
git commit -m "test(e2e): assert attachment ciphertext at rest in MinIO under STORAGE_BACKEND=s3"
```

---

## Task 9: Bump version + update operations doc

**Files:**
- Modify: `backend/mix.exs`
- Modify: `backend/docs/context/encryption-operations.md`

- [ ] **Step 1: Bump mix.exs**

Edit `backend/mix.exs`:

```elixir
version: "0.5.14",
```

- [ ] **Step 2: Add Phase A status block to operations doc**

In `backend/docs/context/encryption-operations.md`, locate the existing `## Status` section (or add one near the top). Append:

```markdown
### Phase A — Attachment encryption (PR #58, 0.5.14)

- New uploads encrypt before S3 put when `STORAGE_BACKEND=s3` is active.
- Legacy BYTEA reads continue to work unchanged (dual-flow `get_attachment`).
- `mix engram.backfill_bytea_to_s3` enqueues one Oban job per (user, vault) with legacy rows.
- Worker is idempotent and cursor-driven; rerun is safe.
- BYTEA column NOT yet dropped — happens in PR #60 after PR #59 cuts writes to S3-only.
- Telemetry events for encrypt/decrypt are deferred to PR #59 (Phase A reland keeps surface area minimal).
- See `docs/superpowers/plans/2026-05-02-encryption-attachments-reland.md` for the full reland plan + production runbook.
```

- [ ] **Step 3: Run precommit aliases**

Run: `cd backend && mix precommit`
Expected: clean (compile + format + tests).

- [ ] **Step 4: Commit**

```bash
cd backend
git add mix.exs docs/context/encryption-operations.md
git commit -m "chore: bump 0.5.14 + Phase A reland operations doc"
```

---

## Task 10: Open PR

- [ ] **Step 1: Push branch**

```bash
cd backend
git push -u origin feat/encryption-attachments-reland
```

- [ ] **Step 2: Open PR with explicit reland framing**

```bash
gh pr create --title "feat(encryption): Phase A reland — encrypt new attachments + BYTEA→S3 backfill" \
  --body "$(cat <<'EOF'
## Summary

Reland of Phase A from the Tier 2 encryption plan (`docs/encryption-tier-2-plan.md`). Original attempt was PR #55, reverted as PR #57 because it dropped the BYTEA column and the \`Storage.Database\` adapter without a backfill — would have vaporized 133 prod attachments.

This PR is **non-destructive**: legacy BYTEA storage stays operational, the column stays in place, and a new mix task migrates legacy rows to encrypted S3 in an idempotent, resumable way.

## Sequence

PR #58 (this) → run \`mix engram.backfill_bytea_to_s3\` on prod → verify → PR #59 (cut writes to S3-only) → PR #60 (drop BYTEA column + Storage.Database adapter).

See \`docs/superpowers/plans/2026-05-02-encryption-attachments-reland.md\` for the full plan + production runbook.

## What changed

- Migration: additive \`encryption_version\` (int default 0) + \`content_nonce\` (bytea) + partial index for backfill scan
- \`Engram.Attachments.upsert_attachment\`: encrypts before S3 put when active backend is S3
- \`Engram.Attachments.get_attachment\`: decrypts when \`encryption_version = 1\`; legacy BYTEA short-circuit unchanged
- \`Engram.Workers.BackfillByteaToS3\`: cursor-driven Oban worker, idempotent, batch=100
- \`mix engram.backfill_bytea_to_s3\`: scans for legacy rows + enqueues one job per (user, vault)
- E2E proof: \`test_attachment_ciphertext_at_rest\` asserts MinIO bytes are ciphertext under \`STORAGE_BACKEND=s3\`
- ETS-backed \`Engram.Storage.InMemory\` test adapter (default for \`config/test.exs\`)
- Version bump 0.5.13 → 0.5.14

## What did NOT change

- \`Engram.Storage.Database\` adapter still alive (PR #60 removes)
- \`attachments.content\` BYTEA column still present (PR #60 drops)
- Default \`STORAGE_BACKEND\` unchanged (\`database\`); operator flips to \`s3\` per the runbook before backfill
- Read path for legacy BYTEA rows unchanged

## Test plan

- [ ] CI green
- [ ] After merge + 0.5.14 deploy, confirm \`/api/health\` reports \`0.5.14\` on both 8000 + 8001
- [ ] Operator runs production runbook (steps 1-9 in plan doc)
- [ ] Verification gate: \`encryption_version = 1\` count matches legacy row count + MinIO object count

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Watch CI**

```bash
cd backend
gh pr checks <PR_NUMBER> --watch
```

Expected: all checks pass — `version-check`, `unit-tests`, `e2e-local`, `e2e-clerk`, `e2e-browser`.

If any check fails, stop here and triage. Do NOT merge until green.
