defmodule Engram.Folders.MovedReadsBudgetTest do
  # S5 readers (Engram#2523), re-review of #2610: with NO folder moved without
  # a cascade (every vault until the writer ships) the shown-path checks must
  # cost nothing. These counts are #2606's (8e37db921), measured on its lib:
  # the moved-vault probe rides an existing read instead of adding one.
  # async: false: another test emptying a node cache mid-count would show
  # up as a statement.
  use Engram.DataCase, async: false

  alias Engram.{Crypto, Folders, Notes, QueryRecorder}

  @same 3
  # +7 for the relocate's after-transaction settle (#2622): one roomless index
  # fold reading the committed row. Constant per relocate.
  # S6 step 3's one hash per path (`PathHmacs.put/2`) costs +1 per newly
  # created folder LEVEL while the write stop is inert; with it on (as here)
  # a new row has no hash, so no statement.
  @relocate 45
  # +1 for the resurrect race fix (#2609): the moved-folder bit read with the
  # row can be a stale `false`, so it is re-read under the vault seq lock
  # (`Location.named?/2`, one `folders_moved_live` index probe).
  # The same: +1 per new folder level only while the stop is inert.
  @resurrect 26
  @restore 53

  setup do
    # Fresh node caches (as query_budget_test.exs), so the warm-up refills
    # every entry and none expires before the measured call.
    Engram.DataCase.clear_request_caches()
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp put!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => path}, actor: "api")

    note
  end

  defp statements(fun) do
    {_, queries} = QueryRecorder.record(fun)
    me = self()
    for %{pid: ^me, sql: sql} <- queries, sql not in ["begin", "commit"], do: sql
  end

  defp count!(fun), do: fun |> statements() |> length()

  # Node caches (the names ledger, plans) are warmed by one identical call
  # first, so a cold or expired entry never shows up as a statement.
  test "a CRDT create of a known note at its own path", %{user: u, vault: v} do
    w = put!(u, v, "A/w.md")
    {:ok, _} = Notes.genesis_crdt_note(u, v, w.id, "A/w.md")
    n = put!(u, v, "A/x.md")
    assert count!(fn -> {:ok, _} = Notes.genesis_crdt_note(u, v, n.id, "A/x.md") end) == @same
  end

  test "a CRDT relocate", %{user: u, vault: v} do
    w = put!(u, v, "A/w.md")
    {:ok, _} = Notes.genesis_crdt_note(u, v, w.id, "W/w.md")
    n = put!(u, v, "A/y.md")
    assert count!(fn -> {:ok, _} = Notes.genesis_crdt_note(u, v, n.id, "B/y.md") end) == @relocate
  end

  test "a CRDT resurrect at another path", %{user: u, vault: v} do
    w = put!(u, v, "A/w.md")
    :deleted = Notes.delete_note_reporting(u, v, "A/w.md")
    {:ok, _} = Notes.genesis_crdt_note(u, v, w.id, "W/w.md")
    n = put!(u, v, "A/z.md")
    :deleted = Notes.delete_note_reporting(u, v, "A/z.md")

    assert count!(fn -> {:ok, _} = Notes.genesis_crdt_note(u, v, n.id, "C/z.md") end) ==
             @resurrect
  end

  test "an undo of a three-note delete", %{user: u, vault: v} do
    _ = Folders.restore_op(u, v, delete_three!(u, v, "W"))
    op = delete_three!(u, v, "D")
    assert count!(fn -> Folders.restore_op(u, v, op) end) == @restore
  end

  defp delete_three!(u, v, folder) do
    op = Ecto.UUID.generate()

    for name <- ["a", "b", "c"], p = "#{folder}/#{name}.md" do
      put!(u, v, p)
      :deleted = Notes.delete_note_reporting(u, v, p, op_id: op)
    end

    op
  end
end
