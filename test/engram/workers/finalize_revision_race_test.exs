defmodule Engram.Workers.FinalizeRevisionRaceTest do
  @moduledoc """
  Two finalizes for one version (Oban.insert_all from the batch path or the
  sweep bypasses `unique`). Without the advisory lock each PUTs under the same
  key with its own nonce and only one nonce reaches the row, leaving the blob
  undecryptable. Real connections via Engram.CheckpointInterleave so the two
  runs genuinely overlap.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Engram.Factory

  alias Engram.{CheckpointInterleave, Crypto, Notes, Repo, Storage}
  alias Engram.Crypto.Envelope
  alias Engram.Notes.{Note, Revision, Revisions}
  alias Engram.Workers.FinalizeRevision

  setup do
    CheckpointInterleave.checkout_real!()
    # The in-memory adapter's ETS table is owned by whichever process first
    # touches it; created lazily inside a Task it would die with that Task.
    :ok = Engram.Storage.InMemory.ensure_table()
    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user =
      insert(:user,
        id: user_id,
        email: "finalize-race-#{System.unique_integer([:positive])}@test.com"
      )

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Race", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "two concurrent finalizes leave a blob that decrypts", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "race me"})
    {:ok, existing} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)

    {:ok, :ok} =
      Repo.with_tenant(user.id, fn -> Revisions.record_write(existing, user, "sync") end)

    rev_id =
      Repo.one!(
        from(r in Revision, where: r.note_id == ^note.id and r.origin == "baseline", select: r.id),
        skip_tenant_check: true
      )

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          CheckpointInterleave.checkout_real!()
          FinalizeRevision.finalize_one(rev_id, user)
        end)
      end

    assert [:ok, :ok] = Enum.map(tasks, &Task.await(&1, 15_000))

    rev = Repo.one!(from(r in Revision, where: r.id == ^rev_id), skip_tenant_check: true)
    {:ok, blob} = Storage.adapter().get(rev.storage_key)
    {:ok, dek} = Crypto.get_dek(user)

    assert {:ok, gz} =
             Envelope.decrypt(
               blob,
               rev.blob_nonce,
               dek,
               Crypto.aad_for_row(:note_revisions, :content, rev.id)
             )

    assert :zlib.gunzip(gz) == "race me"
  end
end
