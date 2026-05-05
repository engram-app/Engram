# Encryption Phase B — HMAC for Filterable Fields Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mandatory at-rest encryption for note paths, folder names, tags, attachment paths, and vault names — closes the last large plaintext leak under Tier 2.

**Architecture:** Per-user filter key derived from the user's DEK via HKDF (info string `"engram-filter-v1"`), computed on demand and never stored. Each filterable field stores both an HMAC-SHA256 fingerprint (for indexed equality lookups) and an envelope-encrypted display value (decrypted at fetch). BYOK-ready by construction — DEK is the linchpin, master/CMK keys are interchangeable wrapping layers.

**Tech Stack:** Elixir 1.17+, Phoenix 1.8+, Ecto/Postgres (btree on scalar HMACs, GIN on array `tags_hmac`), Qdrant (payload re-upsert), Oban (backfill workers), `:crypto.mac/4` (HMAC), existing `Engram.Crypto.Envelope` (AES-GCM).

---

## Background

Phase A made attachment **bytes** mandatory-encrypted in S3 (PRs #58–#62). Phase B closes the parallel hole: file paths, folder names, tags, and vault names are still plaintext in Postgres rows and in Qdrant payload. Anyone exfiltrating the DB without the master key cannot read note content, but they can read the entire file tree — which for many users (clients/cases/projects) is itself sensitive.

**Production sizing as of 2026-05-02 (informs migration tactics):**
- Saas: 3 users, 10 vaults, **805 notes** (793 owned by `user_id=2` = 98.5%), 106 attachments, 76 notes-with-tags (189 tag instances), 151 distinct folders.
- Selfhost: 0 notes, 0 attachments — no migration needed.
- Migration is small. Backfill runs in seconds. `user_id=2` on saas is the smoke target.

**Migration shape — 3-PR sequence mirroring Phase A.1 → A.4 → A.5:**
- **B.1 (PR #1)** adds the new columns, dual-writes on every upsert path, ships the backfill worker. Reads stay on plaintext columns. Backfill is mandatory regardless of vault toggle.
- **B.2 (PR #2)** switches reads to HMAC lookups + decrypted display values. Qdrant payload re-upsert worker. After this PR, plaintext columns are write-only and unreferenced for reads.
- **B.3 (PR #3)** drops plaintext columns, removes dual-write code, deletes the backfill worker. Migration's `down/0` raises (irreversible — same as A.5).

**Why mandatory from day one:** The vault encryption toggle (Phases 1–6) governs note **content** only. Phase B paths/folders/tags follow Phase A's model — encrypt unconditionally, no toggle gate. This decouples Phase B from the toggle (which dies under Phase E) and makes the marketing claim "all path metadata encrypted at rest" honest immediately.

**Critical existing patterns to read before starting:**
- `git show 171ce9e:backend/lib/engram/workers/backfill_bytea_to_s3.ex` — shape of the backfill worker (cursor-driven, per-(user, vault), idempotent on retry). This file was deleted in A.5; the historical version is the template for Phase B's backfill worker.
- `git show 29a7bd4:backend/lib/engram/attachments.ex` — Phase A.5 read-path collapse showing how to cleanly cut over from dual-shape to single-shape.
- `lib/engram/crypto.ex` — current envelope encryption helpers; `dek_filter_key/1` lives here.
- `lib/engram/crypto/envelope.ex` — `encrypt/2` and `decrypt/3` AES-GCM helpers (12-byte nonce, 16-byte GCM tag).
- `lib/engram/repo.ex` — multi-tenant `with_tenant/2` always returns `{:ok, result}` tuple. Destructure carefully or unwrap with `elem(1)`.
- `test/support/log_capture.ex` — for tests asserting on log metadata.

**Critical testing patterns to follow:**
- `Mox.stub_with(MockStorage, InMemory)` per-process for storage stubbing.
- `async: false` on any test that mutates `Application.put_env(:engram, ...)` — async:true tests run concurrently first, then async:false serially. A stray async:true test that flips global config will straddle other tests and fail intermittently. Lesson from PR #61.
- Tests touching multi-tenant Repo must call `Engram.Repo.with_tenant/2` and destructure `{:ok, val}`.

---

## File Structure

| Path | Responsibility |
|------|----------------|
| `lib/engram/crypto.ex` | Add `dek_filter_key/1` deriving HMAC key from DEK via HKDF |
| `lib/engram/notes/note.ex` | Schema: add `path_*`, `folder_*`, `tags_hmac` columns. Validations relax in B.1, tighten in B.3 |
| `lib/engram/attachments/attachment.ex` | Schema: add `path_*` columns |
| `lib/engram/vaults/vault.ex` | Schema: add `name_*` columns |
| `lib/engram/notes.ex` | `upsert_note/2` dual-write (B.1), `get_by_path/3` HMAC lookup (B.2), distinct-folder query rewrite (B.2), drop dual-write (B.3) |
| `lib/engram/attachments.ex` | `upsert_attachment/3` dual-write (B.1), `get_attachment/3` already-encrypted (B.2 path decryption), drop dual-write (B.3) |
| `lib/engram/vaults.ex` | `create_vault/2`, `update_vault/2` dual-write (B.1), `list_vaults/1` decrypt names (B.2), drop dual-write (B.3) |
| `lib/engram/search.ex` | `do_search/4` translates folder/tag filter args to HMAC equality predicates (B.2) |
| `lib/engram/vector/qdrant.ex` | Payload uses `folder_hmac` / `tags_hmac` keys (B.2). New points-upsert helper for backfill worker |
| `lib/engram_web/controllers/folders_controller.ex` | `list/2` returns decrypted folder names (B.2) |
| `lib/engram_web/controllers/notes_controller.ex` | `show/2` returns decrypted path (B.2) |
| `lib/engram_web/controllers/attachments_controller.ex` | `show/2` returns decrypted path (B.2) |
| `lib/engram_web/controllers/vaults_controller.ex` | `index/2` returns decrypted names (B.2) |
| `lib/engram/workers/backfill_phase_b_hmac.ex` | Oban worker, cursor-driven, per-(user, vault). Created B.1, deleted B.3 |
| `lib/engram/workers/qdrant_payload_phase_b.ex` | Re-upsert all Qdrant points with new payload shape. Created B.2, deleted B.3 |
| `lib/mix/tasks/engram.backfill_phase_b_hmac.ex` | Operator entry point to enqueue backfill. Created B.1, deleted B.3 |
| `priv/repo/migrations/<ts>_phase_b_add_hmac_columns.exs` | B.1 — adds columns + indexes |
| `priv/repo/migrations/<ts>_drop_phase_b_plaintext_columns.exs` | B.3 — irreversible drop |
| `mix.exs` | Version bumps: 0.5.23 (B.1), 0.5.24 (B.2), 0.5.25 (B.3) |

---

# Phase B.1 — Schema + Dual-Write + Backfill (PR #1)

**Branch:** `feat/encryption-phase-b1-schema-dual-write` off `main`.

**Pre-task setup:**

```bash
cd backend
git switch main && git pull --ff-only
git switch -c feat/encryption-phase-b1-schema-dual-write
```

### Task B.1.0: Bump version

**Files:**
- Modify: `mix.exs:7`

- [ ] **Step 1: Edit version**

```elixir
version: "0.5.23",
```

- [ ] **Step 2: Verify**

Run: `grep version: mix.exs | head -1`
Expected: `      version: "0.5.23",`

- [ ] **Step 3: Commit**

```bash
git add mix.exs
git commit -m "chore: bump version to 0.5.23 for Phase B.1"
```

---

### Task B.1.1: Add `dek_filter_key/1` helper to `Engram.Crypto`

Returns 32-byte deterministic HMAC key derived from the user's DEK. Same DEK + same info string always produces the same filter key. Different users (different DEKs) produce different filter keys. Used downstream by every HMAC computation.

**Files:**
- Modify: `lib/engram/crypto.ex`
- Test: `test/engram/crypto_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/engram/crypto_test.exs` (within the existing module):

```elixir
describe "dek_filter_key/1" do
  test "returns a deterministic 32-byte key for the same user" do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)

    {:ok, key1} = Engram.Crypto.dek_filter_key(user)
    {:ok, key2} = Engram.Crypto.dek_filter_key(user)

    assert is_binary(key1)
    assert byte_size(key1) == 32
    assert key1 == key2
  end

  test "returns different keys for different users" do
    user_a = insert(:user) |> Engram.Crypto.ensure_user_dek() |> elem(1)
    user_b = insert(:user) |> Engram.Crypto.ensure_user_dek() |> elem(1)

    {:ok, key_a} = Engram.Crypto.dek_filter_key(user_a)
    {:ok, key_b} = Engram.Crypto.dek_filter_key(user_b)

    refute key_a == key_b
  end

  test "is independent of the DEK itself (HKDF separation)" do
    user = insert(:user) |> Engram.Crypto.ensure_user_dek() |> elem(1)
    {:ok, dek} = Engram.Crypto.get_dek(user)
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)

    refute filter_key == dek
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/engram/crypto_test.exs --only describe:"dek_filter_key/1"`
Expected: FAIL with `(UndefinedFunctionError) function Engram.Crypto.dek_filter_key/1 is undefined`

- [ ] **Step 3: Implement the function**

Append to `lib/engram/crypto.ex` (above the final `end`):

```elixir
@filter_key_info "engram-filter-v1"

@doc """
Derives a 32-byte HMAC filter key from the user's DEK using HKDF.

Used for deterministic fingerprinting of filterable fields (path, folder,
tags, vault name). The key is HKDF-Expand of the DEK with versioned info
string `"engram-filter-v1"`. Computed on demand — never stored.

BYOK-ready: the DEK is always available in plaintext after the configured
KeyProvider unwraps it, regardless of whether the wrapping CMK is local,
AWS KMS, or a customer-supplied CMK. Filter key derivation is identical
across providers.

Returns `{:ok, filter_key}` or `{:error, reason}` propagated from `get_dek/1`.
"""
def dek_filter_key(user) do
  with {:ok, dek} <- get_dek(user) do
    {:ok, :crypto.mac(:hmac, :sha256, dek, @filter_key_info)}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/engram/crypto_test.exs --only describe:"dek_filter_key/1"`
Expected: PASS — 3 tests, 0 failures.

- [ ] **Step 5: Format**

Run: `mix format lib/engram/crypto.ex test/engram/crypto_test.exs`

- [ ] **Step 6: Commit**

```bash
git add lib/engram/crypto.ex test/engram/crypto_test.exs
git commit -m "feat(crypto): add dek_filter_key/1 — HKDF-derived per-user HMAC key"
```

---

### Task B.1.2: Add public `hmac_field/2` helper

Wraps `:crypto.mac/4` for callers that have a filter key + plaintext string. Centralizes the algorithm choice (HMAC-SHA256) so future v2 swaps happen in one place. Returns `binary()`.

**Files:**
- Modify: `lib/engram/crypto.ex`
- Test: `test/engram/crypto_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram/crypto_test.exs` describe block "hmac_field/2":

```elixir
describe "hmac_field/2" do
  test "returns deterministic 32-byte binary" do
    key = :crypto.strong_rand_bytes(32)

    h1 = Engram.Crypto.hmac_field(key, "projects/2026-q3")
    h2 = Engram.Crypto.hmac_field(key, "projects/2026-q3")

    assert is_binary(h1)
    assert byte_size(h1) == 32
    assert h1 == h2
  end

  test "different inputs yield different hashes for the same key" do
    key = :crypto.strong_rand_bytes(32)

    refute Engram.Crypto.hmac_field(key, "a") == Engram.Crypto.hmac_field(key, "b")
  end

  test "different keys yield different hashes for the same input" do
    k1 = :crypto.strong_rand_bytes(32)
    k2 = :crypto.strong_rand_bytes(32)

    refute Engram.Crypto.hmac_field(k1, "x") == Engram.Crypto.hmac_field(k2, "x")
  end
end
```

- [ ] **Step 2: Run to verify fail**

Run: `mix test test/engram/crypto_test.exs --only describe:"hmac_field/2"`
Expected: FAIL with undefined function.

- [ ] **Step 3: Implement**

Append to `lib/engram/crypto.ex`:

```elixir
@doc """
Computes an HMAC-SHA256 fingerprint of `value` using `filter_key`.

Used to produce indexed equality predicates on encrypted-at-rest fields:
`WHERE folder_hmac = hmac_field(filter_key, "projects/2026-q3")`.

Always 32 bytes. Deterministic — same inputs always produce the same
output, which is what makes equality lookups possible. This is also why
the filter key MUST NOT be reused for content encryption (same-key reuse
across deterministic and randomized cryptographic operations weakens both).
"""
@spec hmac_field(binary(), binary()) :: binary()
def hmac_field(filter_key, value)
    when is_binary(filter_key) and byte_size(filter_key) == 32 and is_binary(value) do
  :crypto.mac(:hmac, :sha256, filter_key, value)
end
```

- [ ] **Step 4: Verify pass**

Run: `mix test test/engram/crypto_test.exs --only describe:"hmac_field/2"`
Expected: PASS — 3 tests, 0 failures.

- [ ] **Step 5: Format + commit**

```bash
mix format lib/engram/crypto.ex test/engram/crypto_test.exs
git add lib/engram/crypto.ex test/engram/crypto_test.exs
git commit -m "feat(crypto): add hmac_field/2 — HMAC-SHA256 helper for filterable fields"
```

---

### Task B.1.3: Migration adds Phase B columns + indexes

Single migration creates all new columns across `notes`, `attachments`, `vaults`. All nullable in B.1 — backfill populates them. Phase B.3 will tighten validations + drop plaintext columns.

**Files:**
- Create: `priv/repo/migrations/20260502170000_phase_b_add_hmac_columns.exs`

- [ ] **Step 1: Create the migration file**

```elixir
defmodule Engram.Repo.Migrations.PhaseBAddHmacColumns do
  use Ecto.Migration

  # Phase B.1 — adds HMAC fingerprint + envelope-encrypted display columns
  # for path, folder, tags, attachment path, and vault name. All nullable
  # at this stage; backfill populates legacy rows. Phase B.3 tightens to
  # NOT NULL after backfill is verified at 100%.

  def change do
    alter table(:notes) do
      add :path_ciphertext, :binary
      add :path_nonce, :binary
      add :path_hmac, :binary
      add :folder_ciphertext, :binary
      add :folder_nonce, :binary
      add :folder_hmac, :binary
      add :tags_hmac, {:array, :binary}, default: []
      # tags_ciphertext + tags_nonce already exist from Phase 4.
    end

    alter table(:attachments) do
      add :path_ciphertext, :binary
      add :path_nonce, :binary
      add :path_hmac, :binary
    end

    alter table(:vaults) do
      add :name_ciphertext, :binary
      add :name_nonce, :binary
      add :name_hmac, :binary
    end

    create index(:notes, [:user_id, :vault_id, :path_hmac])
    create index(:notes, [:user_id, :vault_id, :folder_hmac])
    create index(:notes, [:tags_hmac], using: "GIN")
    create index(:attachments, [:user_id, :vault_id, :path_hmac])
    create index(:vaults, [:user_id, :name_hmac])
  end
end
```

- [ ] **Step 2: Run migration**

Run: `mix ecto.migrate`
Expected:
```
[info] == Running 20260502170000 Engram.Repo.Migrations.PhaseBAddHmacColumns.change/0 forward
[info] alter table notes
[info] alter table attachments
[info] alter table vaults
[info] create index notes_user_id_vault_id_path_hmac_index
[info] create index notes_user_id_vault_id_folder_hmac_index
[info] create index notes_tags_hmac_index
[info] create index attachments_user_id_vault_id_path_hmac_index
[info] create index vaults_user_id_name_hmac_index
[info] == Migrated 20260502170000 in 0.0s
```

- [ ] **Step 3: Verify columns exist**

Run: `mix run -e "Engram.Repo.query!(\"SELECT column_name FROM information_schema.columns WHERE table_name = 'notes' AND column_name LIKE '%hmac%' ORDER BY column_name\") |> Map.get(:rows) |> List.flatten() |> IO.inspect()"`
Expected: `["folder_hmac", "path_hmac", "tags_hmac"]`

- [ ] **Step 4: Run full test suite to ensure nothing broke**

Run: `mix test`
Expected: All existing tests pass (852 currently). Schema additions are additive and nullable, so no test should fail at this point.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/20260502170000_phase_b_add_hmac_columns.exs
git commit -m "feat(db): add Phase B HMAC + ciphertext columns and indexes"
```

---

### Task B.1.4: `Note` schema declares the new fields

Schema-only change — no validations tighten yet. Phase B.3 makes the columns required.

**Files:**
- Modify: `lib/engram/notes/note.ex`

- [ ] **Step 1: Read the existing schema first**

Run: `cat lib/engram/notes/note.ex`

Note the existing `field :path, :string`, `field :folder, :string`, `field :tags, {:array, :string}`, `field :title_ciphertext`, `field :tags_ciphertext`, `field :tags_nonce`. The new fields fit alongside.

- [ ] **Step 2: Add fields**

Find the schema block opening `schema "notes" do` and add (placement: with the other ciphertext/nonce fields that already exist for Phase 4):

```elixir
field :path_ciphertext, :binary
field :path_nonce, :binary
field :path_hmac, :binary
field :folder_ciphertext, :binary
field :folder_nonce, :binary
field :folder_hmac, :binary
field :tags_hmac, {:array, :binary}, default: []
```

- [ ] **Step 3: Add fields to `cast/3` allowlist in the changeset function**

Find `cast/3` in the changeset and add the same field names to the cast list:

```elixir
[..., :path_ciphertext, :path_nonce, :path_hmac, :folder_ciphertext, :folder_nonce, :folder_hmac, :tags_hmac]
```

- [ ] **Step 4: Run full suite**

Run: `mix test`
Expected: 852 tests, 0 failures (additive change).

- [ ] **Step 5: Format + commit**

```bash
mix format lib/engram/notes/note.ex
git add lib/engram/notes/note.ex
git commit -m "feat(notes): declare Phase B fields in Note schema"
```

---

### Task B.1.5: `Attachment` schema declares `path_*`

**Files:**
- Modify: `lib/engram/attachments/attachment.ex`

- [ ] **Step 1: Add fields to the schema block**

```elixir
field :path_ciphertext, :binary
field :path_nonce, :binary
field :path_hmac, :binary
```

- [ ] **Step 2: Add to changeset cast allowlist**

Append to the `cast/3` field list: `:path_ciphertext, :path_nonce, :path_hmac`

- [ ] **Step 3: Run full suite**

Run: `mix test`
Expected: PASS, 852 tests.

- [ ] **Step 4: Format + commit**

```bash
mix format lib/engram/attachments/attachment.ex
git add lib/engram/attachments/attachment.ex
git commit -m "feat(attachments): declare Phase B path_* fields"
```

---

### Task B.1.6: `Vault` schema declares `name_*`

**Files:**
- Modify: `lib/engram/vaults/vault.ex`

- [ ] **Step 1: Add fields**

```elixir
field :name_ciphertext, :binary
field :name_nonce, :binary
field :name_hmac, :binary
```

- [ ] **Step 2: Add to changeset cast allowlist**

Append: `:name_ciphertext, :name_nonce, :name_hmac`

- [ ] **Step 3: Run full suite**

Run: `mix test`
Expected: PASS, 852 tests.

- [ ] **Step 4: Format + commit**

```bash
mix format lib/engram/vaults/vault.ex
git add lib/engram/vaults/vault.ex
git commit -m "feat(vaults): declare Phase B name_* fields"
```

---

### Task B.1.7: `Notes.upsert_note/2` dual-writes path/folder/tags HMAC + ciphertext

The hot path. Every call to `upsert_note` must populate the new columns alongside the existing ones. Read path stays on `notes.path` until B.2.

**Files:**
- Modify: `lib/engram/notes.ex`
- Test: `test/engram/notes_test.exs`

- [ ] **Step 1: Write the failing tests**

Add a new describe block to `test/engram/notes_test.exs`:

```elixir
describe "upsert_note/2 — Phase B dual-write" do
  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  test "populates path_hmac, path_ciphertext, path_nonce", %{user: user, vault: vault} do
    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "projects/q3/secret.md",
        "content" => "hello"
      })

    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    expected_hmac = Engram.Crypto.hmac_field(filter_key, "projects/q3/secret.md")

    assert note.path_hmac == expected_hmac
    assert is_binary(note.path_ciphertext)
    assert byte_size(note.path_nonce) == 12
  end

  test "populates folder_hmac, folder_ciphertext, folder_nonce", %{user: user, vault: vault} do
    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "projects/q3/secret.md",
        "content" => "hello"
      })

    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    expected_hmac = Engram.Crypto.hmac_field(filter_key, "projects/q3")

    assert note.folder_hmac == expected_hmac
    assert is_binary(note.folder_ciphertext)
    assert byte_size(note.folder_nonce) == 12
  end

  test "populates one tags_hmac entry per tag", %{user: user, vault: vault} do
    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "x.md",
        "content" => "y",
        "tags" => ["legal", "client-acme"]
      })

    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    expected = [
      Engram.Crypto.hmac_field(filter_key, "legal"),
      Engram.Crypto.hmac_field(filter_key, "client-acme")
    ]

    assert Enum.sort(note.tags_hmac) == Enum.sort(expected)
  end

  test "tags_hmac is empty array when no tags", %{user: user, vault: vault} do
    {:ok, note} = Engram.Notes.upsert_note(user, vault, %{"path" => "x.md", "content" => "y"})
    assert note.tags_hmac == []
  end

  test "still writes plaintext path/folder/tags (dual-write)", %{user: user, vault: vault} do
    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "a/b/c.md",
        "content" => "y",
        "tags" => ["t1"]
      })

    assert note.path == "a/b/c.md"
    assert note.folder == "a/b"
    assert note.tags == ["t1"]
  end
