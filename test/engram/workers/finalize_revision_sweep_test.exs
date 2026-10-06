defmodule Engram.Workers.FinalizeRevisionSweepTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{Note, Revision, Revisions}
  alias Engram.Workers.{FinalizeRevision, FinalizeRevisionSweep}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Sweep", Ecto.UUID.generate())
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "s.md", "content" => "stranded"})
    {:ok, existing} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)

    {:ok, :ok} =
      Repo.with_tenant(user.id, fn -> Revisions.record_write(existing, "sync", true) end)

    # The write's own after_commit already enqueued a job; drop it so the tests
    # observe only what the sweep enqueues (a lost job is what the sweep is for).
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.FinalizeRevision"))
    %{user: user, note: note}
  end

  defp age_pending(user, note_id, seconds) do
    then = DateTime.add(DateTime.utc_now(), -seconds, :second)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(r in Revision, where: r.note_id == ^note_id and not is_nil(r.pending_ciphertext)),
          set: [updated_at: then]
        )
      end)
  end

  test "re-enqueues a copy stranded for over ten minutes", %{user: u, note: n} do
    age_pending(u, n.id, 3600)
    assert :ok = perform_job(FinalizeRevisionSweep, %{})
    assert_enqueued(worker: FinalizeRevision, args: %{note_id: n.id})
  end

  test "leaves a fresh copy to its own job", %{note: n} do
    assert :ok = perform_job(FinalizeRevisionSweep, %{})
    refute_enqueued(worker: FinalizeRevision, args: %{note_id: n.id})
  end

  test "skips a copy parked as undecryptable", %{user: u, note: n} do
    age_pending(u, n.id, 3600)

    {:ok, _} =
      Repo.with_tenant(u.id, fn ->
        Repo.update_all(from(r in Revision, where: r.note_id == ^n.id),
          set: [finalize_failed_at: DateTime.utc_now()]
        )
      end)

    assert :ok = perform_job(FinalizeRevisionSweep, %{})
    refute_enqueued(worker: FinalizeRevision, args: %{note_id: n.id})
  end
end
