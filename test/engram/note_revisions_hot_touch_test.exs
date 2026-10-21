defmodule Engram.NoteRevisionsHotTouchTest do
  # Every content write bumps its open version's `updated_at`
  # (Revisions.touch/2). Postgres can update a row in place (HOT, no new
  # index entries) only when no indexed column changes, and `updated_at` was
  # the key of the pending-finalize index, so every touch wrote a new entry
  # into every index of the table. The pending index is keyed on note_id now.
  use Engram.DataCase, async: true

  alias Engram.Notes.Revision
  alias Engram.QueryPlan

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)

    rev =
      Repo.insert!(
        %Revision{
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          actor: "sync",
          origin: "edit",
          session_started_at: DateTime.utc_now()
        },
        skip_tenant_check: true
      )

    %{rev: rev}
  end

  # This transaction's own counters (the sandbox runs the test in one).
  defp hot_updates do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT n_tup_hot_upd FROM pg_stat_xact_user_tables WHERE relname = 'note_revisions'"
      )

    n
  end

  test "a touch of the open version is a HOT update", %{rev: rev} do
    before = hot_updates()

    Repo.query!("UPDATE note_revisions SET updated_at = now() WHERE id = $1", [
      Ecto.UUID.dump!(rev.id)
    ])

    assert hot_updates() == before + 1
  end

  test "the finalize sweep's pending read still has an index" do
    sql =
      "SELECT note_id FROM note_revisions WHERE pending_ciphertext IS NOT NULL " <>
        "AND finalize_failed_at IS NULL AND updated_at < $1"

    assert QueryPlan.generic_plan(sql, analyze: ["note_revisions"]) =~
             "note_revisions_pending_by_note"
  end
end
