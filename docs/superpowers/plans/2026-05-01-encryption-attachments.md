# Encryption Tier 2 — Phase A (Attachments) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Encrypt all attachment bytes at rest in both BYTEA (Postgres) and S3 (Tigris/MinIO) using the existing per-user DEK. Mandatory from this phase onward, mixed-state read path during rollout, full backfill of legacy rows.

**Architecture:** Attachment crypto lives in `Engram.Attachments` context — adapters stay dumb byte sinks, no per-adapter duplication. Encrypt-on-write in `upsert_attachment/3`, decrypt-on-read in `get_attachment/3`. Nonce + version on the `attachments` row (single source of truth, not S3 metadata). Plaintext `content_hash` preserved for dedup. Backfill worker mirrors `EncryptVault`.

**Tech Stack:** Elixir 1.17 / Phoenix 1.8, Ecto, Oban, AES-256-GCM via `Engram.Crypto.Envelope`, ExAws S3, ExUnit, Python E2E (pytest + asyncpg).

---

## Decisions locked

1. **Crypto hook lives in `Engram.Attachments` context, not in storage adapters.** Both `Storage.Database` and `Storage.S3` keep their `Engram.Storage` byte-in/byte-out behaviour. One crypto path, two storage backends.
2. **Mandatory from Phase A.** Attachments do **not** consult `vault.encrypted` — every new write is `encryption_version = 1` regardless of toggle state. This is the Tier 2 commitment ("close holes before mandating"). Notes still respect the toggle until Phase D.
3. **No streaming.** 5MB attachment cap (`Attachment.max_attachment_bytes/0`) means in-memory encrypt is fine. S3 multipart not needed. Re-evaluate if/when cap is raised; document in TODO.
4. **Nonce on the row, not S3 metadata.** New `content_nonce :binary` column. Avoids the S3-metadata sidecar gotcha and keeps both adapters symmetric.
5. **`content_hash` is plaintext-of-plaintext.** Preserve dedup semantics, sync hashes, and conflict detection. Never hash ciphertext.
6. **DEK provisioning reuses `Crypto.ensure_user_dek/1`.** First encrypted attachment lazy-provisions the user DEK exactly like first encrypted note.
7. **Single PR.** Crypto lives in context → no clean BYTEA/S3 fork. Plan-doc's "separate sub-PRs" suggestion does not apply once the hook moves up.
8. **Mixed-state read.** `encryption_version = 0` → return raw plaintext (legacy). `encryption_version = 1` → decrypt with row's `content_nonce` + user DEK. After backfill is 100%, a *separate* PR (Phase A+1) drops the version=0 read path and requires non-null nonce.

## Files

- **Migration (new):** `priv/repo/migrations/<ts>_add_attachment_encryption.exs`
- **Schema (modify):** `lib/engram/attachments/attachment.ex` — add `encryption_version`, `content_nonce`; cast/validate.
- **Context (modify):** `lib/engram/attachments.ex` — encrypt-on-put, decrypt-on-get; pass ciphertext to storage adapter.
- **Backfill worker (new):** `lib/engram/workers/encrypt_attachments.ex`
- **Mix task (new):** `lib/mix/tasks/engram.encrypt_attachments.ex`
- **Tests (new/extend):**
  - `test/engram/attachments_test.exs` — encrypt round-trip, mixed-state read, hash invariance, mandatory write.
  - `test/engram/workers/encrypt_attachments_test.exs` — backfill batches, idempotency, finalize.
  - `e2e/tests/api_only/test_19_write_isolation.py` — assert ciphertext on disk (BYTEA + S3) post-upload.
- **Docs (modify):** `docs/context/encryption-operations.md` — add attachment status block.

---

## Task 1: Schema migration + changeset

**Files:**
- Create: `priv/repo/migrations/<ts>_add_attachment_encryption.exs`
- Modify: `lib/engram/attachments/attachment.ex`

- [ ] **Step 1: Generate migration**

Run: `mix ecto.gen.migration add_attachment_encryption`

Edit the generated file to:

```elixir
defmodule Engram.Repo.Migrations.AddAttachmentEncryption do
  use Ecto.Migration

  def change do
    alter table(:attachments) do
      add :encryption_version, :integer, null: false, default: 0
      add :content_nonce, :binary
    end

    create index(:attachments, [:encryption_version],
             where: "encryption_version = 0",
             name: :attachments_legacy_plaintext_idx)
  end
end
```

