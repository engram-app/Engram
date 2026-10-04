defmodule Engram.NotesResurrectReindexTest do
  @moduledoc """
  #1610, the symptom end to end: an embedded note is deleted, then resurrected
  by an id-keyed rename. The resurrected note must be picked up for
  re-embedding. Before the fix it kept `embed_hash == content_hash`, so
  `ReconcileEmbeddings` skipped it and it stayed unsearchable forever.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.{EmbedNote, ReconcileEmbeddings}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  # A note the embed pipeline has finished with: embed_hash stamped to the
  # current content_hash, and no jobs left in the queue.
  defp embedded_note(user, vault, path) do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => path, "content" => "# body"})

    from(n in Note, where: n.id == ^note.id, update: [set: [embed_hash: n.content_hash]])
    |> Repo.update_all([], skip_tenant_check: true)

    Repo.delete_all(Oban.Job)
    note
  end

  test "REST id-keyed rename (delete, then push the same id elsewhere)", %{
    user: user,
    vault: vault
  } do
    note = embedded_note(user, vault, "Old.md")
    :ok = Notes.delete_note(user, vault, "Old.md")

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"id" => note.id, "path" => "New.md", "content" => "# body"})

    assert :ok = perform_job(ReconcileEmbeddings, %{})
    assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
  end

  test "crdt_create resurrect-rename", %{user: user, vault: vault} do
    note = embedded_note(user, vault, "Old.md")
    :ok = Notes.delete_note(user, vault, "Old.md")

    {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "New.md")

    assert :ok = perform_job(ReconcileEmbeddings, %{})
    assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
  end
end
