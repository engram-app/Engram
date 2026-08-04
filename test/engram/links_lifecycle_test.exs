defmodule Engram.LinksLifecycleTest do
  @moduledoc """
  End-to-end lifecycle hooks (issue #591 task 6): create/rename/resurrect
  (re)bind matching dangling links, delete flips edges. Drives through the
  public API (`Notes.upsert_note/4`, `Notes.rename_note/4`,
  `Notes.delete_note/4`) and drains real Oban jobs (`testing: :manual`,
  see config/test.exs) rather than calling `Links` directly.
  """

  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Links
  alias Engram.Notes
  alias Engram.Workers.EmbedNote

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    %{user: user, vault: vault, bypass: bypass}
  end

  defp stub_qdrant(bypass) do
    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)
  end

  # Runs the note through the real index pipeline (parse -> embed -> Links)
  # exactly like EmbedNoteTest — the debounced job upsert_note enqueued isn't
  # scheduled to run yet, so we perform it directly.
  defp index!(bypass, note_id) do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
    end)

    stub_qdrant(bypass)
    assert :ok = perform_job(EmbedNote, %{note_id: note_id})
  end

  defp drain_indexing! do
    Oban.drain_queue(queue: :indexing)
  end

  defp only_link(user, note_id) do
    assert [link] = Links.links_for_note(user, note_id)
    link
  end

  test "creating the target binds existing danglers", %{user: user, vault: vault, bypass: bypass} do
    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => "Source1.md", "content" => "See [[Later]]."})

    index!(bypass, source.id)

    assert only_link(user, source.id).dangling

    {:ok, target} =
      Notes.upsert_note(user, vault, %{"path" => "x/Later.md", "content" => "# Later"})

    drain_indexing!()

    link = only_link(user, source.id)
    refute link.dangling
    assert link.target_note_id == target.id
  end

  test "renaming a note re-resolves danglers to its new name", %{
    user: user,
    vault: vault,
    bypass: bypass
  } do
    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => "Source2.md", "content" => "See [[Fresh]]."})

    index!(bypass, source.id)
    assert only_link(user, source.id).dangling

    {:ok, old_note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# Old"})
    drain_indexing!()
    assert only_link(user, source.id).dangling

    {:ok, _renamed} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")
    drain_indexing!()

    link = only_link(user, source.id)
    refute link.dangling
    assert link.target_note_id == old_note.id
  end

  test "renaming AWAY re-resolves edges that pointed at the old name", %{
    user: user,
    vault: vault,
    bypass: bypass
  } do
    {:ok, a_short} = Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "# A short"})
    {:ok, a_long} = Notes.upsert_note(user, vault, %{"path" => "b/A.md", "content" => "# A long"})

    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => "Source3.md", "content" => "See [[A]]."})

    index!(bypass, source.id)
    assert only_link(user, source.id).target_note_id == a_short.id

    {:ok, _renamed} = Notes.rename_note(user, vault, "A.md", "Z.md")
    drain_indexing!()

    link = only_link(user, source.id)
    assert link.target_note_id == a_long.id
  end

  test "delete flips incoming edges to dangling and drops outgoing", %{
    user: user,
    vault: vault,
    bypass: bypass
  } do
    {:ok, target} =
      Notes.upsert_note(user, vault, %{
        "path" => "Target4.md",
        "content" => "See [[Nowhere]]."
      })

    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => "Source4.md", "content" => "See [[Target4]]."})

    index!(bypass, target.id)
    index!(bypass, source.id)

    assert only_link(user, target.id).dangling
    assert only_link(user, source.id).target_note_id == target.id

    :ok = Notes.delete_note(user, vault, "Target4.md")
    drain_indexing!()

    link = only_link(user, source.id)
    assert link.dangling
    assert is_nil(link.target_note_id)

    assert Links.links_for_note(user, target.id) == []
  end

  # --- CRDT genesis path (Notes.genesis_crdt_note/4) — the primary
  # web/plugin create+rename path; REST upsert_note/rename_note only serves
  # the public API + MCP now. Fix report addendum (task-6 review). ---

  test "CRDT genesis create binds existing danglers", %{user: user, vault: vault, bypass: bypass} do
    {:ok, source} =
      Notes.upsert_note(user, vault, %{
        "path" => "CrdtSource1.md",
        "content" => "See [[CrdtLater]]."
      })

    index!(bypass, source.id)
    assert only_link(user, source.id).dangling

    id = Ecto.UUID.generate()
    assert {:ok, target} = Notes.genesis_crdt_note(user, vault, id, "x/CrdtLater.md")
    drain_indexing!()

    link = only_link(user, source.id)
    refute link.dangling
    assert link.target_note_id == target.id
  end

  test "CRDT relocate (rename-as-move, same id) re-resolves edges that pointed at the old name",
       %{user: user, vault: vault, bypass: bypass} do
    {:ok, a_short} =
      Notes.upsert_note(user, vault, %{"path" => "CrdtA.md", "content" => "# A short"})

    {:ok, a_long} =
      Notes.upsert_note(user, vault, %{"path" => "b/CrdtA.md", "content" => "# A long"})

    # Drain the two create-branch rebinds now — otherwise they'd sit queued
    # and get swept up by the LATER drain_indexing! below, masking whether
    # genesis_relocate_live's own rebind hook actually fires.
    drain_indexing!()

    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => "CrdtSource3.md", "content" => "See [[CrdtA]]."})

    index!(bypass, source.id)
    assert only_link(user, source.id).target_note_id == a_short.id

    # Same id, different FREE path — genesis_crdt_note's Phase E2 relocate leg
    # (genesis_relocate_live), not a REST rename_note call.
    assert {:ok, _moved} = Notes.genesis_crdt_note(user, vault, a_short.id, "CrdtZ.md")
    drain_indexing!()

    link = only_link(user, source.id)
    assert link.target_note_id == a_long.id
  end

  test "batch delete un-shadows a same-basename sibling", %{
    user: user,
    vault: vault,
    bypass: bypass
  } do
    {:ok, short} = Notes.upsert_note(user, vault, %{"path" => "Dup.md", "content" => "# short"})
    {:ok, long} = Notes.upsert_note(user, vault, %{"path" => "b/Dup.md", "content" => "# long"})

    # Drain the two create-branch rebinds now — otherwise they'd sit queued
    # and get swept up by the LATER drain_indexing! below, masking whether
    # batch_delete_notes' own rebind actually fires.
    drain_indexing!()

    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => "Source5.md", "content" => "See [[Dup]]."})

    index!(bypass, source.id)
    assert only_link(user, source.id).target_note_id == short.id

    assert {:ok, %{deleted: 1}} = Notes.batch_delete_notes(user, vault, [short.id])
    drain_indexing!()

    link = only_link(user, source.id)
    assert link.target_note_id == long.id
  end
end
