defmodule Engram.NotesSeqFeedColumnsTest do
  # Guard: a catch-up page does not read CRDT state.
  #
  # `list_changes_by_seq(:all)` (sync pull) selected the whole row, so every
  # page detoasted and transferred `crdt_state_ciphertext`, about half of a
  # note's bytes in prod (2026-10-20 audit: 7.1 KB of 15 KB), and the byte
  # budget counted none of it. Nothing on the page path reads it: change maps
  # carry no CRDT state, and stale-facade resolution re-reads its own rows.
  use Engram.DataCase, async: true

  alias Engram.Notes
  alias Engram.QueryRecorder

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Feed", Ecto.UUID.generate())

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "hello"}, actor: "api")

    %{user: user, vault: vault}
  end

  test "the page SELECT leaves out crdt_state, and content still ships", %{user: u, vault: v} do
    {{:ok, %{changes: changes}}, queries} =
      QueryRecorder.record(fn -> Notes.list_changes_by_seq(u, v, 0) end)

    assert [%{path: "A.md", content: "hello"}] = changes

    # Own process only: the recorder sees async siblings' queries too (e.g. a
    # direct `Repo.all(Note)` in NotesSeqTest selects every column).
    me = self()

    page =
      for %{sql: sql, pid: ^me} <- queries,
          sql =~ ~s(FROM "notes"),
          sql =~ ~s("seq" > ),
          not (sql =~ "pg_column_size"),
          do: sql

    assert page != [], QueryRecorder.format(queries)
    for sql <- page, do: refute(sql =~ "crdt_state_ciphertext", sql)
  end
end
