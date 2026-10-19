defmodule Engram.Workers.ExtractNoteLinksTxnCountTest do
  # Budget: tenant transactions per ExtractNoteLinks job (3 round trips each).
  # The note + vault reads share one; the candidate prefetch, the stored-edge
  # compare, the write and the dangler list share the other. Was 5.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.Links
  alias Engram.Links.NoteLink
  alias Engram.Notes
  alias Engram.Repo
  alias Engram.TenantQueryCounter
  alias Engram.Workers.ExtractNoteLinks

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "see [[Later]]"},
        actor: "api"
      )

    %{user: user, vault: vault, note: note}
  end

  test "a job opens at most 2 tenant transactions", %{user: user, note: note} do
    enters =
      TenantQueryCounter.count_tenant_enters(fn ->
        assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id, user_id: user.id})
      end)

    assert length(enters) <= 2,
           "ExtractNoteLinks opened #{length(enters)} tenant transactions, budget is 2"

    assert [%{target_text: "Later", dangling: true}] = Links.links_for_note(user, note.id)
  end

  test "unchanged links are left in place, not deleted and re-inserted",
       %{user: user, note: note} do
    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id, user_id: user.id})
    before = link_ids(note)

    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id, user_id: user.id})
    assert link_ids(note) == before
  end

  # Rows store the target's name, not what it resolves to, so a target
  # appearing changes no row: the read resolves it.
  test "a changed resolution rewrites nothing", %{user: user, vault: vault, note: note} do
    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id, user_id: user.id})
    before = link_ids(note)

    {:ok, target} =
      Notes.upsert_note(user, vault, %{"path" => "Later.md", "content" => "# l"}, actor: "api")

    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id, user_id: user.id})
    assert link_ids(note) == before
    assert [%{target_note_id: tid, dangling: false}] = Links.links_for_note(user, note.id)
    assert tid == target.id
  end

  test "a changed alias is still rewritten", %{user: user, vault: vault, note: note} do
    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id, user_id: user.id})

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "see [[Later|soon]]"},
        actor: "api"
      )

    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id, user_id: user.id})
    assert [%{alias: "soon"}] = Links.links_for_note(user, note.id)
  end

  defp link_ids(note) do
    Repo.all(from(l in NoteLink, where: l.source_note_id == ^note.id, select: l.id),
      skip_tenant_check: true
    )
    |> Enum.sort()
  end
end