end
```

- [ ] **Step 2: Run to verify fail**

Run: `mix test test/engram/notes_test.exs --only describe:"upsert_note/2 — Phase B dual-write"`
Expected: FAIL — assertions on `path_hmac`, `path_ciphertext`, etc. all return `nil`.

- [ ] **Step 3: Implement dual-write in `Notes.upsert_note/2`**

Find `lib/engram/notes.ex` `def upsert_note(user, vault, attrs)`. Locate where `attrs` is built up before insert/update. Add a helper module call to inject Phase B fields.

First, add a private helper near the bottom of `lib/engram/notes.ex`:

```elixir
# Phase B.1 dual-write — computes HMAC + envelope-encrypts each filterable field.
# Returns the original attrs map merged with phase_b_* fields. Skips silently
# if the user has no DEK yet (Phase B is mandatory but tests sometimes touch
# unprovisioned users; ensure_user_dek/1 in upsert_note handles that).
defp inject_phase_b_fields(attrs, user, path, folder, tags) do
  with {:ok, dek} <- Engram.Crypto.get_dek(user),
       {:ok, filter_key} <- Engram.Crypto.dek_filter_key(user) do
    {path_ct, path_n} = Engram.Crypto.Envelope.encrypt(path, dek)
    {folder_ct, folder_n} = Engram.Crypto.Envelope.encrypt(folder, dek)

    Map.merge(attrs, %{
      path_ciphertext: path_ct,
      path_nonce: path_n,
      path_hmac: Engram.Crypto.hmac_field(filter_key, path),
      folder_ciphertext: folder_ct,
      folder_nonce: folder_n,
      folder_hmac: Engram.Crypto.hmac_field(filter_key, folder),
      tags_hmac: Enum.map(tags || [], &Engram.Crypto.hmac_field(filter_key, &1))
    })
  else
    _ -> attrs
  end
