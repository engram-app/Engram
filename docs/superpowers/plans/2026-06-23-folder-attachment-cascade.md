# Folder Attachment Cascade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Folder rename, batch-delete, and batch-move operations cascade to attachments (not just notes), and expose a single-attachment move via MCP.

**Architecture:** Leaf cascade functions live in `Engram.Attachments` (reusing `move_attachment/4` and `batch_delete/3`). The note-side batch functions are extended to *report* the folder paths/pairs they touched. A new `Engram.Folders` coordinator is the single home for "a folder op spans notes + attachments" — it calls the note leg, then fans the touched folders out to the attachment leg. REST + MCP surfaces repoint to the coordinator. `Engram.Notes` stays note-only (it must not depend on `Engram.Attachments`, which already depends on it).

**Tech Stack:** Elixir 1.17 / Phoenix 1.8, Ecto + Postgres (tenant-scoped via `Repo.with_tenant/2`), ExUnit + Mox, MCP JSON-RPC tool layer.

## Global Constraints

- One PR, one `mix.exs` version bump (bump once at PR open; never again on follow-up commits).
- No DB migration — purely behavioral over existing schema.
- `Engram.Notes` MUST NOT call `Engram.Attachments` (cycle: Attachments already aliases `Engram.Notes.PathSanitizer`).
- Cross-table consistency is per-table, not one unified transaction (#614 is a within-table guarantee; each table's renamed-row+tombstone share one seq in one txn — preserved by reusing `move_attachment/4` per item).
- Attachment blob/`storage_key` never moves on rename — path is metadata, blob is content-addressed (unchanged behavior).
- Run `mix format` + `mix credo` + `mix sobelow` before any push (pre-push gates on these).
- Tests run against real Postgres sandbox: `cd backend && mix test <path>`.

---

### Task 1: `Engram.Attachments.rename_folder/4` (leaf cascade)

**Files:**
- Modify: `lib/engram/attachments.ex` (add public fn + private helper, near `batch_move/4` ~line 506)
- Test: `test/engram/attachments_test.exs`

**Interfaces:**
- Consumes: existing `Attachments.move_attachment/4`, `Attachments.list_attachments/2` (returns `{:ok, [%{path: String.t(), ...}]}`).
- Produces: `Attachments.rename_folder(user, vault, old_folder, new_folder) :: {:ok, non_neg_integer()} | {:error, term()}` — moves every live attachment under `old_folder` to the mirrored path under `new_folder`, preserving nested structure; `{:ok, 0}` when none; all-or-nothing on conflict/error.

- [ ] **Step 1: Write the failing test**

Add this helper near the top of the test module (after the `setup` block) if not already present:

```elixir
defp put_attachment(user, vault, path) do
  Mox.stub(Engram.MockStorage, :put, fn key, _bin, _opts -> {:ok, key} end)
  {:ok, att} =
    Attachments.upsert_attachment(user, vault, %{
      "path" => path,
      "content_base64" => Base.encode64("x")
    })
  att
end

defp live_paths(user, vault) do
  {:ok, metas} = Attachments.list_attachments(user, vault)
  metas |> Enum.map(& &1.path) |> Enum.sort()
end
```

Then the test:

```elixir
describe "rename_folder/4 (attachment cascade)" do
  test "moves nested attachments under the folder, preserving structure", %{user: user, vault: vault} do
    put_attachment(user, vault, "Docs/a.png")
    put_attachment(user, vault, "Docs/sub/b.png")
    put_attachment(user, vault, "Other/c.png")

    assert {:ok, 2} = Attachments.rename_folder(user, vault, "Docs", "Archive")

    assert live_paths(user, vault) == ["Archive/a.png", "Archive/sub/b.png", "Other/c.png"]
  end

  test "empty folder is an idempotent no-op", %{user: user, vault: vault} do
    assert {:ok, 0} = Attachments.rename_folder(user, vault, "Nope", "Archive")
  end

  test "conflict when a target path is already occupied", %{user: user, vault: vault} do
    put_attachment(user, vault, "Docs/a.png")
    put_attachment(user, vault, "Archive/a.png")

    assert {:error, {:conflict, "Archive/a.png"}} =
             Attachments.rename_folder(user, vault, "Docs", "Archive")

    # rolled back — source untouched
    assert "Docs/a.png" in live_paths(user, vault)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/engram/attachments_test.exs -k "rename_folder/4 (attachment cascade)"`
Expected: FAIL — `function Engram.Attachments.rename_folder/4 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/engram/attachments.ex` (place after `batch_move/4`):

```elixir
@doc """
Cascades a folder rename across attachments: every live attachment whose path
sits under `old_folder` moves to the mirrored path under `new_folder`,
preserving nested structure. Per-item reuse of `move_attachment/4` (each item's
repoint + old-path tombstone share one seq in one txn — the #614 discipline).
All-or-nothing: a conflict/error on any item rolls back every prior DB write in
the batch. Broadcasts already emitted self-heal on the next pull (same caveat as
`batch_move/4`). Returns `{:ok, count}` (0 = no attachments, idempotent).
"""
@spec rename_folder(map(), map(), String.t(), String.t()) ::
        {:ok, non_neg_integer()} | {:error, term()}
def rename_folder(user, vault, old_folder, new_folder) do
  old_folder = String.trim_trailing(old_folder, "/")
  new_folder = String.trim_trailing(new_folder, "/")
  prefix = old_folder <> "/"
  old_len = String.length(old_folder)

  case list_attachments(user, vault) do
    {:ok, metas} ->
      pairs =
        metas
        |> Enum.filter(&String.starts_with?(&1.path, prefix))
        |> Enum.map(fn %{path: old_path} ->
          {old_path, new_folder <> String.slice(old_path, old_len..-1//1)}
        end)

      do_rename_folder_pairs(user, vault, pairs)

    {:error, reason} ->
      {:error, reason}
  end
end

defp do_rename_folder_pairs(_user, _vault, []), do: {:ok, 0}

defp do_rename_folder_pairs(user, vault, pairs) do
  Repo.transaction(fn ->
    Enum.reduce_while(pairs, 0, fn {old_path, new_path}, count ->
      case move_attachment(user, vault, old_path, new_path) do
        {:ok, _} -> {:cont, count + 1}
        {:error, :conflict} -> {:halt, {:rollback, {:conflict, new_path}}}
        {:error, :not_found} -> {:halt, {:rollback, {:not_found, old_path}}}
        {:error, reason} -> {:halt, {:rollback, reason}}
      end
    end)
    |> case do
      {:rollback, reason} -> Repo.rollback(reason)
      count -> count
    end
  end)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/engram/attachments_test.exs -k "rename_folder/4 (attachment cascade)"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd backend && git add lib/engram/attachments.ex test/engram/attachments_test.exs
git commit -m "feat(attachments): cascade folder rename across attachments"
```

---

### Task 2: `Engram.Attachments.delete_folder/3` (leaf cascade)

**Files:**
- Modify: `lib/engram/attachments.ex` (add after `rename_folder/4`)
- Test: `test/engram/attachments_test.exs`

**Interfaces:**
- Consumes: existing `Attachments.batch_delete/3` (`{:ok, %{deleted: n}}`), `Attachments.list_attachments/2`.
- Produces: `Attachments.delete_folder(user, vault, folder) :: {:ok, non_neg_integer()} | {:error, term()}` — soft-deletes every live attachment under `folder` (incl. nested); `{:ok, 0}` when none.

- [ ] **Step 1: Write the failing test**

```elixir
describe "delete_folder/3 (attachment cascade)" do
  test "soft-deletes nested attachments under the folder", %{user: user, vault: vault} do
    Mox.stub(Engram.MockStorage, :delete, fn _key -> :ok end)
    put_attachment(user, vault, "Docs/a.png")
    put_attachment(user, vault, "Docs/sub/b.png")
    put_attachment(user, vault, "Other/c.png")

    assert {:ok, 2} = Attachments.delete_folder(user, vault, "Docs")
    assert live_paths(user, vault) == ["Other/c.png"]
  end

  test "empty folder is an idempotent no-op", %{user: user, vault: vault} do
    assert {:ok, 0} = Attachments.delete_folder(user, vault, "Nope")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/engram/attachments_test.exs -k "delete_folder/3 (attachment cascade)"`
Expected: FAIL — `function Engram.Attachments.delete_folder/3 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/engram/attachments.ex` after `do_rename_folder_pairs/3`:

```elixir
@doc """
Cascades a folder delete across attachments: soft-deletes every live attachment
whose path sits under `folder` (incl. nested). Reuses `batch_delete/3` so each
delete broadcasts + runs best-effort blob cleanup. Returns `{:ok, count}` (0 =
no attachments, idempotent).
"""
@spec delete_folder(map(), map(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
def delete_folder(user, vault, folder) do
  prefix = String.trim_trailing(folder, "/") <> "/"

  case list_attachments(user, vault) do
    {:ok, metas} ->
      paths = metas |> Enum.map(& &1.path) |> Enum.filter(&String.starts_with?(&1, prefix))
      {:ok, %{deleted: n}} = batch_delete(user, vault, paths)
      {:ok, n}

    {:error, reason} ->
      {:error, reason}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/engram/attachments_test.exs -k "delete_folder/3 (attachment cascade)"`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd backend && git add lib/engram/attachments.ex test/engram/attachments_test.exs
git commit -m "feat(attachments): cascade folder delete across attachments"
```

---

### Task 3: `Notes.batch_delete_folders/3` reports touched folders

**Files:**
- Modify: `lib/engram/notes.ex:2562-2564` (the `folders ->` branch return)
- Test: `test/engram/notes_folder_marker_test.exs` (or wherever `batch_delete_folders` is tested — search first)

**Interfaces:**
- Consumes: existing `do_delete_folders/3` (`{:ok, %{deleted: n}}`).
- Produces: `Notes.batch_delete_folders/3` now returns `{:ok, %{deleted: n, folders: [String.t()]}}` (additive `:folders` key — the resolved folder paths). Existing callers matching `%{deleted: n}` keep working.

- [ ] **Step 1: Write the failing test**

First find the existing test file: `cd backend && grep -rln "batch_delete_folders" test/`. Add this test there (mirror that file's setup for creating a folder marker + note):

```elixir
test "batch_delete_folders reports the resolved folder paths it touched", %{user: user, vault: vault} do
  {:ok, marker} = Notes.create_folder_marker(user, vault, "Docs")
  assert {:ok, %{deleted: _, folders: folders}} =
           Notes.batch_delete_folders(user, vault, [marker.id])
  assert folders == ["Docs"]
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test <that_test_file> -k "reports the resolved folder paths"`
Expected: FAIL — returned map has no `:folders` key (KeyError / match error).

- [ ] **Step 3: Write minimal implementation**

In `lib/engram/notes.ex`, change the `folders ->` branch of `batch_delete_folders/3` (currently ~line 2562):

```elixir
          folders ->
            {:ok, %{deleted: n}} = do_delete_folders(user, vault, folders)
            %{deleted: n, folders: folders}
```

(Note: `folders` is built by `reduce_while` with `[... | acc]`, so it is reverse-of-input order; that's fine — the coordinator iterates it order-independently.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test <that_test_file> -k "reports the resolved folder paths"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd backend && git add lib/engram/notes.ex <that_test_file>
git commit -m "feat(notes): batch_delete_folders reports resolved folder paths"
```

---

### Task 4: `Notes.batch_move_folders/4` reports `{old, new}` pairs

**Files:**
- Modify: `lib/engram/notes.ex` — `reduce_move_folders/5` (~2634) + `move_folder_into/5` (~2654)
- Test: same test file as Task 3 (search `batch_move_folders`)

**Interfaces:**
- Consumes: existing `rename_folder/4`, `get_folder_marker_by_id/3`, `hydrate_folder_marker/2`.
- Produces: `Notes.batch_move_folders/4` now returns `{:ok, %{moved: n, pairs: [{old_folder, new_folder}]}}` (additive `:pairs` key). `move_folder_into/5` returns `{:ok, {source_folder, new_folder}}`.

- [ ] **Step 1: Write the failing test**

```elixir
test "batch_move_folders reports {old, new} folder pairs", %{user: user, vault: vault} do
  {:ok, src} = Notes.create_folder_marker(user, vault, "Docs")
  {:ok, _dst} = Notes.create_folder_marker(user, vault, "Archive")

  assert {:ok, %{moved: 1, pairs: pairs}} =
           Notes.batch_move_folders(user, vault, [src.id], {:path, "Archive"})

  assert pairs == [{"Docs", "Archive/Docs"}]
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test <that_test_file> -k "reports {old, new} folder pairs"`
Expected: FAIL — returned map has no `:pairs` key.

- [ ] **Step 3: Write minimal implementation**

In `lib/engram/notes.ex`, update `reduce_move_folders/5` to accumulate pairs:

```elixir
defp reduce_move_folders(user, vault, marker_ids, target_folder, dek) do
  marker_ids
  |> Enum.reduce_while(%{moved: 0, pairs: []}, fn id, acc ->
    case move_folder_into(user, vault, id, target_folder, dek) do
      {:ok, {old_folder, new_folder}} ->
        {:cont, %{acc | moved: acc.moved + 1, pairs: [{old_folder, new_folder} | acc.pairs]}}

      {:error, :not_found} -> {:halt, {:rollback, {:not_found, id}}}
      {:error, :conflict} -> {:halt, {:rollback, {:conflict, id}}}
      {:error, :cycle} -> {:halt, {:rollback, {:cycle, id}}}
      {:error, reason} -> {:halt, {:rollback, reason}}
    end
  end)
  |> case do
    {:rollback, reason} -> Repo.rollback(reason)
    %{pairs: pairs} = acc -> %{acc | pairs: Enum.reverse(pairs)}
  end
end
```

And change `move_folder_into/5` to return the source folder alongside the new one. Replace its success branch:

```elixir
          case rename_folder(user, vault, source_folder, new_folder) do
            {:ok, _count} -> {:ok, {source_folder, new_folder}}
            {:error, :conflict} -> {:error, :conflict}
            {:error, reason} -> {:error, reason}
          end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test <that_test_file> -k "reports {old, new} folder pairs"`
Expected: PASS.

Also run the full move/delete folder suites to confirm no regression in the existing `%{moved: n}` matchers:
Run: `cd backend && mix test <that_test_file>`
Expected: PASS (all).

- [ ] **Step 5: Commit**

```bash
cd backend && git add lib/engram/notes.ex <that_test_file>
git commit -m "feat(notes): batch_move_folders reports {old,new} folder pairs"
```

---

### Task 5: `Engram.Folders` coordinator

**Files:**
- Create: `lib/engram/folders.ex`
- Test: `test/engram/folders_test.exs`

**Interfaces:**
- Consumes: `Notes.rename_folder/4` (`{:ok, count}`), `Notes.batch_delete_folders/3` (`{:ok, %{deleted, folders}}`), `Notes.batch_move_folders/4` (`{:ok, %{moved, pairs}}`), `Attachments.rename_folder/4`, `Attachments.delete_folder/3`.
- Produces:
  - `Folders.rename(user, vault, old, new) :: {:ok, %{notes: n, attachments: a}} | {:error, term()}`
  - `Folders.batch_delete(user, vault, marker_ids) :: {:ok, %{notes: n, attachments: a}} | {:error, term()}`
  - `Folders.batch_move(user, vault, marker_ids, target) :: {:ok, %{notes: n, attachments: a}} | {:error, term()}`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Engram.FoldersTest do
  use Engram.DataCase, async: false

  alias Engram.{Attachments, Folders, Notes}

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
    Mox.stub(Engram.MockStorage, :put, fn key, _bin, _opts -> {:ok, key} end)
    Mox.stub(Engram.MockStorage, :delete, fn _key -> :ok end)

    user = insert(:user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp att_paths(user, vault) do
    {:ok, metas} = Attachments.list_attachments(user, vault)
    metas |> Enum.map(& &1.path) |> Enum.sort()
  end

  defp put_att(user, vault, path) do
    {:ok, _} =
      Attachments.upsert_attachment(user, vault, %{"path" => path, "content_base64" => Base.encode64("x")})
  end

  test "rename/4 moves both a note and an attachment under the folder", %{user: user, vault: vault} do
    {:ok, _note} = Notes.create_or_update_note(user, vault, %{"path" => "Docs/n.md", "content" => "hi"})
    put_att(user, vault, "Docs/a.png")

    assert {:ok, %{notes: 1, attachments: 1}} = Folders.rename(user, vault, "Docs", "Archive")
    assert att_paths(user, vault) == ["Archive/a.png"]
  end

  test "batch_delete/3 soft-deletes the folder's attachments", %{user: user, vault: vault} do
    {:ok, marker} = Notes.create_folder_marker(user, vault, "Docs")
    put_att(user, vault, "Docs/a.png")

    assert {:ok, %{attachments: 1}} = Folders.batch_delete(user, vault, [marker.id])
    assert att_paths(user, vault) == []
  end

  test "batch_move/4 moves the folder's attachments under the target", %{user: user, vault: vault} do
    {:ok, src} = Notes.create_folder_marker(user, vault, "Docs")
    {:ok, _dst} = Notes.create_folder_marker(user, vault, "Archive")
    put_att(user, vault, "Docs/a.png")

    assert {:ok, %{attachments: 1}} = Folders.batch_move(user, vault, [src.id], {:path, "Archive"})
    assert att_paths(user, vault) == ["Archive/Docs/a.png"]
  end
end
```

> Note: confirm the exact note-creation helper name (`create_or_update_note/3` vs `upsert_note`) with `grep -n "def create_or_update_note\|def upsert_note" lib/engram/notes.ex` and use whichever exists; the assertion logic is unchanged.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/engram/folders_test.exs`
Expected: FAIL — `Engram.Folders` is undefined.

- [ ] **Step 3: Write minimal implementation**

Create `lib/engram/folders.ex`:

```elixir
defmodule Engram.Folders do
  @moduledoc """
  Coordinates folder-level operations that span both notes and attachments.

  Folder rename/delete/move must touch the `notes` AND `attachments` tables.
  `Engram.Notes` cannot depend on `Engram.Attachments` (the latter already
  depends on the former), so this module is the single place that fans a folder
  op out to both. Every folder-mutating surface (REST + MCP) routes through here
  so no caller can forget the attachment leg.

  Consistency is per-table (not one unified transaction): the note leg commits
  atomically, then the attachment leg cascades. A client may briefly observe the
  note move ahead of the attachment move; sync converges on the next pull.
  """

  alias Engram.Attachments
  alias Engram.Notes

  @type counts :: %{notes: non_neg_integer(), attachments: non_neg_integer()}

  @spec rename(map(), map(), String.t(), String.t()) :: {:ok, counts()} | {:error, term()}
  def rename(user, vault, old_folder, new_folder) do
    with {:ok, notes} <- Notes.rename_folder(user, vault, old_folder, new_folder),
         {:ok, atts} <- Attachments.rename_folder(user, vault, old_folder, new_folder) do
      {:ok, %{notes: notes, attachments: atts}}
    end
  end

  @spec batch_delete(map(), map(), [String.t()]) :: {:ok, counts()} | {:error, term()}
  def batch_delete(user, vault, marker_ids) do
    with {:ok, %{deleted: notes, folders: folders}} <-
           Notes.batch_delete_folders(user, vault, marker_ids),
         {:ok, atts} <- delete_attachments_for(user, vault, folders) do
      {:ok, %{notes: notes, attachments: atts}}
    end
  end

  @spec batch_move(map(), map(), [String.t()], String.t() | {:path, String.t()}) ::
          {:ok, counts()} | {:error, term()}
  def batch_move(user, vault, marker_ids, target) do
    with {:ok, %{moved: notes, pairs: pairs}} <-
           Notes.batch_move_folders(user, vault, marker_ids, target),
         {:ok, atts} <- rename_attachments_for(user, vault, pairs) do
      {:ok, %{notes: notes, attachments: atts}}
    end
  end

  defp delete_attachments_for(user, vault, folders) do
    Enum.reduce_while(folders, {:ok, 0}, fn folder, {:ok, total} ->
      case Attachments.delete_folder(user, vault, folder) do
        {:ok, n} -> {:cont, {:ok, total + n}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp rename_attachments_for(user, vault, pairs) do
    Enum.reduce_while(pairs, {:ok, 0}, fn {old, new}, {:ok, total} ->
      case Attachments.rename_folder(user, vault, old, new) do
        {:ok, n} -> {:cont, {:ok, total + n}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/engram/folders_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd backend && git add lib/engram/folders.ex test/engram/folders_test.exs
git commit -m "feat(folders): coordinator cascading folder ops to attachments"
```

---

### Task 6: Repoint REST `FoldersController` to the coordinator

**Files:**
- Modify: `lib/engram_web/controllers/folders_controller.ex` — `rename/2` (~226), batch-delete action (~279), batch-move action (~329, ~343)
- Test: `test/engram_web/controllers/folders_controller_test.exs` (search; add one end-to-end surface test)

**Interfaces:**
- Consumes: `Engram.Folders.rename/4`, `.batch_delete/3`, `.batch_move/4` (Task 5).
- Produces: the three REST actions now cascade attachments. JSON responses keep existing keys; `rename` additionally returns the cascade counts map.

- [ ] **Step 1: Write the failing test (surface-level drift guard)**

Find the controller test file: `cd backend && grep -rln "folders" test/engram_web/controllers/`. Mirror its auth/setup; add:

```elixir
test "PUT rename cascades to attachments", %{conn: conn, user: user, vault: vault} do
  Mox.stub(Engram.MockStorage, :put, fn key, _b, _o -> {:ok, key} end)
  {:ok, _} = Engram.Attachments.upsert_attachment(user, vault, %{"path" => "Docs/a.png", "content_base64" => Base.encode64("x")})

  conn
  |> put(~p"/api/folders/Docs", %{"old_path" => "Docs", "new_path" => "Archive"})
  |> json_response(200)

  {:ok, metas} = Engram.Attachments.list_attachments(user, vault)
  assert Enum.map(metas, & &1.path) == ["Archive/a.png"]
end
```

> Confirm the exact route/params shape from the existing rename test in that file before finalizing the `put(...)` line; the assertion is what matters.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test <controller_test_file> -k "cascades to attachments"`
Expected: FAIL — attachment still at `Docs/a.png` (controller still calls `Notes.rename_folder`).

- [ ] **Step 3: Write minimal implementation**

Add `alias Engram.Folders` to the controller's alias block. Then:

At `rename/2` (~226), replace `Notes.rename_folder(user, vault, old_path, new_path)` with `Folders.rename(user, vault, old_path, new_path)` and adjust the `case` to match `{:ok, %{notes: _, attachments: _} = counts}` (render `counts` in the JSON instead of the bare count). Keep the existing `{:error, :conflict}` / other error branches as-is.

At the batch-delete action (~279), replace `Notes.batch_delete_folders(user, vault, ids)` with `Folders.batch_delete(user, vault, ids)`. The success match `{:ok, %{deleted: _}}` becomes `{:ok, %{notes: _, attachments: _} = counts}` — render `counts`.

At the batch-move action (~329 and ~343), replace both `Notes.batch_move_folders(user, vault, ids, <target>)` calls with `Folders.batch_move(user, vault, ids, <target>)`. Success match `{:ok, %{moved: _}}` becomes `{:ok, %{notes: _, attachments: _} = counts}` — render `counts`. Error tuples (`{:error, {:conflict, id}}`, `{:not_found, id}`, `{:cycle, id}`) are unchanged — they still propagate from the note leg through the coordinator's `with`.

> Read each action's current response-rendering block before editing so the JSON keys the frontend expects are preserved (add the new counts, don't drop existing fields).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test <controller_test_file>`
Expected: PASS (new test + existing folder controller tests still green).

- [ ] **Step 5: Commit**

```bash
cd backend && git add lib/engram_web/controllers/folders_controller.ex <controller_test_file>
git commit -m "feat(web): folder rename/delete/move REST cascades to attachments"
```

---

### Task 7: Repoint MCP `rename_folder` handler to the coordinator

**Files:**
- Modify: `lib/engram/mcp/handlers.ex:408-416` (the `rename_folder` clause)
- Test: `test/engram/mcp/handlers_test.exs` (search for the existing `rename_folder` handler test)

**Interfaces:**
- Consumes: `Engram.Folders.rename/4`.
- Produces: MCP `rename_folder` cascades attachments; result string reports both counts.

- [ ] **Step 1: Write the failing test**

Mirror the existing MCP handler test setup (it builds `user`/`vault` and calls `Handlers.handle/4`). Add:

```elixir
test "rename_folder cascades attachments and reports both counts", %{user: user, vault: vault} do
  Mox.stub(Engram.MockStorage, :put, fn key, _b, _o -> {:ok, key} end)
  {:ok, _} = Engram.Attachments.upsert_attachment(user, vault, %{"path" => "Docs/a.png", "content_base64" => Base.encode64("x")})

  assert {:ok, msg} =
           Engram.MCP.Handlers.handle("rename_folder", user, vault, %{
             "old_folder" => "Docs",
             "new_folder" => "Archive"
           })

  assert msg =~ "1 attachment"
  {:ok, metas} = Engram.Attachments.list_attachments(user, vault)
  assert Enum.map(metas, & &1.path) == ["Archive/a.png"]
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/engram/mcp/handlers_test.exs -k "rename_folder cascades attachments"`
Expected: FAIL — attachment not moved; message has no attachment count.

- [ ] **Step 3: Write minimal implementation**

Replace the `rename_folder` clause in `lib/engram/mcp/handlers.ex` (currently ~408):

```elixir
def handle("rename_folder", user, vault, args) do
  old_folder = args["old_folder"] || ""
  new_folder = args["new_folder"] || ""

  case Engram.Folders.rename(user, vault, old_folder, new_folder) do
    {:ok, %{notes: n, attachments: a}} ->
      {:ok,
       "Folder renamed: #{old_folder} -> #{new_folder} " <>
         "(#{n} notes, #{a} attachments updated)"}

    {:error, :conflict} ->
      {:ok, "Folder rename conflict: #{new_folder} already exists"}
  end
end
```

> If the existing clause matched other error shapes, preserve them — read the current clause first. `Notes.rename_folder/4` returns `{:error, :conflict}`; keep any branch the old code had.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/engram/mcp/handlers_test.exs -k "rename_folder cascades attachments"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd backend && git add lib/engram/mcp/handlers.ex test/engram/mcp/handlers_test.exs
git commit -m "feat(mcp): rename_folder cascades attachments"
```

---

### Task 8: MCP `move_attachment` tool

**Files:**
- Modify: `lib/engram/mcp/tools.ex` (add `move_attachment_def/0`, register in `list/0` at ~line 35)
- Modify: `lib/engram/mcp/handlers.ex` (add `handle("move_attachment", ...)` before the catch-all at ~424)
- Modify: `lib/engram_web/controllers/mcp_controller.ex` (add `"move_attachment" => :move_attachment` to the dispatch map ~line 36, matching how `rename_folder` is listed)
- Test: `test/engram/mcp/handlers_test.exs`

**Interfaces:**
- Consumes: existing `Engram.Attachments.move_attachment/4` (`{:ok, att} | {:error, :conflict | :not_found}`).
- Produces: MCP tool `move_attachment` with required `old_path` + `new_path`.

- [ ] **Step 1: Write the failing test**

```elixir
test "move_attachment moves a single attachment", %{user: user, vault: vault} do
  Mox.stub(Engram.MockStorage, :put, fn key, _b, _o -> {:ok, key} end)
  {:ok, _} = Engram.Attachments.upsert_attachment(user, vault, %{"path" => "a.png", "content_base64" => Base.encode64("x")})

  assert {:ok, msg} =
           Engram.MCP.Handlers.handle("move_attachment", user, vault, %{
             "old_path" => "a.png",
             "new_path" => "img/a.png"
           })

  assert msg =~ "img/a.png"
  {:ok, metas} = Engram.Attachments.list_attachments(user, vault)
  assert Enum.map(metas, & &1.path) == ["img/a.png"]
end

test "move_attachment registered as a tool" do
  assert {:ok, %{name: "move_attachment"}} = Engram.MCP.Tools.get("move_attachment")
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/engram/mcp/handlers_test.exs -k "move_attachment"`
Expected: FAIL — handler hits catch-all (unknown tool) / `Tools.get` returns `:error`.

- [ ] **Step 3: Write minimal implementation**

In `lib/engram/mcp/tools.ex`, add `move_attachment_def()` to the `list/0` list (after `delete_note_def()`), and define:

```elixir
defp move_attachment_def do
  %{
    name: "move_attachment",
    description:
      "Move or rename a single attachment (image, PDF, or other binary file) to " <>
        "a new path. Syncs to all connected Obsidian devices. The file's content " <>
        "is unchanged; only its path moves.",
    inputSchema: %{
      "type" => "object",
      "properties" => %{
        "old_path" => %{"type" => "string", "description" => "Current path of the attachment"},
        "new_path" => %{"type" => "string", "description" => "New path for the attachment"}
      },
      "required" => ["old_path", "new_path"]
    },
    handler: &Handlers.handle("move_attachment", &1, &2, &3)
  }
end
```

In `lib/engram/mcp/handlers.ex`, add before the catch-all `handle(name, ...)` clause (~424):

```elixir
def handle("move_attachment", user, vault, args) do
  old_path = args["old_path"] || ""
  new_path = args["new_path"] || ""

  case Engram.Attachments.move_attachment(user, vault, old_path, new_path) do
    {:ok, _att} -> {:ok, "Attachment moved: #{old_path} -> #{new_path}"}
    {:error, :not_found} -> {:ok, "Attachment not found: #{old_path}"}
    {:error, :conflict} -> {:ok, "Attachment already exists at: #{new_path}"}
  end
end
```

In `lib/engram_web/controllers/mcp_controller.ex`, add `"move_attachment" => :move_attachment` to the dispatch/tool-name map alongside `"rename_folder" => :rename_folder` (~line 36) so the tool is callable over JSON-RPC.

> Read the `mcp_controller.ex` map first to confirm the exact shape — if tools are auto-derived from `Tools.list/0` rather than a hardcoded map, this controller edit may be unnecessary. Verify before editing.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/engram/mcp/handlers_test.exs -k "move_attachment"`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd backend && git add lib/engram/mcp/tools.ex lib/engram/mcp/handlers.ex lib/engram_web/controllers/mcp_controller.ex test/engram/mcp/handlers_test.exs
git commit -m "feat(mcp): add move_attachment tool"
```

---

### Task 9: Full-suite verification + version bump + docs

**Files:**
- Modify: `mix.exs` (single version bump)
- Modify: `docs/context/` (add/update a context doc noting folder ops cascade attachments) — optional but per repo convention

- [ ] **Step 1: Run the relevant suites green**

Run:
```bash
cd backend && mix test test/engram/attachments_test.exs test/engram/folders_test.exs test/engram/mcp/ <notes_folder_test_file> <controller_test_file>
```
Expected: all PASS.

- [ ] **Step 2: Lint gates**

Run: `cd backend && mix format && mix credo --strict && mix sobelow --config`
Expected: no new violations. Fix any formatting/credo issues inline.

- [ ] **Step 3: Bump version once**

Edit `mix.exs` `version:` — single patch bump for this PR. Do not bump again on later commits.

- [ ] **Step 4: Commit**

```bash
cd backend && git add mix.exs
git commit -m "chore: bump version for folder attachment cascade"
```

- [ ] **Step 5: Open the PR**

Push the branch and open one PR covering all of the above (single PR per workspace convention). Title: `feat: cascade folder rename/delete/move to attachments + MCP move_attachment`.

---

## Self-Review

**Spec coverage:**
- Goal 1 (rename cascades attachments) → Task 1 (leaf) + Task 5 (coordinator) + Tasks 6/7 (surfaces). ✓
- Goal 2 (delete cascades attachments) → Task 2 (leaf) + Task 3 (Notes reports folders) + Task 5 + Task 6. ✓
- Folder MOVE parity (added at full-parity scope decision) → Task 4 (Notes reports pairs) + Task 5 + Task 6. ✓
- Goal 3 (MCP move_attachment) → Task 8. ✓
- Separate-txn-per-table constraint → leaf fns reuse `move_attachment`/`batch_delete`; coordinator fans out post-commit. ✓
- Cycle constraint (Notes ⊥ Attachments) → coordinator owns the cross-context calls; Notes only gained additive return data. ✓

**Placeholder scan:** Test file names left as `<that_test_file>` / `<controller_test_file>` are explicit "search-then-fill" instructions with the grep command provided, not silent TBDs. Note-helper name in Task 5 flagged with a verification grep. No code-body placeholders.

**Type consistency:** `Folders.rename/batch_delete/batch_move` all return `{:ok, %{notes:, attachments:}}`; coordinator consumes `Notes.batch_delete_folders → %{deleted, folders}` (Task 3) and `Notes.batch_move_folders → %{moved, pairs}` (Task 4) — names match across tasks. `Attachments.rename_folder/4` + `delete_folder/3` return `{:ok, integer}` consistently consumed by the coordinator reducers.

**Open risk (carried from spec):** on `rename`, if the note leg commits then the attachment leg returns `{:error, :conflict}`, notes have moved but attachments have not. Documented, user-recoverable, not engineered around for v1.
