defmodule Engram.DataMigrations.SelfHostJumpTest do
  @moduledoc """
  A self-hoster jumping from a release before `note_bodies` straight to
  R8(c), on one node: every note is pre-split (only the `notes` columns, no
  body row). The upgrade's migrations run before boot, and migration
  20261107120000 gives every note its body row, byte for byte what the app
  writes, so every note reads before any data migration runs. Then writes
  land before the ledgers reach them; run every registered data migration
  until NoteSplit and NoteBodyColumnsNull are done: every note reads its
  latest content throughout, and both `notes` ciphertext columns end NULL.
  """
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations
  alias Engram.DataMigrations.{NoteBodyColumnsNull, NoteSplit}
  alias Engram.Notes
  alias Engram.Notes.CrdtCheckpoint
  alias Engram.Workers.DataMigrationsRunner

  setup do
    IdWindows.reset_walks()
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Jump", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp write!(u, v, path, content) do
    {:ok, n} = Notes.upsert_note(u, v, %{"path" => path, "content" => content}, actor: "api")
    n
  end

  defp doc_with(text) do
    doc = Yex.Doc.new()
    Yex.Text.insert(Yex.Doc.get_text(doc, "content"), 0, text)
    doc
  end

  defp read!(u, v, path) do
    assert {:ok, %{content: content}} = Notes.get_note(u, v, path)
    content
  end

  # What a release before `note_bodies` leaves: the `notes` copies, no body.
  defp pre_split!(u) do
    ids =
      Repo.query!("SELECT id FROM notes WHERE user_id = $1 AND kind = 'note'", [
        Ecto.UUID.dump!(u.id)
      ]).rows
      |> Enum.map(fn [id] -> Ecto.UUID.load!(id) end)

    Enum.each(ids, &Engram.Fixtures.old_release_notes_copy!/1)
    Repo.query!("DELETE FROM note_bodies WHERE user_id = $1", [Ecto.UUID.dump!(u.id)])
  end

  defp copies(u) do
    Repo.query!(
      """
      SELECT count(*) FILTER (WHERE content_ciphertext IS NOT NULL OR crdt_state_ciphertext IS NOT NULL)
      FROM notes WHERE user_id = $1 AND kind = 'note'
      """,
      [Ecto.UUID.dump!(u.id)]
    ).rows
  end

  defp bodies(u) do
    Repo.query!(
      """
      SELECT note_id, user_id, key_version, content_ct, crdt_ct, crdt_head,
        content_bytes, state_bytes, envelope_legacy
      FROM note_bodies WHERE user_id = $1 ORDER BY note_id
      """,
      [Ecto.UUID.dump!(u.id)]
    ).rows
  end

  defp run_all do
    for mod <- DataMigrationsRunner.migrations(), do: DataMigrationsRunner.run(mod)
    :ok
  end

  defp both_done? do
    DataMigrations.done?(NoteSplit.name(), NoteSplit.version()) and
      DataMigrations.done?(NoteBodyColumnsNull.name(), NoteBodyColumnsNull.version())
  end

  test "pre-split notes plus release-B writes: every ledger closes, reads stay right, no copies",
       %{user: u, vault: v} do
    edited = write!(u, v, "edited.md", "old text")
    checkpointed = write!(u, v, "board.md", "board text")
    _ = write!(u, v, "plain.md", "plain text")
    _ = write!(u, v, "moved.md", "moved text")
    {:ok, _} = Notes.rename_note(u, v, "moved.md", "Dir/moved.md")
    pre_split!(u)
    # The upgrade's migrations, before boot.
    Engram.Fixtures.complete_split!()

    expected = %{
      "edited.md" => "old text",
      "board.md" => "board text",
      "plain.md" => "plain text",
      "Dir/moved.md" => "moved text"
    }

    for {path, text} <- expected, do: assert(read!(u, v, path) == text)

    # Release-B writes before the ledgers run: an edit and a checkpoint.
    write!(u, v, "edited.md", "new text")
    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, checkpointed.id, doc_with("checkpointed"))
    expected = %{expected | "edited.md" => "new text"}
    assert read!(u, v, "board.md") =~ "checkpointed"
    assert read!(u, v, "edited.md") == "new text"
    _ = edited

    Enum.reduce_while(1..8, nil, fn _, _ ->
      run_all()
      if both_done?(), do: {:halt, :ok}, else: {:cont, nil}
    end)

    assert both_done?(), "NoteSplit and NoteBodyColumnsNull must both reach :done"
    assert copies(u) == [[0]]

    for {path, text} <- Map.delete(expected, "board.md"), do: assert(read!(u, v, path) == text)
    assert read!(u, v, "board.md") =~ "checkpointed"
  end

  test "a pre-split database booted on this release: every note has its body row, byte for byte, and reads before any data migration runs",
       %{user: u, vault: v} do
    checkpointed = write!(u, v, "board.md", "board text")
    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, checkpointed.id, doc_with("checkpointed"))
    _ = write!(u, v, "plain.md", "plain text")
    _ = write!(u, v, "moved.md", "moved text")
    {:ok, _} = Notes.rename_note(u, v, "moved.md", "Dir/moved.md")
    written = bodies(u)
    assert length(written) >= 3
    assert Enum.any?(written, fn row -> Enum.at(row, 4) != nil end), "one CRDT state"

    pre_split!(u)
    assert bodies(u) == []

    Engram.Fixtures.complete_split!()

    assert bodies(u) == written
    refute DataMigrations.done?(NoteSplit.name(), NoteSplit.version())
    assert read!(u, v, "plain.md") == "plain text"
    assert read!(u, v, "Dir/moved.md") == "moved text"
    assert read!(u, v, "board.md") =~ "checkpointed"

    # Rerun-safe: a second run (a retried boot) writes nothing.
    Engram.Fixtures.complete_split!()
    assert bodies(u) == written
  end

  # Under the RLS-enforced runtime role (`engram_app`, not the owner, no
  # bypass), as prod's non-superuser migrator sees the tables: the per-user
  # tenant context must see and insert every row. The suite's own role
  # bypasses RLS, so without this CI never runs the policy path.
  test "under the RLS-enforced role, the split inserts every body row", %{user: u, vault: v} do
    _ = write!(u, v, "rls.md", "rls text")
    written = bodies(u)
    pre_split!(u)

    Engram.Fixtures.complete_split!(role: "engram_app")

    assert bodies(u) == written
    assert read!(u, v, "rls.md") == "rls text"
  end

  # The one note the insert skips: its body row exists but is owned by
  # another user (drift; hand-edited SQL or a restore), so the tenant policy
  # hides it, ON CONFLICT keeps it, and every read (which joins on the
  # owner) gets a NULL body. Nothing else can heal it, so the migration
  # repairs it, and only then bypasses RLS.
  defp foreign_body!(note) do
    Repo.query!("UPDATE note_bodies SET user_id = $2 WHERE note_id = $1", [
      Ecto.UUID.dump!(note.id),
      Ecto.UUID.dump!(insert(:user).id)
    ])
  end

  test "a body row owned by another user, notes copy present: rebuilt from the copy",
       %{user: u, vault: v} do
    note = write!(u, v, "owned.md", "owned text")
    Engram.Fixtures.old_release_notes_copy!(note.id)

    # The foreign row's bytes are not the note's: only the notes copy reads.
    Repo.query!(
      "UPDATE note_bodies SET content_ct = $2 WHERE note_id = $1",
      [Ecto.UUID.dump!(note.id), <<1>> <> :crypto.strong_rand_bytes(60)]
    )

    foreign_body!(note)
    assert read!(u, v, "owned.md") == nil

    Engram.Fixtures.complete_split!()
    assert read!(u, v, "owned.md") == "owned text"
  end

  test "a body row owned by another user, no notes copy: handed back to the owner",
       %{user: u, vault: v} do
    import ExUnit.CaptureLog
    note = write!(u, v, "owned.md", "owned text")
    foreign_body!(note)
    assert read!(u, v, "owned.md") == nil

    log = capture_log([level: :warning], fn -> assert :ok = Engram.Fixtures.complete_split!() end)
    assert log =~ "may not decrypt"
    assert read!(u, v, "owned.md") == "owned text"
  end

  # Review HIGH-1: release B writes only the nonce on `notes`, so an edited
  # note keeps an OLD notes ciphertext under its NEW nonce, while the body
  # holds the new envelope. The repair must keep the body (its prefix
  # matches the notes nonce), not rebuild it from the stale copy.
  test "a body row owned by another user after a release-B edit keeps the newer body",
       %{user: u, vault: v} do
    note = write!(u, v, "edited.md", "first text")
    Engram.Fixtures.old_release_notes_copy!(note.id)
    write!(u, v, "edited.md", "second text")
    foreign_body!(note)
    assert read!(u, v, "edited.md") == nil

    Engram.Fixtures.complete_split!()
    assert read!(u, v, "edited.md") == "second text"
  end

  # Prod's migrator owns the tables but is no superuser, so FORCE RLS binds
  # it and the foreign body row is invisible: only the repair's NO FORCE
  # lets it reach the row. The suite's role bypasses RLS, so this runs the
  # split as a NOSUPERUSER NOBYPASSRLS role that owns `note_bodies` (DDL in
  # the sandbox, rolled back). Without the NO FORCE / FORCE pair the UPDATE
  # is filtered, not rejected (RLS trap 1), and the note still reads nil.
  test "the owner repair reaches the row as a non-superuser owner of note_bodies",
       %{user: u, vault: v} do
    note = write!(u, v, "owned.md", "owned text")
    foreign_body!(note)

    Repo.query!("CREATE ROLE r8c_migrator NOSUPERUSER NOBYPASSRLS NOINHERIT")

    Repo.query!(
      "GRANT SELECT, INSERT, UPDATE ON users, notes, note_bodies, note_index_state TO r8c_migrator"
    )

    Repo.query!("ALTER TABLE note_bodies OWNER TO r8c_migrator")

    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        assert :ok = Engram.Fixtures.complete_split!(role: "r8c_migrator")
      end)

    refute log =~ "still read with no body"
    assert read!(u, v, "owned.md") == "owned text"
  end
end
