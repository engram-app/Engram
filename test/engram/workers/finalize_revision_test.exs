defmodule Engram.Workers.FinalizeRevisionTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Storage, Vaults}
  alias Engram.Crypto.Envelope
  alias Engram.Notes.{Note, Revision, Revisions}
  alias Engram.Workers.FinalizeRevision

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Finalize", Ecto.UUID.generate())

    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "f.md", "content" => "keep me"})
    {:ok, existing} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)

    {:ok, :ok} =
      Repo.with_tenant(user.id, fn -> Revisions.record_write(existing, user, "sync") end)

    {:ok, baseline} =
      Repo.with_tenant(user.id, fn ->
        Repo.one!(from(r in Revision, where: r.note_id == ^note.id and r.origin == "baseline"))
      end)

    %{user: user, vault: vault, note: note, baseline: baseline}
  end

  defp reload(user, id), do: elem(Repo.with_tenant(user.id, fn -> Repo.get!(Revision, id) end), 1)

  defp blob_text(user, rev, aad_id) do
    {:ok, blob} = Storage.adapter().get(rev.storage_key)
    {:ok, dek} = Crypto.get_dek(user)

    case Envelope.decrypt(
           blob,
           rev.blob_nonce,
           dek,
           Crypto.aad_for_row(:note_revisions, :content, aad_id)
         ) do
      {:ok, gz} -> {:ok, :zlib.gunzip(gz)}
      :error -> :error
    end
  end

  test "moves the copy into storage and clears it", %{user: u, note: n, baseline: b} do
    assert :ok = perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})

    rev = reload(u, b.id)
    assert rev.pending_ciphertext == nil
    assert rev.storage_key == Storage.revision_key(u.id, rev.vault_id, n.id, rev.id)
    assert {:ok, "keep me"} = blob_text(u, rev, rev.id)
    assert rev.char_count == String.length("keep me")
  end

  test "a second run changes nothing", %{user: u, note: n, baseline: b} do
    :ok = perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})
    first = reload(u, b.id)
    {:ok, blob_before} = Storage.adapter().get(first.storage_key)

    assert :ok = perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})

    assert reload(u, b.id) == first
    assert {:ok, ^blob_before} = Storage.adapter().get(first.storage_key)
  end

  test "the blob is bound to its own revision id", %{user: u, note: n, baseline: b} do
    :ok = perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})

    assert :error = blob_text(u, reload(u, b.id), Ecto.UUID.generate())
  end

  test "a deleted account is a no-op" do
    assert :ok =
             perform_job(FinalizeRevision, %{
               note_id: Ecto.UUID.generate(),
               user_id: Ecto.UUID.generate()
             })
  end

  test "new_for_note is unique per note while waiting" do
    note_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    {:ok, _} = Oban.insert(FinalizeRevision.new_for_note(note_id, user_id))
    {:ok, _} = Oban.insert(FinalizeRevision.new_for_note(note_id, user_id))

    assert length(all_enqueued(worker: FinalizeRevision, args: %{note_id: note_id})) == 1
  end
end
