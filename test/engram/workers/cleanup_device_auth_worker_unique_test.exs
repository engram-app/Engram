defmodule Engram.Workers.CleanupDeviceAuthWorkerUniqueTest do
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Workers.CleanupDeviceAuthWorker

  require Logger

  # A slow run must not stack the next tick behind it, and a failing DELETE
  # is not worth Oban's default 20 attempts: the next tick retries it.
  test "a pending run absorbs the next tick" do
    for _ <- 1..3, do: {:ok, _} = Oban.insert(CleanupDeviceAuthWorker.new(%{}))
    assert [_one] = all_enqueued(worker: CleanupDeviceAuthWorker)
  end

  # Every run says what it did, zeros included: a silent run and a run that
  # deleted nothing look the same otherwise.
  test "logs its counts on a run that deletes nothing" do
    # Test config logs at :warning. A module level is scoped to the worker,
    # which no other test module logs from.
    Logger.put_module_level(CleanupDeviceAuthWorker, :info)
    on_exit(fn -> Logger.delete_module_level(CleanupDeviceAuthWorker) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = perform_job(CleanupDeviceAuthWorker, %{})
      end)

    assert log =~ "cleanup_device_auth device_rows=0 oauth_rows=0"
  end

  test "gives up after 3 attempts" do
    assert %{max_attempts: 3} = CleanupDeviceAuthWorker.new(%{}).changes
  end
end