end
```

Then in `upsert_note/2`, after `Helpers.extract_folder/1` and after `ensure_user_dek/1`, before the insert/update branch, merge the Phase B fields. Locate the existing `attrs` map construction (look for where path/folder/tags are placed into the changeset map) and add:

```elixir
attrs = inject_phase_b_fields(attrs, user, sanitized_path, folder, attrs["tags"] || attrs[:tags] || [])
```

(Adjust the variable names — `sanitized_path` and `folder` already exist in upsert_note from `Helpers.extract_folder/1`.)

- [ ] **Step 4: Run tests to verify pass**

Run: `mix test test/engram/notes_test.exs --only describe:"upsert_note/2 — Phase B dual-write"`
Expected: PASS — 5 tests, 0 failures.

- [ ] **Step 5: Run full suite to ensure nothing else broke**

Run: `mix test`
Expected: 857 tests (852 + 5 new), 0 failures.

- [ ] **Step 6: Format + commit**

```bash
mix format lib/engram/notes.ex test/engram/notes_test.exs
git add lib/engram/notes.ex test/engram/notes_test.exs
git commit -m "feat(notes): dual-write Phase B HMAC + ciphertext on upsert_note"
```

---

### Task B.1.8: `Attachments.upsert_attachment/3` dual-writes `path_*`

Same pattern as B.1.7 but smaller — only `path_*` to inject.

**Files:**
- Modify: `lib/engram/attachments.ex`
- Test: `test/engram/attachments_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram/attachments_test.exs` describe `"upsert_attachment/3"`:

```elixir
test "Phase B dual-write — populates path_hmac/ciphertext/nonce", %{user: user, vault: vault} do
  expect(Engram.MockStorage, :put, fn _key, _binary, _opts -> :ok end)

  {:ok, att} =
    Attachments.upsert_attachment(user, vault, %{
      "path" => "photos/test.png",
      "content_base64" => Base.encode64("img bytes")
    })

  {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
  expected_hmac = Engram.Crypto.hmac_field(filter_key, "photos/test.png")

  assert att.path_hmac == expected_hmac
  assert is_binary(att.path_ciphertext)
  assert byte_size(att.path_nonce) == 12
  assert att.path == "photos/test.png", "dual-write keeps plaintext path until B.3"
end
```

- [ ] **Step 2: Run to verify fail**

Run: `mix test test/engram/attachments_test.exs`
Expected: FAIL on the new test — `path_hmac` is `nil`.

- [ ] **Step 3: Implement**

In `lib/engram/attachments.ex`, find `defp prepare_upload(...)` (where `attrs` is built). After the existing block that constructs `attrs`, add the Phase B fields. Inside `prepare_upload/6`:

```elixir
{:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
{path_ct, path_n} = Envelope.encrypt(path, dek)

attrs = Map.merge(attrs, %{
  path_ciphertext: path_ct,
  path_nonce: path_n,
  path_hmac: Engram.Crypto.hmac_field(filter_key, path)
})
```

(Place this after the existing `attrs = %{...}` block but before `{:ok, key, attrs, ciphertext}` is returned.)

- [ ] **Step 4: Run tests to verify pass**

Run: `mix test test/engram/attachments_test.exs`
Expected: PASS — all attachments tests pass including the new one.

- [ ] **Step 5: Format + commit**

```bash
mix format lib/engram/attachments.ex test/engram/attachments_test.exs
git add lib/engram/attachments.ex test/engram/attachments_test.exs
git commit -m "feat(attachments): dual-write Phase B path_* on upsert_attachment"
```

---

### Task B.1.9: `Vaults.create_vault/2` and `update_vault/2` dual-write `name_*`

**Files:**
- Modify: `lib/engram/vaults.ex`
- Test: `test/engram/vaults_test.exs`

- [ ] **Step 1: Write the failing tests**

Add a new describe block to `test/engram/vaults_test.exs`:

```elixir
describe "Phase B dual-write" do
  setup do
    user = insert(:user) |> Engram.Crypto.ensure_user_dek() |> elem(1)
    %{user: user}
  end

  test "create_vault populates name_hmac/ciphertext/nonce", %{user: user} do
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "client-acme"})

    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    expected_hmac = Engram.Crypto.hmac_field(filter_key, "client-acme")

    assert vault.name_hmac == expected_hmac
    assert is_binary(vault.name_ciphertext)
    assert byte_size(vault.name_nonce) == 12
    assert vault.name == "client-acme"
  end

  test "update_vault re-encrypts name on change", %{user: user} do
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "old-name"})
    {:ok, updated} = Engram.Vaults.update_vault(user, vault.id, %{name: "new-name"})

    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    expected = Engram.Crypto.hmac_field(filter_key, "new-name")

    assert updated.name_hmac == expected
    refute updated.name_hmac == vault.name_hmac
  end
