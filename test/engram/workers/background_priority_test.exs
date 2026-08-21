defmodule Engram.Workers.BackgroundPriorityTest do
  use ExUnit.Case, async: false

  alias Engram.Workers.BackgroundPriority

  setup do
    original = Application.get_env(:engram, :background_job_priority)
    on_exit(fn -> Application.put_env(:engram, :background_job_priority, original) end)
    :ok
  end

  # Run in a throwaway process — demoting the test process itself is exactly
  # the failure mode the config gate exists to prevent.
  defp priority_after_demote do
    task =
      Task.async(fn ->
        :ok = BackgroundPriority.demote()
        {:priority, p} = :erlang.process_info(self(), :priority)
        p
      end)

    Task.await(task)
  end

  test "demotes to :low when configured" do
    Application.put_env(:engram, :background_job_priority, :low)
    assert priority_after_demote() == :low
  end

  test "no-ops when configured :normal" do
    Application.put_env(:engram, :background_job_priority, :normal)
    assert priority_after_demote() == :normal
  end

  test "defaults to :low when unset" do
    Application.delete_env(:engram, :background_job_priority)
    assert priority_after_demote() == :low
  end

  test "test env is configured :normal so perform_job cannot strand the test process" do
    # Fences the reason config/test.exs sets this: Oban.Testing.perform_job/2
    # runs perform/1 in the calling process.
    assert Application.get_env(:engram, :background_job_priority) == :normal
    assert :erlang.process_info(self(), :priority) == {:priority, :normal}
  end
end
