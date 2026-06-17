# Sync Cursor Pull — PR B1 (backend) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Backend for the ordered cursor pull: a `vault_device_cursors` watermark table, an opaque `(seq,id)` keyset pull merging notes+attachments (`GET /sync/changes?cursor=`), `change_seq` exposed for bootstrap, dormant `HISTORY_EXPIRED`, and an `attachments.version` column for resurrection-parity. API-tested only — plugin/web migration are PR B2/B3.

**Architecture:** Mirror the existing timestamp keyset pagination (`Notes.list_changes_page/4` + `encode/decode_changes_cursor`, `notes.ex:1496-1591`) but key on `(seq, id)` instead of `(updated_at, id)` and include tombstones. A new `Engram.Sync` context owns the cursor codec + the watermark upsert. A new `SyncController.changes` action merges the two per-table seq feeds by `(seq,id)` (seqs are globally unique per vault — each `next_seq!` bump is distinct across tables — so the keyset is well-ordered across the union). The pull records the device's watermark from the *incoming* cursor (pull-carries-ack).

**Tech Stack:** Elixir 1.17+/Phoenix 1.8+, Ecto, Postgres+RLS (`Repo.with_tenant`), ExUnit + ConnCase. Migration-safety `phase/*` labels; `structure.sql` is a baseline snapshot (NOT regenerated — commit only the migration). One `phase/expand` label, one `mix.exs` bump for this PR.

**Spec:** `docs/superpowers/specs/2026-06-16-sync-cursor-pull-design.md` (PR B1 = the "backend" rollout step).

---

## File structure

**Create:**
- `priv/repo/migrations/<ts>_cursor_pull_expand.exs` — `vault_device_cursors` table + `attachments.version` column (phase/expand).
- `lib/engram/sync.ex` — `Engram.Sync`: cursor codec (`encode_cursor/2`, `decode_cursor/1`) + `record_cursor/3` (watermark upsert) + `retention_floor/1` (returns 0; PR D replaces).
- `lib/engram/sync/device_cursor.ex` — Ecto schema for `vault_device_cursors`.
- `lib/engram_web/controllers/sync_controller.ex` — already exists (`manifest`); ADD `changes/2`.
- `test/engram/sync_test.exs` — codec + watermark tests.
- `test/engram/notes_seq_feed_test.exs`, `test/engram/attachments_seq_feed_test.exs` — context seq-feed tests.
- `test/engram_web/controllers/sync_changes_test.exs` — endpoint tests.

**Modify:**
- `lib/engram/attachments/attachment.ex` — add `field :version, :integer, default: 1` + cast.
- `lib/engram/attachments.ex` — bump `version` in `write_row` (~133) and `delete_attachment` (~250); add `list_changes_by_seq/3`.
- `lib/engram/notes.ex` — add `list_changes_by_seq/3` (mirror `list_changes_page`, keyed on seq, all kinds, tombstones included).
- `lib/engram_web/router.ex` — add `get "/sync/changes", SyncController, :changes` on the vault-scoped pipeline (~line 352, next to `/sync/manifest`).
- `lib/engram_web/controllers/sync_controller.ex` — `manifest/2` response gains `change_seq`.
- `lib/engram/vaults.ex` — add `current_seq/1` (read `change_seq` for a vault).

**Do NOT** touch `structure.sql`.

---

### Task 1: Migration — `vault_device_cursors` + `attachments.version` (phase/expand)

**Files:** Create `priv/repo/migrations/<ts>_cursor_pull_expand.exs` (use a timestamp strictly greater than the newest existing migration; check `ls priv/repo/migrations/`).

- [ ] **Step 1: Write the migration**

```elixir
defmodule Engram.Repo.Migrations.CursorPullExpand do
  use Ecto.Migration

  @moduledoc """
  Sync cursor pull, step B1. phase/expand: purely additive.
  - vault_device_cursors: per-(vault,device) sync watermark (GC + eviction).
  - attachments.version: optimistic-concurrency / resurrection-safety parity
    with notes.version (nullable->default 1; bumped on write).
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create table(:vault_device_cursors, primary_key: false) do
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), null: false
      add :device_id, :text, null: false
      add :last_seq, :bigint, null: false, default: 0
      add :last_seen_at, :utc_datetime, null: false
    end

    create unique_index(:vault_device_cursors, [:vault_id, :device_id], concurrently: true)

    alter table(:attachments) do
      add :version, :integer, null: false, default: 1
    end
  end

  def down do
    alter table(:attachments) do
      remove :version
    end

    drop index(:vault_device_cursors, [:vault_id, :device_id])
    drop table(:vault_device_cursors)
  end
end
```

