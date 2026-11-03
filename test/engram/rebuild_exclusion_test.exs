defmodule Engram.RebuildExclusionTest do
  @moduledoc """
  Task 16.4: while the v5 rebuild is `on`, other bulk writers wait.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Rebuild
  alias Engram.ServiceConfig

  alias Engram.Workers.{
    IndexCapMaintenance,
    RebuildDryRun,
    ReleaseRebuildHeld,
    RepathNoteIndex,
    RotateUserDek
  }

  setup do
    Engram.Cache.clear_local(:rebuild)
    Repo.query!("DELETE FROM rebuild_ledger")
    Rebuild.set_budget(1_000_000)
    :ok
  end

  defp on!, do: ServiceConfig.put_override(:index_rebuild, "on")

  # Every point is written in the v5 layout now, so `on` and the seal need
  # nothing but the switch (and, for `on`, a budget).
  describe "the switch alone" do
    test "on reads :on" do
      on!()
      assert Rebuild.mode() == :on
    end

    test "a dry run seals" do
      ServiceConfig.put_override(:index_rebuild, "dry_run")
      assert Rebuild.mode() == :dry_run
      assert {:ok, _budget} = Rebuild.seal()
    end

    test "the dry-run coordinator seals a budget" do
      ServiceConfig.put_override(:index_rebuild, "dry_run")
      Repo.query!("DELETE FROM rebuild_ledger")
      assert :ok = perform_job(RebuildDryRun, %{})
      assert Rebuild.ledger() != nil
    end
  end

  describe "other writers while on" do
    # Held, not snoozed: a snooze rewrites the job row every time it wakes
    # (#2375). A suspended job is never staged or fetched, so it writes nothing.
    test "a DEK rotation is held and writes nothing" do
      on!()
      user = insert(:user)
      before = Repo.reload!(user)

      assert :ok = perform_job(RotateUserDek, %{user_id: user.id})
      assert Repo.reload!(user).dek_version == before.dek_version
      assert [%{state: "suspended"}] = all_enqueued(worker: RotateUserDek)
    end

    test "a DEK rotation runs when the pass is off" do
      ServiceConfig.put_override(:index_rebuild, "off")

      assert {:discard, :user_deleted} =
               perform_job(RotateUserDek, %{user_id: Ecto.UUID.generate()})
    end

    test "the recap cron is a no-op" do
      on!()
      assert :ok = perform_job(IndexCapMaintenance, %{})
    end

    test "a single-note repath still runs; a bulk one is held until the pass is off" do
      on!()

      args = %{
        note_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        old_path_hmac: "aA=="
      }

      refute match?({:snooze, _}, perform_job(RepathNoteIndex, args))
      assert :ok = perform_job(RepathNoteIndex, Map.put(args, :bulk, true))
      assert [%{state: "suspended"} = held] = all_enqueued(worker: RepathNoteIndex)
      assert held.args["bulk"] == true

      # Still on: the release sweep leaves it held.
      assert :ok = perform_job(ReleaseRebuildHeld, %{})
      assert [%{state: "suspended"}] = all_enqueued(worker: RepathNoteIndex)

      ServiceConfig.put_override(:index_rebuild, "off")
      assert :ok = perform_job(ReleaseRebuildHeld, %{})
      assert [%{state: "available"}] = all_enqueued(worker: RepathNoteIndex)
    end

    test "a bulk repath runs when the pass is off" do
      ServiceConfig.put_override(:index_rebuild, "off")

      args = %{
        note_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        old_path_hmac: "aA=="
      }

      refute match?({:snooze, _}, perform_job(RepathNoteIndex, Map.put(args, :bulk, true)))
    end

    test "only folder renames over the threshold queue bulk repaths" do
      id = Ecto.UUID.generate()
      uid = Ecto.UUID.generate()

      refute Map.has_key?(
               RepathNoteIndex.new_debounced(id, uid, old_path_hmac: "x").changes.args,
               :bulk
             )

      assert RepathNoteIndex.new_debounced(id, uid, old_path_hmac: "x", bulk: true).changes.args.bulk
      assert RepathNoteIndex.bulk_threshold() == 100
    end
  end
end
