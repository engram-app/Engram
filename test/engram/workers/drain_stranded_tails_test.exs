defmodule Engram.Workers.DrainStrandedTailsTest do
  # A CRDT tail row is folded into the snapshot only by its note's next
  # checkpoint. A room that died without unbind (OOM, node loss) and a note
  # never opened again kept its rows forever. The sweep enqueues a
  # CheckpointNote for every live note whose tail has a row older than the
  # window and that has no live room.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Notes
  alias Engram.Notes.{CrdtRegistry, CrdtUpdateLog}
  alias Engram.Workers.{CheckpointNote, DrainStrandedTails}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp note!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "x"}, actor: "api")

    note
  end

  defp tail!(user, note, age_minutes) do
    at = DateTime.add(DateTime.utc_now(), -age_minutes * 60, :second)

    Repo.insert!(
      %CrdtUpdateLog{
        note_id: note.id,
        user_id: user.id,
        vault_id: note.vault_id,
        update_ciphertext: "c",
        update_nonce: "n",
        inserted_at: at
      },
      skip_tenant_check: true
    )
  end

  test "enqueues a checkpoint for each stale, roomless tail, once", %{user: u, vault: v} do
    stale = note!(u, v, "stale.md")
    tail!(u, stale, 120)
    tail!(u, stale, 90)

    fresh = note!(u, v, "fresh.md")
    tail!(u, fresh, 1)

    deleted = note!(u, v, "deleted.md")
    tail!(u, deleted, 120)
    :ok = Notes.delete_note(u, v, "deleted.md")

    roomed = note!(u, v, "roomed.md")
    tail!(u, roomed, 120)
    {:ok, _room} = CrdtRegistry.ensure_started(u.id, v.id, roomed.id)
    on_exit(fn -> CrdtRegistry.terminate_room(roomed.id) end)

    assert :ok = perform_job(DrainStrandedTails, %{})

    assert [job] = all_enqueued(worker: CheckpointNote)
    assert job.args == %{"user_id" => u.id, "vault_id" => v.id, "note_id" => stale.id}

    # A second tick while the job waits adds none (CheckpointNote is unique).
    assert :ok = perform_job(DrainStrandedTails, %{})
    assert [_] = all_enqueued(worker: CheckpointNote)
  end
end
