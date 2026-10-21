defmodule Engram.RebuildExclusionTest do
  @moduledoc """
  Task 16.4: while the v5 rebuild is `on`, other bulk writers wait, and
  `on` itself needs the v5 write layout.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import ExUnit.CaptureLog

  alias Engram.Rebuild
  alias Engram.ServiceConfig
  alias Engram.Workers.{IndexCapMaintenance, RebuildDryRun, RepathNoteIndex, RotateUserDek}

  setup do
    Engram.Cache.clear_local(:rebuild)
    Repo.query!("DELETE FROM rebuild_ledger")
    Rebuild.set_budget(1_000_000)
    :persistent_term.erase({Rebuild, :v5_layout_off_warned})
    :ok
  end

  defp on!(v5? \\ true) do
    ServiceConfig.put_override(:write_v5_layout, v5?)
    ServiceConfig.put_override(:index_rebuild, "on")
  end

  describe "the v5 layout guard" do
    test "on with the v5 layout reads :on" do
      on!()
      assert Rebuild.mode() == :on
    end

    test "on without the v5 layout reads :off and warns once" do
      on!(false)

      log =
        capture_log(fn ->
          assert Rebuild.mode() == :off
          assert Rebuild.mode() == :off
        end)

      assert [_one] = Regex.scan(~r/rebuild_v5_layout_off/, log)
    end

    test "v5_payload_format alone is not enough" do
      ServiceConfig.put_override(:v5_payload_format, true)
      on!(false)
      assert Rebuild.mode() == :off
    end

    test "a dry run seals only with the v5 layout" do
      ServiceConfig.put_override(:index_rebuild, "dry_run")
      ServiceConfig.put_override(:write_v5_layout, false)
      assert Rebuild.mode() == :dry_run
      assert Rebuild.seal() == {:error, :v5_layout_off}

      ServiceConfig.put_override(:write_v5_layout, true)
      assert {:ok, _budget} = Rebuild.seal()
    end

    test "the dry-run coordinator completes without sealing when the layout is off" do
      ServiceConfig.put_override(:index_rebuild, "dry_run")
      ServiceConfig.put_override(:write_v5_layout, false)
      Repo.query!("DELETE FROM rebuild_ledger")
      assert :ok = perform_job(RebuildDryRun, %{})
      assert Rebuild.ledger() == nil
    end
  end

  describe "other writers while on" do
    test "a DEK rotation snoozes an hour and writes nothing" do
      on!()
      user = insert(:user)
      before = Repo.reload!(user)

      assert {:snooze, 3600} = perform_job(RotateUserDek, %{user_id: user.id})
      assert Repo.reload!(user).dek_version == before.dek_version
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

    test "a single-note repath still runs; a bulk one snoozes" do
      on!()

      args = %{
        note_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        old_path_hmac: "aA=="
      }

      refute match?({:snooze, _}, perform_job(RepathNoteIndex, args))
      assert {:snooze, 3600} = perform_job(RepathNoteIndex, Map.put(args, :bulk, true))
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
