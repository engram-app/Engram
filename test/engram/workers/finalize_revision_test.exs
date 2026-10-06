defmodule Engram.Workers.FinalizeRevisionTest.FailingStorage do
  @moduledoc false
  # A storage PUT that always fails, and tells the test it was attempted.
  def put(key, _binary, _opts) do
    send(self(), {:put_attempted, key})
    {:error, :unavailable}
  end
end

defmodule Engram.Workers.FinalizeRevisionTest.VanishingStorage do
  @moduledoc false
  # The real adapter, except that the revision row disappears during the PUT,
  # the way a note delete cascading mid-upload would remove it.
  import Ecto.Query

  def put(key, binary, opts) do
    id = Path.basename(key)
    Engram.Repo.delete_all(from(r in Engram.Notes.Revision, where: r.id == ^id))
    real().put(key, binary, opts)
  end

  def delete(key) do
    send(self(), {:deleted, key})
    real().delete(key)
  end

  def get(key), do: real().get(key)

  defp real, do: Process.get(:real_storage)
end

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

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "f.md", "content" => "keep me"}, actor: "api")

    {:ok, existing} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)

    {:ok, :ok} =
      Repo.with_tenant(user.id, fn -> Revisions.record_write(existing, "sync", true) end)

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

  test "job is unique per note while waiting" do
    note_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    {:ok, _} = Oban.insert(FinalizeRevision.job(note_id, user_id))
    {:ok, _} = Oban.insert(FinalizeRevision.job(note_id, user_id))

    assert length(all_enqueued(worker: FinalizeRevision, args: %{note_id: note_id})) == 1
  end

  describe "a version that can never decrypt" do
    # A second pending copy behind the baseline: an MCP write closes the open
    # sync version, copying the note's text ("keep me") into it.
    setup %{user: u, vault: v, note: n, baseline: b} do
      {:ok, _} =
        Notes.upsert_note(u, v, %{"path" => "f.md", "content" => "ai text"}, actor: "mcp")

      {:ok, later} =
        Repo.with_tenant(u.id, fn ->
          Repo.one!(
            from(r in Revision,
              where: r.note_id == ^n.id and r.id != ^b.id and not is_nil(r.pending_ciphertext)
            )
          )
        end)

      %{later: later}
    end

    defp corrupt(user, rev) do
      <<first, rest::binary>> = rev.pending_ciphertext

      {:ok, {1, _}} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(r in Revision, where: r.id == ^rev.id),
            set: [pending_ciphertext: <<Bitwise.bxor(first, 0xFF), rest::binary>>]
          )
        end)
    end

    test "is parked and does not block later versions of the note",
         %{user: u, note: n, baseline: b, later: later} do
      corrupt(u, b)

      assert :ok = perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})

      parked = reload(u, b.id)
      assert parked.finalize_failed_at
      assert parked.pending_ciphertext
      assert parked.storage_key == nil

      done = reload(u, later.id)
      assert done.pending_ciphertext == nil
      assert {:ok, "keep me"} = blob_text(u, done, done.id)
    end

    test "a parked version is not retried", %{user: u, note: n, baseline: b} do
      corrupt(u, b)
      :ok = perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})
      parked = reload(u, b.id)

      assert :ok = perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})
      assert reload(u, b.id).finalize_failed_at == parked.finalize_failed_at
    end
  end

  test "a storage failure tries every version, then errors so Oban retries",
       %{user: u, vault: v, note: n, baseline: b} do
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "f.md", "content" => "ai text"}, actor: "mcp")
    previous = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, __MODULE__.FailingStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, previous) end)

    assert {:error, :unavailable} =
             perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})

    assert_received {:put_attempted, _}
    assert_received {:put_attempted, _}
    rev = reload(u, b.id)
    assert rev.pending_ciphertext
    assert rev.finalize_failed_at == nil
  end

  test "a revision gone by the time the upload lands leaves no blob behind",
       %{user: u, note: n, baseline: b} do
    previous = Application.get_env(:engram, :storage)
    Process.put(:real_storage, Storage.adapter())
    Application.put_env(:engram, :storage, __MODULE__.VanishingStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, previous) end)

    assert :ok = perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})

    key = Storage.revision_key(u.id, b.vault_id, n.id, b.id)
    assert_received {:deleted, ^key}
    assert {:error, :not_found} = Process.get(:real_storage).get(key)
  end

  test "a user with no DEK parks the copy instead of retrying forever",
       %{user: u, note: n, baseline: b} do
    Repo.update_all(from(x in Engram.Accounts.User, where: x.id == ^u.id),
      set: [encrypted_dek: nil]
    )

    assert :ok = perform_job(FinalizeRevision, %{note_id: n.id, user_id: u.id})

    parked = reload(u, b.id)
    assert parked.finalize_failed_at
    assert parked.pending_ciphertext
  end
end