> Note: `create table` inside `@disable_ddl_transaction` is fine; the `unique_index(..., concurrently: true)` is the part that needs the disabled transaction. If the runner objects to a CONCURRENTLY index on a brand-new (empty) table, drop `concurrently: true` from this one index — a new empty table has nothing to lock. Report which you used.

- [ ] **Step 2: Apply (do NOT regenerate structure.sql)**

Run: `mix ecto.migrate`. Expected: clean. Verify via DB inspection: `vault_device_cursors` exists with the PK+unique index; `attachments.version` is `integer NOT NULL DEFAULT 1`. Optionally `mix ecto.rollback --step 1` then re-migrate.

- [ ] **Step 3: Lint**

Run: `bash priv/repo/lint_migrations.sh` (Squawk). Expected: pass (additive; new table; constant default). Note result.

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/<ts>_cursor_pull_expand.exs
git commit -m "feat(sync): vault_device_cursors + attachments.version (phase/expand)"
```

---

### Task 2: Attachment `version` — schema + bump on write

**Files:** Modify `lib/engram/attachments/attachment.ex`, `lib/engram/attachments.ex`. Test: `test/engram/attachments_seq_feed_test.exs` (version part).

> Scope: column + monotonic bump on every write + surface in the feed. The 409-reject-on-stale-version enforcement is a **push-path** concern and rides with the client migration (B2/B3) — NOT in B1.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Engram.AttachmentsSeqFeedTest do
  use Engram.DataCase, async: true
  alias Engram.{Attachments, Vaults, Repo}

  setup do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  defp b64(b), do: Base.encode64(b)
  defp put(user, vault, path), do: Attachments.upsert_attachment(user, vault, %{"path" => path, "content_base64" => b64(path), "mime_type" => "image/png"})

  test "version starts at 1 and bumps on update", %{user: user, vault: vault} do
    {:ok, a} = put(user, vault, "a.png")
    r1 = Repo.with_tenant(user.id, fn -> Repo.get(Attachments.Attachment, a.id) end)
    {:ok, {:ok, r1}} = {:ok, r1} |> then(&{:ok, &1})
    assert r1.version == 1
    {:ok, _} = put(user, vault, "a.png")
    r2 = Repo.with_tenant(user.id, fn -> Repo.get(Attachments.Attachment, a.id) end)
    {:ok, r2} = {:ok, r2}
    assert r2.version == 2
  end
end
```
> (`Repo.with_tenant` returns `{:ok, value}` — unwrap. Adjust the helper shape to whatever's cleanest; the assertion contract is version=1 on insert, +1 on update.)

- [ ] **Step 2: Run — FAIL** (`version` field unknown / nil). `mix test test/engram/attachments_seq_feed_test.exs`

- [ ] **Step 3: Add the schema field**

In `lib/engram/attachments/attachment.ex` add after `field :seq, :integer`:
```elixir
    field :version, :integer, default: 1
```
and add `:version` to the `cast/3` list in `changeset/2`.

- [ ] **Step 4: Bump version on write**

In `lib/engram/attachments.ex` `write_row/4` (~133), alongside the existing `seq` stamp, set version. For an update, increment the existing row's version; for insert it defaults to 1:
```elixir
    changeset_attrs =
      changeset_attrs
      |> Map.put(:seq, Engram.Vaults.next_seq!(changeset_attrs.vault_id))
      |> then(fn attrs ->
        case existing do
          %Attachment{version: v} -> Map.put(attrs, :version, (v || 1) + 1)
          _ -> attrs
        end
      end)
```
In `delete_attachment/3` (~250), add `version` to the `update_all` set by reading the row's current version first, OR (simpler) increment via SQL is overkill — instead include `version` bump only where a struct is available. For the bulk soft-delete, fetch the row's version is unnecessary for B1's feed (a delete already carries `deleted: true`); leave `delete_attachment` version untouched and note it. (Resurrection-safety on delete is push-path; deletes are conveyed by the tombstone flag, not version.)

- [ ] **Step 5: Run — PASS.** Then regression `mix test test/engram/attachments_test.exs test/engram/attachments_seq_test.exs`.

- [ ] **Step 6: Commit**
```bash
git add lib/engram/attachments/attachment.ex lib/engram/attachments.ex test/engram/attachments_seq_feed_test.exs
git commit -m "feat(sync): add attachments.version, bump on write"
```

---

### Task 3: `Engram.Sync` context — cursor codec + watermark

**Files:** Create `lib/engram/sync.ex`, `lib/engram/sync/device_cursor.ex`. Test: `test/engram/sync_test.exs`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Engram.SyncTest do
  use Engram.DataCase, async: true
  alias Engram.{Sync, Vaults, Repo}

  test "cursor round-trips (seq,id) and rejects garbage" do
    id = Ecto.UUID.generate()
    tok = Sync.encode_cursor(42, id)
    assert {:ok, {42, ^id}} = Sync.decode_cursor(tok)
    assert {:ok, nil} = Sync.decode_cursor(nil)
    assert {:error, :invalid_cursor} = Sync.decode_cursor("not-base64!!")
  end

  test "record_cursor upserts a monotonic watermark per (vault, device)" do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "T"})

    :ok = Sync.record_cursor(user, vault, "dev-1", 10)
    :ok = Sync.record_cursor(user, vault, "dev-1", 25)
    :ok = Sync.record_cursor(user, vault, "dev-1", 20)  # lagging pull must NOT regress

    {:ok, row} =
      Repo.with_tenant(user.id, fn ->
        Repo.get_by(Sync.DeviceCursor, vault_id: vault.id, device_id: "dev-1")
      end)
    assert row.last_seq == 25
  end

  test "record_cursor with nil device_id is a no-op" do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "T"})
    assert :ok = Sync.record_cursor(user, vault, nil, 5)
  end