end
```

- [ ] **Step 2: Run to verify fail**

Run: `mix test test/engram/vaults_test.exs --only describe:"Phase B dual-write"`
Expected: FAIL — name_hmac is nil.

- [ ] **Step 3: Implement**

In `lib/engram/vaults.ex`, locate `create_vault/2` and `update_vault/3`. Both build `attrs` for the changeset. Add a helper:

```elixir
# Phase B.1 — inject HMAC + ciphertext for the vault name. Skips if user
# has no DEK (test scaffolding edge case).
defp inject_name_phase_b(attrs, user) do
  name = attrs[:name] || attrs["name"]
  if is_binary(name) do
    case Engram.Crypto.get_dek(user) do
      {:ok, dek} ->
        {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
        {ct, n} = Engram.Crypto.Envelope.encrypt(name, dek)

        Map.merge(attrs, %{
          name_ciphertext: ct,
          name_nonce: n,
          name_hmac: Engram.Crypto.hmac_field(filter_key, name)
        })
      _ -> attrs
    end
  else
    attrs
  end
end
```

In `create_vault/2`, before the changeset/insert: `attrs = inject_name_phase_b(attrs, user)`.
In `update_vault/3`, same — but only if `:name` is present in attrs.

- [ ] **Step 4: Run tests to verify pass**

Run: `mix test test/engram/vaults_test.exs`
Expected: PASS.

- [ ] **Step 5: Run full suite**

Run: `mix test`
Expected: 859 tests (857 + 2 new), 0 failures.

- [ ] **Step 6: Format + commit**

```bash
mix format lib/engram/vaults.ex test/engram/vaults_test.exs
git add lib/engram/vaults.ex test/engram/vaults_test.exs
git commit -m "feat(vaults): dual-write Phase B name_* on create/update"
```

---

### Task B.1.10: `BackfillPhaseBHmac` Oban worker

Cursor-driven, per-(user, vault). Walks notes, attachments, vaults and populates Phase B columns for any row where `path_hmac IS NULL`. Idempotent on retry (skip-if-populated). Pattern mirrors `BackfillByteaToS3` from PR #58 (deleted in PR #62 — read its source via `git show 171ce9e:backend/lib/engram/workers/backfill_bytea_to_s3.ex` for the template).

**Files:**
- Create: `lib/engram/workers/backfill_phase_b_hmac.ex`
- Test: `test/engram/workers/backfill_phase_b_hmac_test.exs`

- [ ] **Step 1: Read the historical pattern**

Run: `git show 171ce9e:lib/engram/workers/backfill_bytea_to_s3.ex | head -60`

Note the structure: `use Oban.Worker`, `perform/1` accepts `{user_id, vault_id, last_id}`, processes a batch, schedules next batch with new cursor, terminates when batch is empty.

- [ ] **Step 2: Write the failing test**

Create `test/engram/workers/backfill_phase_b_hmac_test.exs`:

```elixir
defmodule Engram.Workers.BackfillPhaseBHmacTest do
  use Engram.DataCase, async: false

  import Ecto.Query
  alias Engram.Notes.Note
  alias Engram.Workers.BackfillPhaseBHmac

  setup do
    user = insert(:user) |> Engram.Crypto.ensure_user_dek() |> elem(1)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  test "backfills HMAC + ciphertext for legacy notes missing phase_b columns",
       %{user: user, vault: vault} do
    # Insert a row directly bypassing upsert_note so Phase B columns are nil
    {:ok, _} =
      Engram.Repo.with_tenant(user.id, fn ->
        %Note{}
        |> Note.changeset(%{
          path: "legacy/note.md",
          folder: "legacy",
          content: "x",
          tags: ["t1"],
          user_id: user.id,
          vault_id: vault.id
        })
        |> Engram.Repo.insert()
      end)

    {:ok, _job} = BackfillPhaseBHmac.perform(%Oban.Job{
      args: %{"user_id" => user.id, "vault_id" => vault.id, "last_id" => 0}
    })

    {:ok, [note]} =
      Engram.Repo.with_tenant(user.id, fn ->
        Engram.Repo.all(from n in Note, where: n.path == "legacy/note.md")
      end)

    assert is_binary(note.path_hmac)
    assert is_binary(note.path_ciphertext)
    assert note.tags_hmac != []
  end

  test "is idempotent — second run is a no-op", %{user: user, vault: vault} do
    insert(:note, user: user, vault: vault)
    BackfillPhaseBHmac.perform(%Oban.Job{
      args: %{"user_id" => user.id, "vault_id" => vault.id, "last_id" => 0}
    })

    {:ok, before_state} =
      Engram.Repo.with_tenant(user.id, fn ->
        Engram.Repo.all(from n in Note, select: n.path_hmac)
      end)

    BackfillPhaseBHmac.perform(%Oban.Job{
      args: %{"user_id" => user.id, "vault_id" => vault.id, "last_id" => 0}
    })

    {:ok, after_state} =
      Engram.Repo.with_tenant(user.id, fn ->
        Engram.Repo.all(from n in Note, select: n.path_hmac)
      end)

    assert before_state == after_state
  end
end
```

- [ ] **Step 3: Run to verify fail**

Run: `mix test test/engram/workers/backfill_phase_b_hmac_test.exs`
Expected: FAIL — `BackfillPhaseBHmac` module not found.

- [ ] **Step 4: Implement the worker**

Create `lib/engram/workers/backfill_phase_b_hmac.ex`:

```elixir
defmodule Engram.Workers.BackfillPhaseBHmac do
  @moduledoc """
  Phase B.1 backfill worker — populates `path_hmac`, `path_ciphertext`,
  `path_nonce`, `folder_hmac`, `folder_ciphertext`, `folder_nonce`,
  `tags_hmac` (notes) and `path_*` (attachments) and `name_*` (vaults)
  for legacy rows that pre-date Phase B.1's dual-write code.

  Cursor-driven per (user, vault). Each invocation processes one batch
  and re-enqueues itself with the next cursor until the batch is empty.

  Idempotent on retry: skips rows where `path_hmac IS NOT NULL`.

  Pattern mirrors the deleted `Engram.Workers.BackfillByteaToS3` (Phase A.4,
  removed in A.5). See `git show 171ce9e:lib/engram/workers/backfill_bytea_to_s3.ex`.
  """

  use Oban.Worker, queue: :backfill, max_attempts: 5

  import Ecto.Query

  alias Engram.{Crypto, Notes.Note, Repo}
  alias Engram.Attachments.Attachment
  alias Engram.Vaults.Vault
  alias Engram.Crypto.Envelope

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id} = args}) do
    last_id = Map.get(args, "last_id", 0)
    user = Repo.get!(Engram.Accounts.User, user_id, skip_tenant_check: true)
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)

    {:ok, processed} =
      Repo.with_tenant(user_id, fn ->
        backfill_notes(user_id, vault_id, last_id, dek, filter_key)
        |> tap(fn _ -> backfill_attachments(user_id, vault_id, dek, filter_key) end)
        |> tap(fn _ -> backfill_vault(vault_id, dek, filter_key) end)
      end)

    case processed do
      {:done, _} ->
        :ok

      {:more, next_cursor} ->
        %{"user_id" => user_id, "vault_id" => vault_id, "last_id" => next_cursor}
        |> __MODULE__.new()
        |> Oban.insert()
    end
  end

  defp backfill_notes(user_id, vault_id, last_id, dek, filter_key) do
    notes =
      from(n in Note,
        where: n.user_id == ^user_id and n.vault_id == ^vault_id,
        where: is_nil(n.path_hmac) and n.id > ^last_id,
        order_by: [asc: n.id],
        limit: @batch_size
      )
      |> Repo.all()

    Enum.each(notes, fn note ->
      {path_ct, path_n} = Envelope.encrypt(note.path, dek)
      {folder_ct, folder_n} = Envelope.encrypt(note.folder || "", dek)

      Note
      |> where(id: ^note.id)
      |> Repo.update_all(set: [
        path_ciphertext: path_ct,
        path_nonce: path_n,
        path_hmac: Crypto.hmac_field(filter_key, note.path),
        folder_ciphertext: folder_ct,
        folder_nonce: folder_n,
        folder_hmac: Crypto.hmac_field(filter_key, note.folder || ""),
        tags_hmac: Enum.map(note.tags || [], &Crypto.hmac_field(filter_key, &1))
      ])
    end)

    case notes do
      [] -> {:done, last_id}
      _ -> {:more, List.last(notes).id}
    end
  end

  defp backfill_attachments(user_id, vault_id, dek, filter_key) do
    attachments =
      from(a in Attachment,
        where: a.user_id == ^user_id and a.vault_id == ^vault_id,
        where: is_nil(a.path_hmac)
      )
      |> Repo.all()

    Enum.each(attachments, fn att ->
      {ct, n} = Envelope.encrypt(att.path, dek)

      Attachment
      |> where(id: ^att.id)
      |> Repo.update_all(set: [
        path_ciphertext: ct,
        path_nonce: n,
        path_hmac: Crypto.hmac_field(filter_key, att.path)
      ])
    end)
  end

  defp backfill_vault(vault_id, dek, filter_key) do
    vault = Repo.get(Vault, vault_id)
    if vault && is_nil(vault.name_hmac) && is_binary(vault.name) do
      {ct, n} = Envelope.encrypt(vault.name, dek)

      Vault
      |> where(id: ^vault_id)
      |> Repo.update_all(set: [
        name_ciphertext: ct,
        name_nonce: n,
        name_hmac: Crypto.hmac_field(filter_key, vault.name)
      ])
    end
  end
end
```

- [ ] **Step 5: Run tests to verify pass**

Run: `mix test test/engram/workers/backfill_phase_b_hmac_test.exs`
Expected: PASS — 2 tests.

- [ ] **Step 6: Run full suite**

Run: `mix test`
Expected: 861 tests, 0 failures.

- [ ] **Step 7: Format + commit**

```bash
mix format lib/engram/workers/backfill_phase_b_hmac.ex test/engram/workers/backfill_phase_b_hmac_test.exs
git add lib/engram/workers/backfill_phase_b_hmac.ex test/engram/workers/backfill_phase_b_hmac_test.exs
git commit -m "feat(workers): add BackfillPhaseBHmac Oban worker"
```

---

### Task B.1.11: `mix engram.backfill_phase_b_hmac` task

Operator entry point. Enqueues one job per (user, vault) where any note row has `path_hmac IS NULL`.

**Files:**
- Create: `lib/mix/tasks/engram.backfill_phase_b_hmac.ex`

- [ ] **Step 1: Implement**

```elixir
defmodule Mix.Tasks.Engram.BackfillPhaseBHmac do
  @moduledoc """
  Enqueues `Engram.Workers.BackfillPhaseBHmac` jobs for every (user, vault)
  combination that has at least one row with `path_hmac IS NULL` in notes,
  attachments, or `name_hmac IS NULL` in vaults.

  Idempotent — re-runs are safe. The worker itself skips populated rows.

  Usage from a release shell on FastRaid:
      docker exec engram-saas /app/bin/engram eval 'Mix.Task.run("engram.backfill_phase_b_hmac")'
  """

  use Mix.Task

  import Ecto.Query

  alias Engram.Notes.Note
  alias Engram.Attachments.Attachment
  alias Engram.Vaults.Vault
  alias Engram.Repo
  alias Engram.Workers.BackfillPhaseBHmac

  @shortdoc "Enqueue Phase B HMAC backfill jobs"

  def run(_args) do
    Mix.Task.run("app.start")

    pairs =
      Repo.all(
        from n in Note,
          where: is_nil(n.path_hmac),
          group_by: [n.user_id, n.vault_id],
          select: {n.user_id, n.vault_id},
          skip_tenant_check: true
      )
      |> Enum.uniq()

    IO.puts("Enqueueing Phase B backfill for #{length(pairs)} (user, vault) pairs")

    for {user_id, vault_id} <- pairs do
      %{"user_id" => user_id, "vault_id" => vault_id, "last_id" => 0}
      |> BackfillPhaseBHmac.new()
      |> Oban.insert!()
    end

    IO.puts("Done. Watch oban_jobs queue=:backfill for progress.")
  end