The partial index is the backfill worker's cursor source — it shrinks to zero post-rollout and disappears with the legacy-read drop PR.

- [ ] **Step 2: Run migration locally**

Run: `mix ecto.migrate`
Expected: `add_attachment_encryption` applied; `attachments_legacy_plaintext_idx` created.

- [ ] **Step 3: Update schema**

In `lib/engram/attachments/attachment.ex`, add the two fields and include them in `cast/3`:

```elixir
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
  # ...
end

def changeset(attachment, attrs) do
  attachment
  |> cast(attrs, [
    :path, :content, :content_hash, :mime_type, :size_bytes,
    :mtime, :user_id, :vault_id, :storage_key, :deleted_at,
    :encryption_version, :content_nonce
  ])
  |> validate_required([:path, :user_id, :vault_id, :content_hash, :mime_type, :size_bytes])
  |> validate_number(:size_bytes, less_than_or_equal_to: @max_attachment_bytes)
  |> validate_inclusion(:encryption_version, [0, 1])
  |> validate_nonce_consistency()
  |> unique_constraint([:user_id, :vault_id, :path], name: :attachments_user_vault_path_active_index)
end

defp validate_nonce_consistency(changeset) do
  case get_field(changeset, :encryption_version) do
    1 ->
      case get_field(changeset, :content_nonce) do
        nil -> add_error(changeset, :content_nonce, "required when encryption_version=1")
        _ -> changeset
      end
    _ -> changeset
  end
end
```

- [ ] **Step 4: Run existing test suite, confirm green**

