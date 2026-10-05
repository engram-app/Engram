defmodule Engram.Workers.CleanupDeviceAuthWorkerUniqueTest do
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Workers.CleanupDeviceAuthWorker

  # A slow run must not stack the next tick behind it, and a failing DELETE
  # is not worth Oban's default 20 attempts: the next tick retries it.
  test "a pending run absorbs the next tick" do
    for _ <- 1..3, do: {:ok, _} = Oban.insert(CleanupDeviceAuthWorker.new(%{}))
    assert [_one] = all_enqueued(worker: CleanupDeviceAuthWorker)
  end

  test "gives up after 3 attempts" do
    assert %{max_attempts: 3} = CleanupDeviceAuthWorker.new(%{}).changes
  end
end