end
```

- [ ] **Step 2: Verify it compiles**

Run: `mix compile --warnings-as-errors`
Expected: PASS.

- [ ] **Step 3: Format + commit**

```bash
mix format lib/mix/tasks/engram.backfill_phase_b_hmac.ex
git add lib/mix/tasks/engram.backfill_phase_b_hmac.ex
git commit -m "feat(mix): add engram.backfill_phase_b_hmac task"
```

---

### Task B.1.12: Open Phase B.1 PR

- [ ] **Step 1: Final full test run**

Run: `mix test`
Expected: All tests pass.

- [ ] **Step 2: Push branch + open PR**

```bash
git push -u origin feat/encryption-phase-b1-schema-dual-write
gh pr create --base main --head feat/encryption-phase-b1-schema-dual-write \
  --title "feat(encryption): Phase B.1 schema + dual-write + backfill" \
  --body "$(cat <<'EOF'
## Summary

Phase B.1 of the Tier 2 encryption plan — adds HMAC + envelope-encrypted columns for filterable fields (paths, folders, tags, vault names), dual-writes them on every upsert path, and ships a backfill worker. Reads still operate on plaintext columns; that switches in B.2. Plaintext columns drop in B.3.

Bumps backend 0.5.22 → 0.5.23.

## Schema changes (additive, all nullable)

- `notes`: path_ciphertext, path_nonce, path_hmac, folder_ciphertext, folder_nonce, folder_hmac, tags_hmac (array)
- `attachments`: path_ciphertext, path_nonce, path_hmac
- `vaults`: name_ciphertext, name_nonce, name_hmac
- Indexes: btree on each scalar `_hmac`, GIN on `notes.tags_hmac`

## New code

- `Engram.Crypto.dek_filter_key/1` — HKDF-Expand from DEK with info `"engram-filter-v1"`
- `Engram.Crypto.hmac_field/2` — HMAC-SHA256 wrapper
- `Engram.Workers.BackfillPhaseBHmac` — cursor-driven, idempotent
- `mix engram.backfill_phase_b_hmac` — operator entry point

## Test plan

- [x] `mix test` — all green
- [ ] Apply migration on FastRaid via `fly deploy`
- [ ] Run backfill on saas: `docker exec engram-saas /app/bin/engram eval 'Mix.Task.run(\"engram.backfill_phase_b_hmac\")'`
- [ ] Verify all 805 saas notes have `path_hmac IS NOT NULL`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Wait for CI green, merge, deploy**

Use a Monitor on the PR checks then on the post-merge deploy run. After deploy:

```bash
ssh root@10.0.20.214 "docker exec engram-saas /app/bin/engram eval 'Mix.Task.run(\"engram.backfill_phase_b_hmac\")'"
```

Then verify completion:

```bash
ssh root@10.0.20.214 'docker exec engram-saas /app/bin/engram rpc "
  IO.inspect(Engram.Repo.query!(\"SELECT count(*) FROM notes WHERE path_hmac IS NULL\").rows)
"'
```

Expected: `[[0]]` after backfill completes (max ~30 seconds for 805 notes).

---

# Phase B.2 — Read Switch + Qdrant Migration (PR #2)

**Branch:** `feat/encryption-phase-b2-read-switch` off `main` after B.1 merges and backfill is verified at zero `path_hmac IS NULL` rows.

### Task B.2.0: Bump version

**Files:** Modify `mix.exs:7`

- [ ] Edit version to `"0.5.24"`, commit `"chore: bump version to 0.5.24 for Phase B.2"`.

### Task B.2.1: `Notes.get_by_path/3` queries on `path_hmac`

**Files:**
- Modify: `lib/engram/notes.ex` (find `def get_by_path` or equivalent — may be inlined into `get/3` or `get_note_by_path/3`)
- Test: `test/engram/notes_test.exs`

- [ ] **Step 1: Identify the current lookup function**

Run: `grep -nE "def get.*path|where.*\.path == \^path" lib/engram/notes.ex | head -10`

Locate the function that does `WHERE path = ^path`. Likely `get_note_by_path/3` or similar.

- [ ] **Step 2: Write failing test asserting HMAC-based lookup works after switch**

Add to `test/engram/notes_test.exs`:

```elixir
test "get_note_by_path locates note via HMAC, returns decrypted plaintext path", %{user: user, vault: vault} do
  {:ok, _note} = Engram.Notes.upsert_note(user, vault, %{"path" => "x/y.md", "content" => "z"})

  # Simulate post-B.3 world: nil out the plaintext path column to ensure the lookup uses HMAC
  Engram.Repo.with_tenant(user.id, fn ->
    Engram.Repo.update_all(
      from(n in Engram.Notes.Note, where: n.path == "x/y.md"),
      set: [path: nil]
    )
  end)

  {:ok, note} = Engram.Notes.get_note_by_path(user, vault, "x/y.md")
  assert note != nil
  # The decrypted path is exposed as a virtual field or computed on read
  assert note_path(note) == "x/y.md"
end

defp note_path(note), do: note.path_decrypted || note.path
```

- [ ] **Step 3: Run to verify fail**

Expected: FAIL because lookup currently uses `n.path == ^path`, which after the test's nil-ing returns no row.

- [ ] **Step 4: Rewrite the lookup**

Replace the `WHERE path = ^path` clause with HMAC equality:

```elixir
def get_note_by_path(user, vault, path) do
  {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
  hmac = Engram.Crypto.hmac_field(filter_key, path)

  Engram.Repo.with_tenant(user.id, fn ->
    Engram.Repo.one(
      from n in Note,
        where: n.user_id == ^user.id and n.vault_id == ^vault.id and n.path_hmac == ^hmac
    )
  end)
  |> case do
    {:ok, nil} -> {:ok, nil}
    {:ok, note} -> {:ok, decrypt_phase_b_fields(note, user)}
  end
end

defp decrypt_phase_b_fields(note, user) do
  {:ok, dek} = Engram.Crypto.get_dek(user)

  %{note |
    path: Engram.Crypto.Envelope.decrypt(note.path_ciphertext, note.path_nonce, dek) |> elem(1),
    folder: Engram.Crypto.Envelope.decrypt(note.folder_ciphertext, note.folder_nonce, dek) |> elem(1)
  }
end
```