Run: `mix test test/engram/attachments_test.exs --max-failures 1`
Expected: existing tests still pass (schema additions are nullable / defaulted).

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/*_add_attachment_encryption.exs lib/engram/attachments/attachment.ex
git commit -m "feat(encryption): add encryption_version + content_nonce to attachments"
```

---

## Task 2: Encrypt-on-put in `Attachments.upsert_attachment/3`

**Files:**
- Modify: `lib/engram/attachments.ex`
- Test: `test/engram/attachments_test.exs`

- [ ] **Step 1: Write failing test — encrypt-on-write round-trip**

Add to `test/engram/attachments_test.exs`:

```elixir
test "upsert_attachment encrypts content at rest", %{user: user, vault: vault} do
  plaintext = :crypto.strong_rand_bytes(1024)

  {:ok, att} =
    Attachments.upsert_attachment(user, vault, %{
      "path" => "secrets/blob.bin",
      "content_base64" => Base.encode64(plaintext),
      "mime_type" => "application/octet-stream"
    })

  raw = Repo.with_tenant(user.id, fn -> Repo.get!(Attachment, att.id) end) |> elem(1)

  assert raw.encryption_version == 1
  assert is_binary(raw.content_nonce) and byte_size(raw.content_nonce) == 12
  assert raw.content != plaintext, "content must be ciphertext at rest"
  assert raw.content_hash == :crypto.hash(:md5, plaintext) |> Base.encode16(case: :lower),
         "hash must be of plaintext, not ciphertext"

  {:ok, fetched} = Attachments.get_attachment(user, vault, "secrets/blob.bin")
  assert fetched.content == plaintext
end
```

- [ ] **Step 2: Run, verify red**

Run: `mix test test/engram/attachments_test.exs -k "encrypts content at rest"`
Expected: FAIL — `raw.encryption_version == 1` fails (still 0) and `raw.content == plaintext`.

- [ ] **Step 3: Implement encrypt-on-put**

In `lib/engram/attachments.ex`, modify `upsert_attachment/3` to encrypt before `prepare_upload`. Key shape:

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
       {:ok, user} <- Crypto.ensure_user_dek(user),
       {:ok, dek} <- Crypto.get_dek(user),
       {ciphertext, nonce} = Envelope.encrypt(plaintext, dek),
       {:ok, key, changeset_attrs} <-
         prepare_upload(user, vault, path, plaintext, ciphertext, nonce, mtime, explicit_mime),
       :ok <- store_external(key, ciphertext, changeset_attrs.mime_type) do
    # ... existing insert/update flow, no change ...
  end
end
```

Update `prepare_upload/7` to take `plaintext` (for hash + size) AND `ciphertext` + `nonce` (for storage):

```elixir
defp prepare_upload(user, vault, path, plaintext, ciphertext, nonce, mtime, explicit_mime) do
  mime = explicit_mime || detect_mime(path)
  hash = :crypto.hash(:md5, plaintext) |> Base.encode16(case: :lower)
  key = Storage.key(user.id, vault.id, path)
  backend = Storage.adapter()

  changeset_attrs =
    %{
      path: path,
      content_hash: hash,
      mime_type: mime,
      size_bytes: byte_size(plaintext),
      mtime: mtime,
      user_id: user.id,
      vault_id: vault.id,
      storage_key: key,
      deleted_at: nil,
      encryption_version: 1,
      content_nonce: nonce
    }
    |> maybe_include_content(backend, ciphertext)

  {:ok, key, changeset_attrs}
end
```

`maybe_include_content/3` is unchanged but now receives ciphertext.

`store_external/3` already takes a binary; pass `ciphertext` straight through. No adapter changes.

- [ ] **Step 4: Run test, verify green**

Run: `mix test test/engram/attachments_test.exs -k "encrypts content at rest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/attachments.ex test/engram/attachments_test.exs
git commit -m "feat(encryption): encrypt attachment bytes on upsert (BYTEA + S3)"
```

---

## Task 3: Decrypt-on-read in `Attachments.get_attachment/3`

**Files:**
- Modify: `lib/engram/attachments.ex`
- Test: `test/engram/attachments_test.exs`

- [ ] **Step 1: Write failing test — mixed-state read**

Add to `test/engram/attachments_test.exs`:

```elixir
test "get_attachment reads legacy plaintext (version=0) unchanged", %{user: user, vault: vault} do
  # Insert a row directly bypassing upsert to simulate a pre-Phase-A row
  legacy = :crypto.strong_rand_bytes(64)

  {:ok, _} =
    Repo.with_tenant(user.id, fn ->
      %Attachment{}
      |> Attachment.changeset(%{
        path: "legacy/old.bin",
        content: legacy,
        content_hash: :crypto.hash(:md5, legacy) |> Base.encode16(case: :lower),
        mime_type: "application/octet-stream",
        size_bytes: byte_size(legacy),
        user_id: user.id,
        vault_id: vault.id,
        storage_key: "#{user.id}/#{vault.id}/legacy/old.bin",
        encryption_version: 0
      })
      |> Repo.insert()
    end)

  {:ok, att} = Attachments.get_attachment(user, vault, "legacy/old.bin")
  assert att.content == legacy
end

test "get_attachment decrypts version=1 rows", %{user: user, vault: vault} do
  plaintext = "hello world"
  {:ok, _} =
    Attachments.upsert_attachment(user, vault, %{
      "path" => "fresh.txt",
      "content_base64" => Base.encode64(plaintext),
      "mime_type" => "text/plain"
    })

  {:ok, att} = Attachments.get_attachment(user, vault, "fresh.txt")
  assert att.content == plaintext
end
```

- [ ] **Step 2: Run, verify red on the version=1 case**

Run: `mix test test/engram/attachments_test.exs -k "decrypts version=1"`
Expected: FAIL — content is ciphertext, not "hello world".

- [ ] **Step 3: Implement decrypt-on-get**

In `lib/engram/attachments.ex`, wrap the existing fetch with a decrypt step:

```elixir
def get_attachment(user, vault, path) do
  path = PathSanitizer.sanitize(path)

  result =
    Repo.with_tenant(user.id, fn ->
      Repo.one(
        from(a in Attachment,
          where:
            a.path == ^path and a.user_id == ^user.id and a.vault_id == ^vault.id and
              is_nil(a.deleted_at)
        )
      )
    end)
    |> unwrap_tenant()

  case result do
    {:ok, nil} -> {:ok, nil}
    {:ok, %Attachment{} = att} -> hydrate_and_decrypt(att, user, vault, path)
    {:error, _} = err -> err
  end
end

defp hydrate_and_decrypt(%Attachment{content: nil, storage_key: key} = att, user, vault, path) do
  case Storage.adapter().get(key || Storage.key(user.id, vault.id, path)) do
    {:ok, bytes} -> decrypt_if_needed(%{att | content: bytes}, user)
    {:error, :not_found} ->
      require Logger
      Logger.error("Attachment blob missing for live row: id=#{att.id} key=#{key}")
      {:error, {:storage, :blob_missing}}
    {:error, reason} -> {:error, {:storage, reason}}
  end
end

defp hydrate_and_decrypt(%Attachment{} = att, user, _vault, _path),
  do: decrypt_if_needed(att, user)

defp decrypt_if_needed(%Attachment{encryption_version: 0} = att, _user), do: {:ok, att}

defp decrypt_if_needed(%Attachment{encryption_version: 1, content_nonce: nonce, content: ct} = att, user) do
  with {:ok, dek} <- Crypto.get_dek(user),
       {:ok, plaintext} <- Envelope.decrypt(ct, nonce, dek) do
    {:ok, %{att | content: plaintext}}
  else
    :error -> {:error, :decrypt_failed}
    {:error, _} = err -> err
  end
end
```

- [ ] **Step 4: Run both tests, verify green**

Run: `mix test test/engram/attachments_test.exs -k "get_attachment"`
Expected: PASS for both legacy and version=1.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/attachments.ex test/engram/attachments_test.exs
git commit -m "feat(encryption): decrypt attachments on read with mixed-state fallback"
```

---

## Task 4: Backfill worker `Engram.Workers.EncryptAttachments`

**Files:**
- Create: `lib/engram/workers/encrypt_attachments.ex`
- Test: `test/engram/workers/encrypt_attachments_test.exs`

- [ ] **Step 1: Write failing test — batch encrypts legacy rows**

`test/engram/workers/encrypt_attachments_test.exs`:

```elixir
defmodule Engram.Workers.EncryptAttachmentsTest do
  use Engram.DataCase, async: false
  alias Engram.Workers.EncryptAttachments
  alias Engram.Attachments
  alias Engram.Attachments.Attachment
  alias Engram.Repo

  setup do
    user = insert_user_with_dek!()
    vault = insert_vault!(user)
    {:ok, user: user, vault: vault}
  end

  test "encrypts all legacy attachments in a vault", %{user: user, vault: vault} do
    legacies = for i <- 1..3 do
      bytes = :crypto.strong_rand_bytes(32)
      insert_legacy_attachment!(user, vault, "f#{i}.bin", bytes)
      {"f#{i}.bin", bytes}
    end

    assert :ok =
             EncryptAttachments.perform(%Oban.Job{
               args: %{"vault_id" => vault.id, "user_id" => user.id, "cursor" => 0}
             })

    for {path, bytes} <- legacies do
      raw = raw_attachment(user, vault, path)
      assert raw.encryption_version == 1
      assert is_binary(raw.content_nonce)
      {:ok, att} = Attachments.get_attachment(user, vault, path)
      assert att.content == bytes
    end
  end
end
```

(Helpers `insert_user_with_dek!`, `insert_vault!`, `insert_legacy_attachment!`, `raw_attachment` mirror the patterns in `Engram.Workers.EncryptVaultTest`. Lift them via `Engram.DataCase` if not already there.)

- [ ] **Step 2: Run, verify red**

Run: `mix test test/engram/workers/encrypt_attachments_test.exs`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement worker**

`lib/engram/workers/encrypt_attachments.ex`:

```elixir
defmodule Engram.Workers.EncryptAttachments do
  @moduledoc """
  Backfill-encrypts every plaintext attachment in a vault. Mirrors
  `Engram.Workers.EncryptVault`: batch of 100 per job, per-row atomicity,
  cursor-resumable on crash, self-re-enqueue until exhausted.
  """

  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5,
    unique: [keys: [:vault_id], states: [:available, :scheduled]]

  import Ecto.Query
  require Logger

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Vaults.Vault

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"vault_id" => vault_id, "user_id" => user_id, "cursor" => cursor}}) do
    case load_batch(vault_id, user_id, cursor) do
      :noop -> :ok
      {:error, _} = err -> err
      {:ok, %{user: user, vault: vault, atts: []}} -> finalize(vault, 0)
      {:ok, %{user: user, vault: vault, atts: atts}} ->
        commit_batch(user, vault, atts, cursor)
    end
  end

  defp load_batch(vault_id, user_id, cursor) do
    Repo.with_tenant(user_id, fn ->
      vault = Repo.get!(Vault, vault_id)
      user = Repo.get!(User, user_id)

      with {:ok, user} <- Crypto.ensure_user_dek(user) do
        atts =
          from(a in Attachment,
            where:
              a.vault_id == ^vault.id and
                a.encryption_version == 0 and
                a.id > ^cursor and
                is_nil(a.deleted_at),
            order_by: [asc: a.id],
            limit: @batch_size
          )
          |> Repo.all()

        {:ok, %{user: user, vault: vault, atts: atts}}
      end
    end)
    |> unwrap()
  end

  defp commit_batch(user, vault, atts, _cursor) do
    {:ok, dek} = Crypto.get_dek(user)

    Repo.with_tenant(user.id, fn ->
      Enum.reduce_while(atts, {:ok, 0}, fn att, {:ok, _} ->
        case encrypt_one(att, user, vault, dek) do
          :ok -> {:cont, {:ok, att.id}}
          {:error, reason} = err ->
            Logger.error("EncryptAttachments failed att #{att.id}: #{inspect(reason)}")
            {:halt, err}
        end
      end)
    end)
    |> unwrap()
    |> case do
      {:ok, last_id} ->
        if length(atts) == @batch_size,
          do: enqueue_next(vault, user, last_id),
          else: finalize(vault, length(atts))
      err ->
        err
    end
  end

  defp encrypt_one(%Attachment{content: nil, storage_key: key} = att, user, vault, dek) do
    with {:ok, plaintext} <- Storage.adapter().get(key || Storage.key(user.id, vault.id, att.path)),
         {ct, nonce} = Envelope.encrypt(plaintext, dek),
         :ok <- Storage.adapter().put(key, ct, content_type: att.mime_type),
         {:ok, _} <- update_row(att, ct, nonce, _persist_bytea? = false) do
      :ok
    end
  end

  defp encrypt_one(%Attachment{content: bytes} = att, _user, _vault, dek) when is_binary(bytes) do
    {ct, nonce} = Envelope.encrypt(bytes, dek)

    case update_row(att, ct, nonce, _persist_bytea? = true) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp update_row(att, ct, nonce, persist_bytea?) do
    attrs = %{encryption_version: 1, content_nonce: nonce}
    attrs = if persist_bytea?, do: Map.put(attrs, :content, ct), else: attrs

    att
    |> Attachment.changeset(attrs)
    |> Repo.update()
  end

  defp enqueue_next(vault, user, last_id) do
    case __MODULE__.new(%{vault_id: vault.id, user_id: user.id, cursor: last_id}) |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: false}} -> :ok
      {:ok, %Oban.Job{conflict?: true}} -> {:error, :next_batch_conflict}
      {:error, _} = err -> err
    end
  end

  defp finalize(vault, count) do
    :telemetry.execute(
      [:engram, :crypto, :attachment_backfill, :vault_done],
      %{processed: count},
      %{vault_id: vault.id}
    )
    :ok
  end

  defp unwrap({:ok, inner}), do: inner
  defp unwrap(other), do: other
end
```

Key shape difference from `EncryptVault`: there's no per-vault status flag for attachments (no `vault.attachments_encrypted`) — finalize is a telemetry-only no-op. The legacy partial index from Task 1 is the source of truth: empty index = backfill complete.

- [ ] **Step 4: Run test, verify green**

Run: `mix test test/engram/workers/encrypt_attachments_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/workers/encrypt_attachments.ex test/engram/workers/encrypt_attachments_test.exs
git commit -m "feat(encryption): backfill worker for legacy attachments"
```

---

## Task 5: Mix task to enqueue backfill for all vaults

**Files:**
- Create: `lib/mix/tasks/engram.encrypt_attachments.ex`
- Test: `test/mix/tasks/engram.encrypt_attachments_test.exs`

- [ ] **Step 1: Write failing test — task enqueues one job per vault with legacy rows**

```elixir
defmodule Mix.Tasks.Engram.EncryptAttachmentsTest do
  use Engram.DataCase, async: false
  alias Engram.Workers.EncryptAttachments

  test "enqueues a job for each vault holding legacy attachments" do
    user = insert_user_with_dek!()
    vault_a = insert_vault!(user)
    vault_b = insert_vault!(user)
    insert_legacy_attachment!(user, vault_a, "x.bin", "abc")
    # vault_b intentionally empty

    Mix.Tasks.Engram.EncryptAttachments.run([])

    assert_enqueued worker: EncryptAttachments, args: %{"vault_id" => vault_a.id, "cursor" => 0}
    refute_enqueued worker: EncryptAttachments, args: %{"vault_id" => vault_b.id}
  end
end
```

- [ ] **Step 2: Run, verify red**

Run: `mix test test/mix/tasks/engram.encrypt_attachments_test.exs`
Expected: FAIL — task module missing.

- [ ] **Step 3: Implement task**

```elixir
defmodule Mix.Tasks.Engram.EncryptAttachments do
  use Mix.Task
  import Ecto.Query
  alias Engram.{Attachments.Attachment, Repo, Workers.EncryptAttachments}

  @shortdoc "Enqueue attachment backfill for every vault with legacy plaintext rows"
  def run(_args) do
    Mix.Task.run("app.start")

    pairs =
      from(a in Attachment,
        where: a.encryption_version == 0 and is_nil(a.deleted_at),
        distinct: true,
        select: {a.user_id, a.vault_id}
      )
      |> Repo.all(prefix: nil, skip_tenant_check: true)

    Enum.each(pairs, fn {uid, vid} ->
      EncryptAttachments.new(%{user_id: uid, vault_id: vid, cursor: 0})
      |> Oban.insert()
    end)

    Mix.shell().info("Enqueued backfill for #{length(pairs)} vault(s)")
  end
end
```

(Confirm the cross-tenant query escape hatch matches existing patterns — see `Mix.Tasks.Engram.SetCooldown` if it exists, or the toggle's batch enqueuer in the Phase 6 work. If the project's `Repo.with_tenant/2` does not support `skip_tenant_check`, use raw SQL via `Repo.query!`.)

- [ ] **Step 4: Run test, verify green**

Run: `mix test test/mix/tasks/engram.encrypt_attachments_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/engram.encrypt_attachments.ex test/mix/tasks/engram.encrypt_attachments_test.exs
git commit -m "feat(encryption): mix task to enqueue attachment backfill across all vaults"
```

---

## Task 6: E2E proof of ciphertext at rest

**Files:**
- Modify: `e2e/tests/api_only/test_19_write_isolation.py`

- [ ] **Step 1: Add ciphertext-on-disk assertion**

Append a new test to `test_19_write_isolation.py`:

```python
@pytest.mark.asyncio
async def test_attachment_ciphertext_at_rest(api_sync, db_pool):
    """Uploaded attachments must be ciphertext in BYTEA and (when applicable) Tigris."""
    plaintext = b"\x89PNG\r\n\x1a\n" + os.urandom(512)
    att_path = f"e2e/cipher-proof-{uuid.uuid4().hex}.png"

    status = api_sync.upload_attachment(att_path, plaintext)
    assert status == 200, f"upload failed: {status}"

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            SELECT encryption_version, content_nonce, content, storage_key
              FROM attachments
             WHERE user_id = $1 AND path = $2 AND deleted_at IS NULL
            """,
            api_sync.user_id, att_path,
        )

    assert row is not None
    assert row["encryption_version"] == 1
    assert row["content_nonce"] is not None and len(row["content_nonce"]) == 12

    if row["content"] is not None:
        # Database adapter — BYTEA must NOT contain plaintext
        assert plaintext not in row["content"], "BYTEA still plaintext"
        assert row["content"] != plaintext

    # Round-trip via API (server decrypt path)
    resp = api_sync.get_attachment(att_path)
    assert resp.content == plaintext, "API round-trip must return plaintext"
```

If the E2E suite runs against the S3 adapter, also add a `boto3`/`aiobotocore` raw-get assertion (gate on env). Skip block if not configured.

- [ ] **Step 2: Run E2E suite locally against CI stack**

Run: `make ci-up && make e2e -k "ciphertext_at_rest or write_isolation"` (then `make ci-down`).
Expected: new test passes; no regression in test_19's existing cases.

- [ ] **Step 3: Commit**

```bash
git add e2e/tests/api_only/test_19_write_isolation.py
git commit -m "test(e2e): assert attachment ciphertext on disk after upload"
```

---

## Task 7: Telemetry + operator runbook update

**Files:**
- Modify: `lib/engram/attachments.ex` (telemetry events)
- Modify: `docs/context/encryption-operations.md` (status block)

- [ ] **Step 1: Emit telemetry on encrypt + decrypt**

In `Attachments.upsert_attachment`:

```elixir
:telemetry.execute(
  [:engram, :crypto, :attachment, :encrypted],
  %{bytes: byte_size(plaintext)},
  %{user_id: user.id, vault_id: vault.id}
)
```

In `decrypt_if_needed/2` for the version=1 success branch, mirror with `[:engram, :crypto, :attachment, :decrypted]`.

(Wire to PromEx if a `Crypto` plugin exists; otherwise leave as raw events for follow-up.)

- [ ] **Step 2: Update encryption-operations.md status block**

Add a subsection under `## Status`:

```markdown
### Attachments (Tier 2 Phase A — shipped <date>)

- All new attachment writes are AES-256-GCM encrypted at rest (`encryption_version = 1`).
- Mixed-state read path: rows with `encryption_version = 0` return plaintext (legacy).
- Backfill: `mix engram.encrypt_attachments` enqueues `Engram.Workers.EncryptAttachments` per vault. Cursor on `attachments.id`, batch 100, idempotent.
- Drop-legacy PR follows once `SELECT count(*) FROM attachments WHERE encryption_version = 0 AND deleted_at IS NULL` is zero across prod for ≥7 days.
```

- [ ] **Step 3: Commit**

```bash
git add lib/engram/attachments.ex docs/context/encryption-operations.md
git commit -m "feat(encryption): telemetry + runbook update for attachment encryption"
```

---

## Task 8: Open PR

**Pre-PR sanity:**
- [ ] `mix format --check-formatted`
- [ ] `mix credo --strict` (existing baseline only — don't fix unrelated)
- [ ] `mix test` (full suite)
- [ ] `make ci-up && make e2e && make ci-down` (full E2E suite)

**PR title:** `feat(encryption): Tier 2 Phase A — encrypt attachments at rest`

**PR body:**

```markdown
## Summary
- Encrypt all attachment bytes at rest (BYTEA + Tigris/MinIO) using per-user DEK.
- Mandatory from Phase A; vault.encrypted toggle is bypassed for attachments.
- Mixed-state read path (encryption_version 0 = legacy plaintext, 1 = encrypted).
- `Engram.Workers.EncryptAttachments` backfill worker + `mix engram.encrypt_attachments` task.
- E2E proves ciphertext on disk post-upload, plaintext via API round-trip.

Implements Phase A of `engram-workspace/docs/encryption-tier-2-plan.md`.
Legacy plaintext drop and bumping the 5MB cap are explicit follow-ups.

## Test plan
- [x] `mix test` (unit, including new attachment + worker tests)
- [x] `make e2e` (test_19 ciphertext-at-rest assertion + existing isolation tests)
- [ ] Manual: upload via plugin → fetch via plugin → byte-equal
- [ ] Manual: backfill task on vault 6 (104 plaintext attachments) — verify version=1 across all rows, no read errors
```

---

## Out of scope (explicit follow-ups)

1. **Drop legacy plaintext read path.** Separate PR after backfill completes in prod for 7 days.
2. **Streaming + S3 multipart.** Re-evaluate when 5MB cap is raised. Plan calls for "100MB+ fixture" — defer until cap moves.
3. **Re-key on KMS migration.** Phase F.0 work; orthogonal — attachment rows already provider-agnostic via `Crypto.get_dek/1`.
4. **Path / folder / tag HMAC.** Phase B.
5. **Log redaction (attachment filenames).** Phase C will audit `Logger` calls for `key`, `path`, `att.path`.

## Open questions

1. **Which storage adapter does prod actually use?** `config/runtime.exs` flips between `S3` and `Database` — confirm Fly.io config selects `S3` for vault attachments, otherwise the BYTEA path dominates and the S3 multipart concern is moot regardless of cap. Verify before opening PR.
2. **Backfill rate-limit?** EncryptVault has no Oban concurrency knob; for Tigris-backed users, 100 attachments/batch could spike S3 PUTs. Add `priority` or `unique` window if needed.
3. **Does `Repo.with_tenant/2` accept `skip_tenant_check`?** Mix task's cross-tenant scan needs a clear escape hatch — check the Phase 6 toggle's batch enqueuer for the established pattern before relying on it.