end
```

- [ ] **Step 2: Run — FAIL** (`Engram.Sync` undefined). `mix test test/engram/sync_test.exs`

- [ ] **Step 3: Schema** — `lib/engram/sync/device_cursor.ex`:
```elixir
defmodule Engram.Sync.DeviceCursor do
  @moduledoc false
  use Engram.Schema
  import Ecto.Changeset

  @primary_key false
  schema "vault_device_cursors" do
    field :vault_id, :binary_id, primary_key: true
    field :device_id, :string, primary_key: true
    field :last_seq, :integer, default: 0
    field :last_seen_at, :utc_datetime
  end

  def changeset(c, attrs) do
    c
    |> cast(attrs, [:vault_id, :device_id, :last_seq, :last_seen_at])
    |> validate_required([:vault_id, :device_id, :last_seq, :last_seen_at])
  end
end
```

- [ ] **Step 4: Context** — `lib/engram/sync.ex`:
```elixir
defmodule Engram.Sync do
  @moduledoc """
  Ordered change-log sync: opaque (seq,id) cursor codec + per-device
  watermark recording (the GC/eviction record; NOT the pagination source
  of truth — clients hold their own position).
  """
  import Ecto.Query
  alias Engram.Repo
  alias Engram.Sync.DeviceCursor

  @doc "Opaque cursor token = url-safe base64 of `<seq>:<id>`."
  def encode_cursor(seq, id) when is_integer(seq) and is_binary(id),
    do: Base.url_encode64("#{seq}:#{id}", padding: false)

  def decode_cursor(nil), do: {:ok, nil}

  def decode_cursor(tok) when is_binary(tok) do
    with {:ok, raw} <- Base.url_decode64(tok, padding: false),
         [seq_str, id_str] <- String.split(raw, ":", parts: 2),
         {seq, ""} <- Integer.parse(seq_str),
         {:ok, id} <- Ecto.UUID.cast(id_str) do
      {:ok, {seq, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  def decode_cursor(_), do: {:error, :invalid_cursor}

  @doc "Retention floor for HISTORY_EXPIRED. 0 until PR D (compaction) lands."
  def retention_floor(_vault), do: 0

  @doc """
  Records a device's confirmed-applied watermark (pull-carries-ack).
  Monotonic via GREATEST so a lagging/out-of-order pull never regresses it.
  No-op when device_id is nil/blank.
  """
  def record_cursor(_user, _vault, device_id, _seq) when device_id in [nil, ""], do: :ok

  def record_cursor(user, vault, device_id, seq) when is_integer(seq) do
    now = DateTime.utc_now(:second)

    Repo.with_tenant(user.id, fn ->
      Repo.insert_all(
        DeviceCursor,
        [%{vault_id: vault.id, device_id: device_id, last_seq: seq, last_seen_at: now}],
        on_conflict: [set: [last_seen_at: now], inc: []],
        conflict_target: [:vault_id, :device_id]
      )

      # GREATEST bump in one statement so concurrent pulls can't regress it.
      Repo.query!(
        "UPDATE vault_device_cursors SET last_seq = GREATEST(last_seq, $3), last_seen_at = $4 WHERE vault_id = $1 AND device_id = $2",
        [Ecto.UUID.dump!(vault.id), device_id, seq, now]
      )
    end)

    :ok
  end

  defdelegate child_spec(opts), to: Engram.Sync.DeviceCursor, as: :__struct__
end
```
> Drop the bogus `defdelegate` line — included only to flag: do NOT add one. The real module ends after `record_cursor`. Expose `Engram.Sync.DeviceCursor` via `alias` in tests as `Sync.DeviceCursor` (add `alias Engram.Sync.DeviceCursor` re-export or reference the full module in tests).

> Implementation note: the insert_all-then-update is a clean upsert-with-GREATEST. If simpler, do a single `INSERT ... ON CONFLICT DO UPDATE SET last_seq = GREATEST(...), last_seen_at = ...` via `Repo.query!`. Pick the clearer one; the contract is the 3 tests.

- [ ] **Step 5: Run — PASS.** `mix test test/engram/sync_test.exs`

- [ ] **Step 6: Commit**
```bash
git add lib/engram/sync.ex lib/engram/sync/device_cursor.ex test/engram/sync_test.exs
git commit -m "feat(sync): Engram.Sync cursor codec + device watermark"
```

---

### Task 4: `Notes.list_changes_by_seq/3` — keyset seq feed

**Files:** Modify `lib/engram/notes.ex`. Test: `test/engram/notes_seq_feed_test.exs`.

> Mirror `list_changes_page/4` (notes.ex:1496-1557) but: filter `seq > cursor` keyed on `(seq, id)`; include ALL kinds (notes + folders) and tombstones (NO `deleted_at` filter, NO `kind == "note"` filter) — the feed must carry deletes/renames/folder ops. Reuse `change_map/1` + `@note_meta_fields`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Engram.NotesSeqFeedTest do
  use Engram.DataCase, async: true
  alias Engram.{Notes, Vaults}

  setup do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "T"})
    %{user: user, vault: vault}
  end

  test "returns rows with seq > cursor in (seq,id) order, includes tombstones", %{user: user, vault: vault} do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})
    {:ok, b} = Notes.upsert_note(user, vault, %{"path" => "b.md", "content" => "B"})
    :ok = Notes.delete_note(user, vault, "a.md")  # tombstone, new seq

    {:ok, %{changes: all}} = Notes.list_changes_by_seq(user, vault, 0)
    # a (deleted) + b both present; the delete carries deleted: true
    assert Enum.any?(all, &(&1.path == "a.md" and &1.deleted))
    assert Enum.any?(all, &(&1.path == "b.md" and not &1.deleted))
    # seq strictly increasing
    seqs = Enum.map(all, & &1.seq)
    assert seqs == Enum.sort(seqs)

    # cursor past b's seq returns nothing newer (no later writes)
    last_seq = List.last(all).seq
    {:ok, %{changes: []}} = Notes.list_changes_by_seq(user, vault, last_seq, after_id: List.last(all).id)
  end

  test "paginates with limit + has_more", %{user: user, vault: vault} do
    for i <- 1..3, do: Notes.upsert_note(user, vault, %{"path" => "n#{i}.md", "content" => "x"})
    {:ok, p1} = Notes.list_changes_by_seq(user, vault, 0, limit: 2)
    assert length(p1.changes) == 2 and p1.has_more
    {c, i} = p1.next
    {:ok, p2} = Notes.list_changes_by_seq(user, vault, c, after_id: i, limit: 2)
    assert length(p2.changes) == 1 and not p2.has_more
  end
end
```
> The fn signature: `list_changes_by_seq(user, vault, after_seq, opts \\ [])` where opts may carry `after_id` (the keyset tiebreak), `limit`, `fields`. Returns `{:ok, %{changes: [change_map ++ %{seq:}], has_more: bool, next: {seq,id} | nil}}`. Each change_map must include `:seq`.

- [ ] **Step 2: Run — FAIL.** `mix test test/engram/notes_seq_feed_test.exs`

- [ ] **Step 3: Implement** in `lib/engram/notes.ex` (mirror `list_changes_page`, key on seq):
```elixir
@doc """
Seq-cursor change feed: rows with `(seq, id) > (after_seq, after_id)`,
ALL kinds + tombstones, ordered by (seq, id), paginated. Each change_map
carries :seq. Used by the unified /sync/changes pull.
"""
def list_changes_by_seq(user, vault, after_seq, opts \\ []) when is_integer(after_seq) do
  limit = opts |> Keyword.get(:limit, @changes_page_max_limit) |> min(@changes_page_max_limit) |> max(1)
  fields = Keyword.get(opts, :fields, :all)
  after_id = Keyword.get(opts, :after_id)

  base =
    from(n in Note,
      where: n.user_id == ^user.id and n.vault_id == ^vault.id and not is_nil(n.seq),
      order_by: [asc: n.seq, asc: n.id],
      limit: ^(limit + 1)
    )

  base =
    if after_id do
      from n in base, where: n.seq > ^after_seq or (n.seq == ^after_seq and n.id > ^after_id)
    else
      from n in base, where: n.seq > ^after_seq
    end

  query =
    case fields do
      :meta -> from(n in base, select: struct(n, @note_meta_fields ++ [:seq]))
      :all -> base
    end

  {:ok, rows} = Repo.with_tenant(user.id, fn -> Repo.all(query) end)
  {page, has_more} = if length(rows) > limit, do: {Enum.take(rows, limit), true}, else: {rows, false}

  changes =
    page
    |> decrypt_or_raise!(user)
    |> Enum.map(fn n -> n |> change_map() |> Map.put(:seq, n.seq) end)

  next = if has_more, do: (last = List.last(page); {last.seq, last.id}), else: nil
  {:ok, %{changes: changes, has_more: has_more, next: next}}
end
```
> Confirm `@note_meta_fields` includes `:id` + `:seq` (add `:seq` to it if `select: struct` needs it; the `:all` path loads the full row so seq is present). Confirm `decrypt_or_raise!` tolerates tombstones (deleted rows) — it does in `list_changes`.

- [ ] **Step 4: Run — PASS.** Then `mix test test/engram/notes_test.exs test/engram/notes_changes_page_test.exs` (no regression).

- [ ] **Step 5: Commit**
```bash
git add lib/engram/notes.ex test/engram/notes_seq_feed_test.exs
git commit -m "feat(sync): Notes.list_changes_by_seq keyset feed"
```

---

### Task 5: `Attachments.list_changes_by_seq/3` — keyset seq feed

**Files:** Modify `lib/engram/attachments.ex`. Test: `test/engram/attachments_seq_feed_test.exs` (append).

> Mirror Task 4 over `Attachment`. Include tombstones (no `deleted_at` filter). Reuse `decrypt_each`. Each entry carries `:seq`, `:version`, `:deleted` (`deleted_at != nil`), `:id`, `:path`, `:mime_type`, `:size_bytes`, `:mtime`, `:updated_at`.

- [ ] **Step 1: Append failing test**
```elixir
  test "attachment seq feed returns seq>cursor incl tombstones", %{user: user, vault: vault} do
    {:ok, a} = put(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    {:ok, %{changes: ch}} = Attachments.list_changes_by_seq(user, vault, 0)
    assert Enum.any?(ch, &(&1.path == "a.png" and &1.deleted))
    assert Enum.all?(ch, &is_integer(&1.seq))
  end
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement** in `lib/engram/attachments.ex`:
```elixir
def list_changes_by_seq(user, vault, after_seq, opts \\ []) when is_integer(after_seq) do
  user = fresh_user(user)
  limit = opts |> Keyword.get(:limit, 500) |> min(500) |> max(1)
  after_id = Keyword.get(opts, :after_id)

  base =
    from(a in Attachment,
      where: a.user_id == ^user.id and a.vault_id == ^vault.id and not is_nil(a.seq),
      order_by: [asc: a.seq, asc: a.id],
      limit: ^(limit + 1)
    )

  base =
    if after_id do
      from a in base, where: a.seq > ^after_seq or (a.seq == ^after_seq and a.id > ^after_id)
    else
      from a in base, where: a.seq > ^after_seq
    end

  Repo.with_tenant(user.id, fn -> Repo.all(base) end)
  |> unwrap_tenant()
  |> case do
    {:ok, atts} ->
      {page, has_more} = if length(atts) > limit, do: {Enum.take(atts, limit), true}, else: {atts, false}

      changes =
        decrypt_each(page, user, fn att, meta ->
          meta
          |> Map.put(:id, att.id)
          |> Map.put(:seq, att.seq)
          |> Map.put(:version, att.version)
          |> Map.put(:deleted, not is_nil(att.deleted_at))
          |> Map.delete(:deleted_at)
        end)

      next = if has_more, do: (l = List.last(page); {l.seq, l.id}), else: nil
      {:ok, %{changes: changes, has_more: has_more, next: next}}

    err ->
      err
  end
end
```

- [ ] **Step 4: Run — PASS.** Then `mix test test/engram/attachments_test.exs`.

- [ ] **Step 5: Commit**
```bash
git add lib/engram/attachments.ex test/engram/attachments_seq_feed_test.exs
git commit -m "feat(sync): Attachments.list_changes_by_seq keyset feed"
```

---

### Task 6: Unified pull endpoint `GET /sync/changes`

**Files:** Modify `lib/engram_web/controllers/sync_controller.ex`, `lib/engram_web/router.ex`. Test: `test/engram_web/controllers/sync_changes_test.exs`.

> Merge the two per-table seq feeds by `(seq, id)` (seqs are globally unique per vault, so the union is well-ordered), page to `limit`, tag each entry `type: "note"|"attachment"`, return `next_cursor` (opaque) + `has_more`, and record the device watermark from the *incoming* cursor (pull-carries-ack). HISTORY_EXPIRED check uses `Sync.retention_floor` (0 → never fires).

- [ ] **Step 1: Write the failing test**
```elixir
defmodule EngramWeb.SyncChangesTest do
  use EngramWeb.ConnCase, async: true
  alias Engram.{Notes, Attachments}

  setup %{conn: conn} do
    user = insert(:user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "k")
    grant_api_write!(user)
    authed = conn |> put_req_header("authorization", "Bearer #{api_key}") |> put_req_header("x-device-id", "dev-1")
    %{conn: authed, user: user, vault: vault}
  end

  test "pulls notes+attachments merged by seq, paginates, records watermark", %{conn: conn, user: user, vault: vault} do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n1.md", "content" => "x"})
    {:ok, _} = Attachments.upsert_attachment(user, vault, %{"path" => "a.png", "content_base64" => Base.encode64("p"), "mime_type" => "image/png"})
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n2.md", "content" => "y"})

    p1 = conn |> get(~p"/api/sync/changes?limit=2") |> json_response(200)
    assert length(p1["changes"]) == 2
    assert p1["has_more"] == true
    assert Enum.all?(p1["changes"], &(&1["type"] in ["note", "attachment"]))
    # strictly increasing seq across the merged page
    seqs = Enum.map(p1["changes"], & &1["seq"])
    assert seqs == Enum.sort(seqs)

    p2 = conn |> get(~p"/api/sync/changes?cursor=#{p1["next_cursor"]}&limit=2") |> json_response(200)
    assert length(p2["changes"]) == 1 and p2["has_more"] == false

    # watermark recorded for dev-1
    {:ok, row} = Engram.Repo.with_tenant(user.id, fn -> Engram.Repo.get_by(Engram.Sync.DeviceCursor, vault_id: vault.id, device_id: "dev-1") end)
    assert row.last_seq >= 1
  end

  test "malformed cursor -> 400", %{conn: conn} do
    assert conn |> get(~p"/api/sync/changes?cursor=%%%bad") |> json_response(400)
  end
end
```

- [ ] **Step 2: Run — FAIL** (route missing). `mix test test/engram_web/controllers/sync_changes_test.exs`

- [ ] **Step 3: Route** — `lib/engram_web/router.ex`, next to `get "/sync/manifest"`:
```elixir
    get "/sync/changes", SyncController, :changes
```

- [ ] **Step 4: Read `X-Device-Id`** — simplest is in the controller (no new plug). In `SyncController.changes`, `device_id = conn |> get_req_header("x-device-id") |> List.first()`.

- [ ] **Step 5: Implement `changes/2`** in `lib/engram_web/controllers/sync_controller.ex`:
```elixir
def changes(conn, params) do
  user = conn.assigns.current_user
  vault = conn.assigns.current_vault
  device_id = conn |> get_req_header("x-device-id") |> List.first()
  limit = parse_limit(params["limit"])

  with {:ok, cursor} <- Engram.Sync.decode_cursor(params["cursor"]) do
    {after_seq, after_id} = cursor || {0, nil}

    if after_seq < Engram.Sync.retention_floor(vault) do
      conn |> put_status(410) |> json(%{error: "history_expired"})
    else
      {:ok, %{changes: notes, has_more: nm}} =
        Engram.Notes.list_changes_by_seq(user, vault, after_seq, after_id: after_id, limit: limit + 1)

      {:ok, %{changes: atts, has_more: am}} =
        Engram.Attachments.list_changes_by_seq(user, vault, after_seq, after_id: after_id, limit: limit + 1)

      merged =
        ((notes |> Enum.map(&Map.put(&1, :type, "note"))) ++
           (atts |> Enum.map(&Map.put(&1, :type, "attachment"))))
        |> Enum.sort_by(&{&1.seq, &1.id})

      {page, has_more} =
        if length(merged) > limit, do: {Enum.take(merged, limit), true}, else: {merged, nm or am}

      next_cursor =
        if has_more do
          last = List.last(page)
          Engram.Sync.encode_cursor(last.seq, last.id)
        end

      # pull-carries-ack: the cursor the client sent = what it durably applied.
      :ok = Engram.Sync.record_cursor(user, vault, device_id, after_seq)

      json(conn, %{changes: Enum.map(page, &change_json/1), next_cursor: next_cursor, has_more: has_more})
    end
  else
    {:error, :invalid_cursor} -> conn |> put_status(400) |> json(%{error: "invalid_cursor"})
  end
end

defp parse_limit(nil), do: 500
defp parse_limit(s) when is_binary(s) do
  case Integer.parse(s) do
    {n, ""} when n > 0 -> min(n, 1000)
    _ -> 500
  end
end

defp change_json(c), do: Map.update(c, :id, nil, & &1)  # already a plain map; serialize keys as-is
```
> `change_json/1`: the merged entries are plain maps (note change_map + :seq + :type; attachment meta + :seq + :version + :type). Phoenix JSON-encodes maps directly, so `Enum.map(page, & &1)` suffices — drop the `change_json` indirection if not needed. Ensure note vs attachment maps both carry the keys the client needs (notes: path/title/folder/tags/version/content_hash/content/deleted/seq/type; attachments: path/mime_type/size_bytes/mtime/version/deleted/seq/type). Content for notes follows the existing dual-field; for B1 default to `:all` or honor a `fields` param — keep parity with the timestamp feed (default `:all`).
>
> **Merge-pagination correctness:** fetching `limit+1` from EACH table then merging + taking `limit` is correct for `has_more` (if either had more, or the merged total exceeds limit). Verify the `has_more` logic against the test (3 items, limit 2 → page 2 then 1).

- [ ] **Step 6: Run — PASS.** `mix test test/engram_web/controllers/sync_changes_test.exs`

- [ ] **Step 7: Commit**
```bash
git add lib/engram_web/controllers/sync_controller.ex lib/engram_web/router.ex test/engram_web/controllers/sync_changes_test.exs
git commit -m "feat(sync): GET /sync/changes unified keyset cursor pull"
```

---

### Task 7: Expose `change_seq` for bootstrap (manifest)

**Files:** Modify `lib/engram/vaults.ex`, `lib/engram_web/controllers/sync_controller.ex`. Test: `test/engram_web/controllers/sync_changes_test.exs` (append) or a manifest test.

> A bootstrapping client needs the vault's current `change_seq` so it can set its cursor to "everything ≤ S" after applying the manifest. Add it to the existing `/sync/manifest` response.

- [ ] **Step 1: Append failing test**
```elixir
  test "manifest includes current change_seq", %{conn: conn, user: user, vault: vault} do
    {:ok, _} = Engram.Notes.upsert_note(user, vault, %{"path" => "n.md", "content" => "x"})
    body = conn |> get(~p"/api/sync/manifest") |> json_response(200)
    assert is_integer(body["change_seq"])
    assert body["change_seq"] >= 1
  end
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: `Vaults.current_seq/1`** in `lib/engram/vaults.ex`:
```elixir
@doc "Reads the vault's current change_seq watermark (read-only)."
def current_seq(vault_id) do
  %{rows: [[seq]]} = Repo.query!("SELECT change_seq FROM vaults WHERE id = $1", [Ecto.UUID.dump!(vault_id)])
  seq
end
```

- [ ] **Step 4:** In `SyncController.render_manifest` (and `render_empty_manifest`), add `change_seq: Engram.Vaults.current_seq(vault.id)` to the JSON (empty manifest → `change_seq: 0` or the real value; the real value is fine).

- [ ] **Step 5: Run — PASS.**

- [ ] **Step 6: Commit**
```bash
git add lib/engram/vaults.ex lib/engram_web/controllers/sync_controller.ex test/engram_web/controllers/sync_changes_test.exs
git commit -m "feat(sync): expose change_seq in manifest for bootstrap"
```

---

### Task 8: Full suite green + version bump

- [ ] **Step 1:** `mix test` — all green. Root-cause any failure (don't skip). A likely one: `@note_meta_fields` missing `:seq` for the `:meta` select — fix by adding `:seq` to that module attr.
- [ ] **Step 2:** Bump `mix.exs` version once (patch +1 over current main — **check `git show origin/main:mix.exs | grep version` at the time and pick strictly greater**, since main moves).
- [ ] **Step 3:** Commit `chore: bump version for cursor-pull backend (PR B1)`.

---

## Self-review

**Spec coverage (B1 = backend rollout step):** `device_id` header read (Task 6) ✅ · `vault_device_cursors` (Tasks 1,3) ✅ · keyset pull (Tasks 4,5,6) ✅ · pull-carries-ack watermark (Tasks 3,6) ✅ · bootstrap `change_seq` (Task 7) ✅ · `HISTORY_EXPIRED` dormant (Task 6, floor=0) ✅ · attachment `version` (Tasks 1,2) ✅ · perf #5 partial index / #4 batch-coalesce — **NOT in this plan; fold into a follow-up task or B-D** (flagged, not silently dropped). Manifest-authoritative reconcile + plugin/web = B2/B3.

**Placeholder scan:** Two intentional "do NOT add this" markers (the bogus `defdelegate` in Task 3, the `change_json` indirection in Task 6) are called out explicitly with the correct alternative — not placeholders. No TBD/TODO.

**Type consistency:** `list_changes_by_seq(user, vault, after_seq, opts)` returns `%{changes, has_more, next}` in both Notes + Attachments. `Engram.Sync.{encode_cursor/2, decode_cursor/1, record_cursor/4, retention_floor/1}` + `Engram.Sync.DeviceCursor` referenced consistently. Cursor token is `<seq>:<id>` base64 everywhere.

**Deferred (flagged):** perf #4/#5; attachment 409-on-stale-version (push-path, B2/B3); the merge-pagination `has_more` edge — verify against Task 6's test before trusting.
