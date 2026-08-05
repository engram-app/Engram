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

  alias Engram.Attachments
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

  test "renaming AWAY (REST) rewrites the link to follow its target instead of falling back to basename rebind",
       %{
         user: user,
         vault: vault,
         bypass: bypass
       } do
    {:ok, a_short} = Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "# A short"})

    {:ok, _a_long} =
      Notes.upsert_note(user, vault, %{"path" => "b/A.md", "content" => "# A long"})

    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => "Source3.md", "content" => "See [[A]]."})

    index!(bypass, source.id)
    assert only_link(user, source.id).target_note_id == a_short.id

    {:ok, _renamed} = Notes.rename_note(user, vault, "A.md", "Z.md")
    drain_indexing!()

    # Task 6: REST-origin renames route through RewriteNoteLinks, which
    # mechanically rewrites "[[A]]" -> "[[Z]]" so the link keeps pointing at
    # the SAME row it did pre-rename (a_short, now Z.md) — the
    # exactly-one-rewriter, semantics-preserving policy in
    # Engram.Links.Rewriter. It no longer falls through to basename-fallback
    # rebinding onto the sibling a_long; that fallback-only behavior (the
    # pre-rewriter semantics this test used to assert) is covered for the
    # untouched CRDT/plugin origin by "CRDT relocate ..." below.
    link = only_link(user, source.id)
    refute link.dangling
    assert link.target_note_id == a_short.id
    assert link.target_text == "Z"
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

  # --- Attachment lifecycle hooks (task 6 addendum) — attachments.ex had no
  # edge hooks at all: an embed dangling on an attachment that gets uploaded
  # later, an attachment rename, or an attachment delete never touched
  # note_links. Mirrors the note hooks above. ---

  defp upload!(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("fake bytes for " <> path)
      })

    att
  end

  test "embedding an attachment before it exists binds once it's uploaded", %{
    user: user,
    vault: vault,
    bypass: bypass
  } do
    {:ok, source} =
      Notes.upsert_note(user, vault, %{
        "path" => "Source6.md",
        "content" => "![[photo.png]]"
      })

    index!(bypass, source.id)
    assert only_link(user, source.id).dangling

    att = upload!(user, vault, "photo.png")
    drain_indexing!()

    link = only_link(user, source.id)
    refute link.dangling
    assert link.target_attachment_id == att.id
  end

  test "moving an attachment (REST) rewrites the link to follow it instead of dangling", %{
    user: user,
    vault: vault,
    bypass: bypass
  } do
    att = upload!(user, vault, "Movable.png")

    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => "Source7.md", "content" => "![[Movable.png]]"})

    index!(bypass, source.id)
    refute only_link(user, source.id).dangling

    {:ok, _} = Attachments.move_attachment(user, vault, "Movable.png", "moved/Renamed.png")
    drain_indexing!()

    # Task 6: Attachments.move_attachment/4 also routes through
    # RewriteNoteLinks, so "![[Movable.png]]" is mechanically rewritten to
    # "![[Renamed.png]]" (id-stable move) — the link keeps pointing at the
    # SAME attachment instead of dangling. Pre-rewriter this asserted the
    # opposite (dangling); that fallback-only behavior belongs to the
    # untouched CRDT/plugin origin (see the CRDT-prefixed tests above).
    link = only_link(user, source.id)
    refute link.dangling
    assert link.target_attachment_id == att.id
    assert link.target_text == "Renamed.png"
  end

  test "an attachment rename binds a dangler waiting on its new name", %{
    user: user,
    vault: vault,
    bypass: bypass
  } do
    _att = upload!(user, vault, "Stays.png")

    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => "Source9.md", "content" => "![[Fresh.png]]"})

    index!(bypass, source.id)
    assert only_link(user, source.id).dangling

    {:ok, moved} = Attachments.move_attachment(user, vault, "Stays.png", "Fresh.png")
    drain_indexing!()

    link = only_link(user, source.id)
    refute link.dangling
    assert link.target_attachment_id == moved.id
  end

  test "deleting an attachment flips the incoming edge to dangling", %{
    user: user,
    vault: vault,
    bypass: bypass
  } do
    att = upload!(user, vault, "Gone.png")

    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => "Source8.md", "content" => "![[Gone.png]]"})

    index!(bypass, source.id)
    link = only_link(user, source.id)
    refute link.dangling
    assert link.target_attachment_id == att.id

    :ok = Attachments.delete_attachment(user, vault, "Gone.png")

    link = only_link(user, source.id)
    assert link.dangling
    assert is_nil(link.target_attachment_id)
  end

  test "batch-deleting an attachment flips the incoming edge to dangling", %{
    user: user,
    vault: vault,
    bypass: bypass
  } do
    att = upload!(user, vault, "GoneBatch.png")

    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => "Source10.md", "content" => "![[GoneBatch.png]]"})

    index!(bypass, source.id)
    link = only_link(user, source.id)
    refute link.dangling
    assert link.target_attachment_id == att.id

    assert {:ok, %{deleted: 1}} = Attachments.batch_delete(user, vault, ["GoneBatch.png"])

    link = only_link(user, source.id)
    assert link.dangling
    assert is_nil(link.target_attachment_id)
  end

  # Pins the batched edge-flip added for the batch_delete N+1 fix (finding
  # #2 on PR #1229): two attachments soft-deleted in ONE batch_delete/3 call
  # must each flip their own incoming edge, proving
  # Links.on_attachments_soft_deleted/2 (plural, one UPDATE) covers every id
  # in the batch rather than only the first/last.
  test "batch-deleting two attachments flips both incoming edges", %{
    user: user,
    vault: vault,
    bypass: bypass
  } do
    att_a = upload!(user, vault, "BatchA.png")
    att_b = upload!(user, vault, "BatchB.png")

    {:ok, source_a} =
      Notes.upsert_note(user, vault, %{"path" => "SourceA.md", "content" => "![[BatchA.png]]"})

    {:ok, source_b} =
      Notes.upsert_note(user, vault, %{"path" => "SourceB.md", "content" => "![[BatchB.png]]"})

    index!(bypass, source_a.id)
    index!(bypass, source_b.id)

    link_a = only_link(user, source_a.id)
    link_b = only_link(user, source_b.id)
    assert link_a.target_attachment_id == att_a.id
    assert link_b.target_attachment_id == att_b.id

    assert {:ok, %{deleted: 2}} =
             Attachments.batch_delete(user, vault, ["BatchA.png", "BatchB.png"])

    link_a = only_link(user, source_a.id)
    link_b = only_link(user, source_b.id)
    assert link_a.dangling
    assert is_nil(link_a.target_attachment_id)
    assert link_b.dangling
    assert is_nil(link_b.target_attachment_id)
  end
end