(`Envelope.decrypt/3` returns `{:ok, plaintext}` — adapt the elem/1 pattern to whatever Engram's helper returns; check `lib/engram/crypto/envelope.ex` for the exact signature.)

- [ ] **Step 5: Run tests to verify pass**

Run: `mix test test/engram/notes_test.exs`
Expected: PASS.

- [ ] **Step 6: Format + commit**

```bash
mix format lib/engram/notes.ex test/engram/notes_test.exs
git add lib/engram/notes.ex test/engram/notes_test.exs
git commit -m "feat(notes): get_note_by_path uses HMAC lookup + decrypts response"
```

---

### Task B.2.2: Distinct-folder query rewrites to `GROUP BY folder_hmac`

**Files:**
- Modify: `lib/engram/notes.ex` (around the existing query at lines ~287–291)
- Test: `test/engram/notes_test.exs`

- [ ] **Step 1: Locate the current query**

Run: `sed -n '280,295p' lib/engram/notes.ex`

The query is `from n in Note, where: n.folder != "" and not is_nil(n.folder), select: n.folder, order_by: n.folder, distinct: true` (or similar).

- [ ] **Step 2: Write failing test**

Add to `test/engram/notes_test.exs`:

```elixir
test "list_distinct_folders returns decrypted folder names sourced from HMAC", %{user: user, vault: vault} do
  Engram.Notes.upsert_note(user, vault, %{"path" => "a/x.md", "content" => "1"})
  Engram.Notes.upsert_note(user, vault, %{"path" => "a/y.md", "content" => "2"})
  Engram.Notes.upsert_note(user, vault, %{"path" => "b/z.md", "content" => "3"})

  # Nil out plaintext folder column to force HMAC-sourced query
  Engram.Repo.with_tenant(user.id, fn ->
    Engram.Repo.update_all(Engram.Notes.Note, set: [folder: nil])
  end)

  {:ok, folders} = Engram.Notes.list_distinct_folders(user, vault)

  assert Enum.sort(folders) == ["a", "b"]
end
```

- [ ] **Step 3: Run to verify fail**

Expected: FAIL — function may be named differently. Check `grep -n "distinct.*folder" lib/engram/notes.ex` and `lib/engram_web/controllers/folders_controller.ex` for the call site.

- [ ] **Step 4: Implement**

Replace the existing distinct-folder query block with:

```elixir
def list_distinct_folders(user, vault) do
  {:ok, dek} = Engram.Crypto.get_dek(user)

  Engram.Repo.with_tenant(user.id, fn ->
    Engram.Repo.all(
      from n in Note,
        where: n.user_id == ^user.id and n.vault_id == ^vault.id,
        where: not is_nil(n.folder_hmac),
        group_by: n.folder_hmac,
        select: %{
          ciphertext: fragment("MIN(?)", n.folder_ciphertext),
          nonce: fragment("MIN(?)", n.folder_nonce)
        }
    )
  end)
  |> case do
    {:ok, rows} ->
      folders =
        rows
        |> Enum.map(fn %{ciphertext: ct, nonce: n} ->
          {:ok, plaintext} = Engram.Crypto.Envelope.decrypt(ct, n, dek)
          plaintext
        end)
        |> Enum.reject(&(&1 == ""))

      {:ok, folders}
  end
end
```

- [ ] **Step 5: Run tests to verify pass**

Run: `mix test test/engram/notes_test.exs`
Expected: PASS.

- [ ] **Step 6: Format + commit**

```bash
mix format lib/engram/notes.ex test/engram/notes_test.exs
git add lib/engram/notes.ex test/engram/notes_test.exs
git commit -m "feat(notes): list_distinct_folders uses HMAC group + decrypted display"
```

---

### Task B.2.3: `Search.do_search/4` translates folder/tag filters to HMAC predicates

**Files:**
- Modify: `lib/engram/search.ex`
- Test: `test/engram/search_test.exs`

- [ ] **Step 1: Locate filter construction**

Run: `grep -nE "Keyword.put.*folder|filter.*folder|tags:" lib/engram/search.ex | head -10`

Find where user-facing `folder` / `tags` filters are added to the Qdrant query (look for `Keyword.put(&1, :folder, folder)` or similar).

- [ ] **Step 2: Write failing test**

Add to `test/engram/search_test.exs`:

```elixir
test "search by folder uses folder_hmac filter not raw folder name", %{user: user, vault: vault} do
  # Capture what Qdrant sees
  test_pid = self()

  expect(Engram.MockQdrantClient, :search, fn _collection, opts ->
    send(test_pid, {:qdrant_filter, opts})
    {:ok, []}
  end)

  Engram.Search.do_search(user, vault, "test query", folder: "projects/q3")

  assert_receive {:qdrant_filter, opts}
  filter = Keyword.fetch!(opts, :filter)

  {:ok, fk} = Engram.Crypto.dek_filter_key(user)
  expected_hmac = Engram.Crypto.hmac_field(fk, "projects/q3")

  refute filter |> inspect() =~ "projects/q3", "raw folder name leaked into Qdrant filter"
  assert filter |> inspect() =~ Base.encode64(expected_hmac), "expected HMAC in filter"
end
```

(Adjust `Engram.MockQdrantClient` to match whatever mock exists for the Qdrant client; check `test/support/mocks.ex`.)

- [ ] **Step 3: Run to verify fail**

Expected: FAIL — current code passes raw folder name.

- [ ] **Step 4: Implement filter translation**

In `lib/engram/search.ex`, before the Qdrant client call, translate filterable args:

```elixir
defp translate_filters(opts, user) do
  {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)

  opts
  |> Enum.map(fn
    {:folder, folder} when is_binary(folder) ->
      {:folder_hmac, Engram.Crypto.hmac_field(filter_key, folder)}

    {:tags, tags} when is_list(tags) ->
      {:tags_hmac, Enum.map(tags, &Engram.Crypto.hmac_field(filter_key, &1))}

    other ->
      other
  end)
end
```

Call this from `do_search/4` before passing opts to the Qdrant client. Update the Qdrant payload schema accordingly (next task).

- [ ] **Step 5: Run tests to verify pass**

Run: `mix test test/engram/search_test.exs`
Expected: PASS.

- [ ] **Step 6: Format + commit**

```bash
mix format lib/engram/search.ex test/engram/search_test.exs
git add lib/engram/search.ex test/engram/search_test.exs
git commit -m "feat(search): translate folder/tag filters to HMAC predicates"
```

---

### Task B.2.4: Qdrant payload writes use `folder_hmac` / `tags_hmac` keys

**Files:**
- Modify: `lib/engram/vector/qdrant.ex` and the upsert path (likely `lib/engram/indexer.ex` or `lib/engram/workers/embed_note.ex`)

- [ ] **Step 1: Find where Qdrant payload is constructed**

Run: `grep -rn "payload:.*folder\|source_path:" lib/engram/`

Locate the `payload: %{folder: folder, source_path: path, tags: tags, ...}` map.

- [ ] **Step 2: Write failing test (or extend existing indexer test)**

Add a test asserting payload uses `folder_hmac`/`tags_hmac` keys instead of raw plaintext:

```elixir
test "qdrant payload uses HMAC keys not raw values", %{user: user, vault: vault} do
  test_pid = self()
  expect(Engram.MockQdrantClient, :upsert, fn _coll, points ->
    send(test_pid, {:upsert, points})
    {:ok, []}
  end)

  Engram.Notes.upsert_note(user, vault, %{
    "path" => "secret/x.md", "content" => "hi", "tags" => ["legal"]
  })
  # Trigger embedding (or call the worker directly)
  Engram.Workers.EmbedNote.perform(%Oban.Job{args: %{"note_id" => /* ... */}})

  assert_receive {:upsert, [%{payload: payload}]}, 1000
  refute Map.has_key?(payload, :source_path) and payload[:source_path] == "secret/x.md"
  assert Map.has_key?(payload, :path_hmac)
  assert Map.has_key?(payload, :folder_hmac)
  assert Map.has_key?(payload, :tags_hmac)
end
```

- [ ] **Step 3: Implement payload schema swap**

In whatever module builds Qdrant payloads, replace plaintext keys with their HMAC equivalents pulled from the note row (which now has them populated since B.1):

```elixir
%{
  payload: %{
    text_ciphertext: chunk.text_ciphertext,
    text_nonce: chunk.text_nonce,
    title_ciphertext: note.title_ciphertext,
    title_nonce: note.title_nonce,
    path_hmac: note.path_hmac,
    path_ciphertext: note.path_ciphertext,
    path_nonce: note.path_nonce,
    folder_hmac: note.folder_hmac,
    folder_ciphertext: note.folder_ciphertext,
    folder_nonce: note.folder_nonce,
    tags_hmac: note.tags_hmac,
    tags_ciphertext: note.tags_ciphertext,
    tags_nonce: note.tags_nonce,
    vault_id: note.vault_id,
    user_id: note.user_id,
    note_id: note.id
  }
}
```

(Drop `source_path`, `folder`, `tags` from the payload — those were the plaintext keys.)

- [ ] **Step 4: Verify tests pass**

Run: `mix test`
Expected: PASS.

- [ ] **Step 5: Format + commit**

```bash
mix format lib/engram/vector/qdrant.ex lib/engram/workers/embed_note.ex
git add lib/engram/vector/qdrant.ex lib/engram/workers/embed_note.ex test/
git commit -m "feat(qdrant): payload uses HMAC keys, drops plaintext path/folder/tags"
```

---

### Task B.2.5: `QdrantPayloadPhaseB` re-upsert worker

For existing Qdrant points (the 318 Phase 4 ciphertext rows + any pre-Phase-4 plaintext rows), payloads need to be re-upserted with the new shape. Worker walks Qdrant by collection, fetches batches, re-upserts with new payload.

**Files:**
- Create: `lib/engram/workers/qdrant_payload_phase_b.ex`
- Test: `test/engram/workers/qdrant_payload_phase_b_test.exs`

- [ ] **Step 1: Implement** (use the EmbedNote worker as the template for re-upserting per note)

```elixir
defmodule Engram.Workers.QdrantPayloadPhaseB do
  @moduledoc """
  Re-upserts every Qdrant point owned by (user_id, vault_id) with the
  Phase B payload shape (HMAC keys instead of plaintext folder/path/tags).

  Idempotent — re-upsert with the same point_id is an update.
  """

  use Oban.Worker, queue: :backfill, max_attempts: 5

  import Ecto.Query
  alias Engram.{Notes.Note, Notes.Chunk, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id}}) do
    {:ok, _} =
      Repo.with_tenant(user_id, fn ->
        Repo.all(
          from n in Note,
            where: n.user_id == ^user_id and n.vault_id == ^vault_id,
            preload: :chunks
        )
        |> Enum.each(fn note ->
          Engram.Indexer.reindex_note_payload(note)
        end)
      end)

    :ok
  end
end
```

(`Engram.Indexer.reindex_note_payload/1` should be a thin wrapper that re-upserts the chunks to Qdrant with the new payload shape. If no such helper exists, add it as part of this task in `lib/engram/indexer.ex`.)

- [ ] **Step 2: Add a corresponding mix task**

`lib/mix/tasks/engram.qdrant_payload_phase_b.ex` — mirrors `engram.backfill_phase_b_hmac` but enqueues `QdrantPayloadPhaseB` jobs.

- [ ] **Step 3: Write a smoke test**

Create `test/engram/workers/qdrant_payload_phase_b_test.exs`:

```elixir
defmodule Engram.Workers.QdrantPayloadPhaseBTest do
  use Engram.DataCase, async: false

  import Mox
  alias Engram.Workers.QdrantPayloadPhaseB

  setup :verify_on_exit!

  setup do
    user = insert(:user) |> Engram.Crypto.ensure_user_dek() |> elem(1)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  test "re-upserts every note in (user, vault) with new payload shape",
       %{user: user, vault: vault} do
    {:ok, _note} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "x.md",
        "content" => "y",
        "tags" => ["t1"]
      })

    test_pid = self()

    expect(Engram.MockQdrantClient, :upsert, fn _coll, points ->
      send(test_pid, {:upsert, points})
      {:ok, []}
    end)

    QdrantPayloadPhaseB.perform(%Oban.Job{
      args: %{"user_id" => user.id, "vault_id" => vault.id}
    })

    assert_receive {:upsert, [point | _]}, 1000
    assert Map.has_key?(point.payload, :path_hmac)
    refute Map.has_key?(point.payload, :source_path)
  end
end
```

- [ ] **Step 4: Format + commit**

```bash
mix format
git add lib/engram/workers/qdrant_payload_phase_b.ex lib/mix/tasks/engram.qdrant_payload_phase_b.ex test/
git commit -m "feat(workers): QdrantPayloadPhaseB re-upserts existing points with new payload"
```

---

### Task B.2.6: Decrypt path/folder/tags/name on every read response

Controllers need to expose decrypted display values to the API consumer (plugin, web SPA). Affected controllers: `notes_controller`, `attachments_controller`, `vaults_controller`, `folders_controller`.

**Files:**
- Modify: `lib/engram_web/controllers/notes_controller.ex`
- Modify: `lib/engram_web/controllers/attachments_controller.ex`
- Modify: `lib/engram_web/controllers/vaults_controller.ex`
- Modify: `lib/engram_web/controllers/folders_controller.ex`

For each controller, in the response-shaping function (likely `note_to_json/1` / `vault_to_json/1` / etc.), replace direct field access with decrypted-field access:

- [ ] **Step 1: Update `notes_controller` response shaping**

```elixir
defp note_to_json(note, user) do
  {:ok, dek} = Engram.Crypto.get_dek(user)
  {:ok, plaintext_path} = Engram.Crypto.Envelope.decrypt(note.path_ciphertext, note.path_nonce, dek)
  {:ok, plaintext_folder} = Engram.Crypto.Envelope.decrypt(note.folder_ciphertext, note.folder_nonce, dek)
  # Tags decrypt path uses existing tags_ciphertext/tags_nonce from Phase 4
  plaintext_tags = decrypt_tags(note, dek)

  %{
    id: note.id,
    path: plaintext_path,
    folder: plaintext_folder,
    tags: plaintext_tags,
    # ... rest unchanged
  }
end
```

- [ ] **Step 2: Repeat for `attachments_controller`, `vaults_controller`, `folders_controller`**

- [ ] **Step 3: Update existing controller tests** that assert response shape — they should still pass because the API contract is unchanged (decrypted plaintext is what consumers see).

- [ ] **Step 4: Run full suite**

Run: `mix test`
Expected: All tests pass.

- [ ] **Step 5: Format + commit**

```bash
mix format lib/engram_web/controllers/
git add lib/engram_web/controllers/
git commit -m "feat(web): controllers decrypt Phase B fields on response"
```

---

### Task B.2.7: Open Phase B.2 PR

- [ ] **Step 1: Push + open PR**

```bash
git push -u origin feat/encryption-phase-b2-read-switch
gh pr create --base main --head feat/encryption-phase-b2-read-switch \
  --title "feat(encryption): Phase B.2 read switch + Qdrant payload migration" \
  --body "$(cat <<'EOF'
## Summary

Phase B.2 — switches every read path from plaintext columns (`notes.path`, `notes.folder`, `notes.tags`, `attachments.path`, `vaults.name`) to HMAC-equality lookups + decrypted display values. Adds the `QdrantPayloadPhaseB` worker to re-upsert existing Qdrant points with the new payload schema. After this PR, plaintext columns are write-only and unreferenced for any read; B.3 drops them.

Bumps backend 0.5.23 → 0.5.24.

## Read paths switched

- `Notes.get_note_by_path/3` — `WHERE path = ?` → `WHERE path_hmac = ?`
- `Notes.list_distinct_folders/2` — distinct on plaintext folder → `GROUP BY folder_hmac` + decrypt
- `Search.do_search/4` — folder/tag filter args translate to HMAC predicates
- Qdrant payload schema — `source_path`/`folder`/`tags` keys replaced by `*_hmac` + `*_ciphertext`
- All controller response shapers (`notes`, `attachments`, `vaults`, `folders`) — decrypt ciphertext columns into virtual plaintext fields for the API consumer

## Migration

After deploy, run the Qdrant payload re-upsert worker on saas:
```bash
docker exec engram-saas /app/bin/engram eval 'Mix.Task.run("engram.qdrant_payload_phase_b")'
```

## Test plan

- [x] `mix test` — all green
- [ ] Apply on FastRaid via `fly deploy`
- [ ] Run Qdrant payload re-upsert on saas
- [ ] Dump a random Qdrant point, verify payload has `path_hmac` keys (no `source_path` plaintext)
- [ ] Smoke test: search by folder, by tag, by exact path — all return correct results

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Wait for CI green, merge**

- [ ] **Step 3: Run Qdrant payload backfill on saas**

```bash
ssh root@10.0.20.214 "docker exec engram-saas /app/bin/engram eval 'Mix.Task.run(\"engram.qdrant_payload_phase_b\")'"
```

- [ ] **Step 4: Verify**

Pick one Qdrant point on saas, dump its payload via Qdrant HTTP API, confirm `path_hmac` key exists and `source_path` plaintext key does not.

---

# Phase B.3 — Drop Plaintext Columns (PR #3)

**Branch:** `feat/encryption-phase-b3-drop-plaintext` off `main` after B.2 deploys and Qdrant payload backfill verifies clean.

### Task B.3.0: Bump version

**Files:** Modify `mix.exs:7`

- [ ] Edit version to `"0.5.25"`, commit `"chore: bump version to 0.5.25 for Phase B.3"`.

### Task B.3.1: Pre-merge probe — verify backfill complete

This is the A.5-style safety check. **Do not skip.**

- [ ] **Step 1: Probe both containers**

```bash
ssh root@10.0.20.214 'docker exec engram-saas /app/bin/engram rpc "
  results = [
    notes_missing_phase_b: Engram.Repo.query!(\"SELECT count(*) FROM notes WHERE path_hmac IS NULL\").rows,
    attachments_missing: Engram.Repo.query!(\"SELECT count(*) FROM attachments WHERE path_hmac IS NULL\").rows,
    vaults_missing: Engram.Repo.query!(\"SELECT count(*) FROM vaults WHERE name_hmac IS NULL\").rows
  ]
  IO.inspect(results)
"'

ssh root@10.0.20.214 'docker exec engram-selfhost /app/bin/engram rpc "
  results = [
    notes_missing_phase_b: Engram.Repo.query!(\"SELECT count(*) FROM notes WHERE path_hmac IS NULL\").rows,
    attachments_missing: Engram.Repo.query!(\"SELECT count(*) FROM attachments WHERE path_hmac IS NULL\").rows,
    vaults_missing: Engram.Repo.query!(\"SELECT count(*) FROM vaults WHERE name_hmac IS NULL\").rows
  ]
  IO.inspect(results)
"'
```

**Required:** every count must be `[[0]]`. If any count is non-zero, run the backfill task on that container and re-probe before proceeding.

### Task B.3.2: Migration drops plaintext columns

**Files:**
- Create: `priv/repo/migrations/<ts>_drop_phase_b_plaintext_columns.exs`

- [ ] **Step 1: Write the irreversible migration**

```elixir
defmodule Engram.Repo.Migrations.DropPhaseBPlaintextColumns do
  use Ecto.Migration

  # Phase B.3 — drops the plaintext path/folder/tags/name columns. By this
  # point, B.1's backfill + B.2's read switch + Qdrant payload re-upsert
  # have been live and verified at zero `*_hmac IS NULL` rows on every
  # container.
  #
  # IRREVERSIBLE: rolling back would require decrypting every ciphertext
  # column and re-populating the plaintext columns, which is supported only
  # via a forward migration not a `down/0` step.

  def up do
    alter table(:notes) do
      remove :path
      remove :folder
      remove :tags
    end

    alter table(:attachments) do
      remove :path
    end

    alter table(:vaults) do
      remove :name
    end

    # Tighten — every row must now have ciphertext + HMAC
    alter table(:notes) do
      modify :path_hmac, :binary, null: false
      modify :path_ciphertext, :binary, null: false
      modify :path_nonce, :binary, null: false
      modify :folder_hmac, :binary, null: false
      modify :folder_ciphertext, :binary, null: false
      modify :folder_nonce, :binary, null: false
    end

    alter table(:attachments) do
      modify :path_hmac, :binary, null: false
      modify :path_ciphertext, :binary, null: false
      modify :path_nonce, :binary, null: false
    end

    alter table(:vaults) do
      modify :name_hmac, :binary, null: false
      modify :name_ciphertext, :binary, null: false
      modify :name_nonce, :binary, null: false
    end
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "DropPhaseBPlaintextColumns is irreversible — restoring requires " <>
          "decrypting every ciphertext column and re-populating plaintext, " <>
          "which is not supported via Ecto down migrations."
  end
end
```

- [ ] **Step 2: Run migration locally**

Run: `mix ecto.migrate`
Expected: All ALTER TABLE / MODIFY statements succeed.

- [ ] **Step 3: Verify columns gone**

```bash
mix run -e "Engram.Repo.query!(\"SELECT column_name FROM information_schema.columns WHERE table_name = 'notes' ORDER BY ordinal_position\") |> Map.get(:rows) |> List.flatten() |> IO.inspect()"
```

Expected: no `path`, `folder`, or `tags` (the plaintext array) in the list.

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/
git commit -m "feat(db): drop Phase B plaintext columns (irreversible, A.5-style)"
```

---

### Task B.3.3: Schema removes plaintext fields, adds virtual accessors

**Files:**
- Modify: `lib/engram/notes/note.ex`
- Modify: `lib/engram/attachments/attachment.ex`
- Modify: `lib/engram/vaults/vault.ex`

- [ ] **Step 1: For each schema, remove the plaintext field declarations** (`path`, `folder`, `tags` on Note; `path` on Attachment; `name` on Vault).

- [ ] **Step 2: Add virtual fields** for callers that still need to read plaintext after decryption:

```elixir
field :path, :string, virtual: true
field :folder, :string, virtual: true
field :tags, {:array, :string}, virtual: true
```

(The decryption helpers from B.2.1 set these at read time.)

- [ ] **Step 3: Update changeset** — remove plaintext fields from `cast/3` allowlist, add `validate_required([:path_hmac, :path_ciphertext, :path_nonce, ...])`.

- [ ] **Step 4: Run full suite**

Run: `mix test`
Expected: PASS — virtual fields preserve API consumers' contract.

- [ ] **Step 5: Format + commit**

```bash
mix format lib/engram/notes/note.ex lib/engram/attachments/attachment.ex lib/engram/vaults/vault.ex
git add lib/engram/
git commit -m "feat(schema): drop plaintext fields, add virtual accessors for decrypted display"
```

---

### Task B.3.4: Drop dual-write code paths

**Files:**
- Modify: `lib/engram/notes.ex` — `upsert_note/2` no longer writes both; only writes encrypted columns. Drop `inject_phase_b_fields/3` (was a dual-write helper) — its body becomes the only write path.
- Modify: `lib/engram/attachments.ex` — same simplification.
- Modify: `lib/engram/vaults.ex` — same.

- [ ] **Step 1: For each `upsert_*` function**, remove the now-unreachable plaintext writes. The HMAC + ciphertext writes stay.

- [ ] **Step 2: Run full suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 3: Format + commit**

```bash
mix format lib/engram/
git add lib/engram/
git commit -m "feat: drop Phase B dual-write code, encrypted columns are sole write path"
```

---

### Task B.3.5: Delete backfill worker + mix tasks

**Files:**
- Delete: `lib/engram/workers/backfill_phase_b_hmac.ex`
- Delete: `lib/engram/workers/qdrant_payload_phase_b.ex`
- Delete: `lib/mix/tasks/engram.backfill_phase_b_hmac.ex`
- Delete: `lib/mix/tasks/engram.qdrant_payload_phase_b.ex`
- Delete: `test/engram/workers/backfill_phase_b_hmac_test.exs`
- Delete: `test/engram/workers/qdrant_payload_phase_b_test.exs`

- [ ] **Step 1: Confirm nothing references them**

Run: `grep -rE "BackfillPhaseBHmac|QdrantPayloadPhaseB|backfill_phase_b" lib/ test/`
Expected: no matches outside the files being deleted.

- [ ] **Step 2: Delete the files**

```bash
git rm lib/engram/workers/backfill_phase_b_hmac.ex \
       lib/engram/workers/qdrant_payload_phase_b.ex \
       lib/mix/tasks/engram.backfill_phase_b_hmac.ex \
       lib/mix/tasks/engram.qdrant_payload_phase_b.ex \
       test/engram/workers/backfill_phase_b_hmac_test.exs \
       test/engram/workers/qdrant_payload_phase_b_test.exs
```

- [ ] **Step 3: Run full suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat: delete Phase B backfill worker + mix tasks (no callers left)"
```

---

### Task B.3.6: Open Phase B.3 PR

- [ ] **Step 1: Push + open PR**

```bash
git push -u origin feat/encryption-phase-b3-drop-plaintext
gh pr create --base main --head feat/encryption-phase-b3-drop-plaintext \
  --title "feat(encryption): Phase B.3 drop plaintext columns + retire backfill" \
  --body "$(cat <<'EOF'
## Summary

Phase B.3 — drops `notes.path`, `notes.folder`, `notes.tags`, `attachments.path`, `vaults.name` plaintext columns. Tightens HMAC + ciphertext + nonce columns to NOT NULL. Removes dual-write code and deletes the Phase B backfill worker, mix tasks, and Qdrant re-upsert worker (no callers left).

**Migration is irreversible** (`down/0` raises). Same pattern as A.5 — restoring the columns would require decrypting every ciphertext and re-populating plaintext, which Engram does not support.

Bumps backend 0.5.24 → 0.5.25.

## Pre-merge probe (REQUIRED)

Both saas and selfhost must show zero `*_hmac IS NULL` rows in notes, attachments, and vaults. Verified 2026-XX-XX (fill in date when running):

```bash
ssh root@10.0.20.214 'docker exec engram-saas /app/bin/engram rpc "
  IO.inspect([
    notes: Engram.Repo.query!(\"SELECT count(*) FROM notes WHERE path_hmac IS NULL\").rows,
    attachments: Engram.Repo.query!(\"SELECT count(*) FROM attachments WHERE path_hmac IS NULL\").rows,
    vaults: Engram.Repo.query!(\"SELECT count(*) FROM vaults WHERE name_hmac IS NULL\").rows
  ])
"'
```

All counts must be `[[0]]`. If any container has non-zero, run the backfill task on that container before merging.

## Test plan

- [x] `mix test` — all green
- [ ] Apply on FastRaid via `fly deploy`
- [ ] Verify schema: `SELECT column_name FROM information_schema.columns WHERE table_name = 'notes' AND column_name IN ('path', 'folder', 'tags')` returns empty
- [ ] Run smoke recipe from plan doc — write/read/search a note, verify all paths sealed in DB

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Wait for CI, merge, deploy, verify**

After deploy, verify:

```bash
ssh root@10.0.20.214 'docker exec engram-saas /app/bin/engram rpc "
  IO.inspect(Engram.Repo.query!(\"SELECT column_name FROM information_schema.columns WHERE table_name = 'notes' AND column_name IN ('path', 'folder', 'tags')\").rows)
"'
```

Expected: `[]` — none of the plaintext columns exist.

---

# Acceptance Criteria

After B.3 deploys, the following must all be true:

- [ ] **Zero plaintext path/folder/tag bytes in Postgres** — verifiable via `\d notes` showing no `path`, `folder`, or `tags` columns.
- [ ] **Zero plaintext path/folder/tag bytes in Qdrant payload** — verifiable by dumping a random Qdrant point's payload and confirming no `source_path`, `folder`, or `tags` keys (only `*_hmac` and `*_ciphertext`).
- [ ] **Folder filter still works** — search API call with `folder=projects/q3` returns matching notes.
- [ ] **Tag filter still works** — search API call with `tags=legal` returns matching notes.
- [ ] **Exact path lookup still works** — sync API `GET /api/notes/<path>` returns the right note.
- [ ] **Distinct folders still works** — `GET /api/folders` returns correct unique folder list.
- [ ] **Vault list still works** — `GET /api/vaults` returns vault names.
- [ ] **Search latency p95 within 10% of pre-B.1 baseline.**
- [ ] **All existing E2E tests pass** — particularly the sync round-trip tests in `e2e/`.

# Smoke Recipe (post-B.3 deploy)

```bash
# 1. Mint API key for user 2 on saas
ssh root@10.0.20.214 "docker exec engram-saas /app/bin/engram rpc '
user = Engram.Repo.get(Engram.Accounts.User, 2)
{:ok, raw_key, _} = Engram.Accounts.create_api_key(user, \"phase-b-smoke\")
IO.puts(\"KEY=#{raw_key}\")
'"

RAW_KEY="<paste from above>"
VAULT_ID=2

# 2. Upsert a note via API
SENTINEL_PATH="phase-b-smoke/sealed-folder/note-$(date +%s).md"
curl --max-time 5 -s -X POST "https://engram.ras.band/api/notes" \
  -H "Authorization: Bearer $RAW_KEY" -H "X-Vault-ID: $VAULT_ID" -H "Content-Type: application/json" \
  -d "{\"path\":\"$SENTINEL_PATH\",\"content\":\"phase B smoke\",\"tags\":[\"phase-b-tag\"]}"

# 3. Get it back via path
curl --max-time 5 -s "https://engram.ras.band/api/notes/$SENTINEL_PATH" \
  -H "Authorization: Bearer $RAW_KEY" -H "X-Vault-ID: $VAULT_ID"
# Expected: 200 with the note

# 4. Search by folder
curl --max-time 5 -s -X POST "https://engram.ras.band/api/search" \
  -H "Authorization: Bearer $RAW_KEY" -H "X-Vault-ID: $VAULT_ID" -H "Content-Type: application/json" \
  -d "{\"query\":\"phase B\",\"folder\":\"phase-b-smoke/sealed-folder\"}"
# Expected: 200, results contain our note

# 5. Verify raw DB row has no plaintext path
ssh root@10.0.20.214 'docker exec engram-saas /app/bin/engram rpc "
  res = Engram.Repo.query!(\"SELECT path_hmac, path_ciphertext FROM notes WHERE id = (SELECT MAX(id) FROM notes)\")
  IO.inspect(res.rows)
"'
# Expected: HMAC + ciphertext binaries; no plaintext path anywhere

# 6. Cleanup
curl --max-time 5 -X DELETE "https://engram.ras.band/api/notes/$SENTINEL_PATH" \
  -H "Authorization: Bearer $RAW_KEY" -H "X-Vault-ID: $VAULT_ID"
```

# Out of Scope

- **Phase F (AWS KMS BYOK provider)** — Phase B's filter-key derivation from DEK is BYOK-ready by construction. The end-to-end BYOK smoke test (search through folder filter while customer's CMK rotates mid-query) waits for Phase F to land.
- **Path prefix matching** — codebase verified zero `LIKE 'folder/%'` queries today; deterministic encryption breaks prefix queries by design. Reintroduce only if product asks (would require rolling-prefix HMACs).
- **Tag autocomplete** — "browse tags starting with X" dies under deterministic encryption. Future option: per-user encrypted tag dictionary (fetched whole, filtered client-side). Documented regression.
- **Note content encryption** — governed by the existing vault toggle until Phase D flips it to mandatory. Phase B handles ONLY paths/folders/tags/vault names; `notes.content` (and its `content_ciphertext` from Phase 4) are unchanged here.
- **Vector inversion mitigation** — embedding vectors stay plaintext in Qdrant by design. Documented as a known limitation in the Tier 2 plan.

# References

- Workspace plan: `docs/encryption-tier-2-plan.md` (Phase B section, revised 2026-05-02 commit `16b1902`)
- Phase A.4 backfill template (deleted, read via git): `git show 171ce9e:lib/engram/workers/backfill_bytea_to_s3.ex`
- Phase A.5 read-path collapse template: `git show 29a7bd4:lib/engram/attachments.ex`
- Filter-key memory: `~/.claude/projects/.../memory/project_encryption_tier_2_plan.md`
- BYOK design memory: `~/.claude/projects/.../memory/project_encryption_at_rest.md`
