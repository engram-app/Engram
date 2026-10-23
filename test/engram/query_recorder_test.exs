defmodule Engram.QueryRecorderTest do
  use ExUnit.Case, async: true

  # Another process querying every 10 ms never leaves the 50 ms quiet gap
  # the drain waited for: it hung until the 60 s test timeout (#2151 CI).
  test "recording returns while other processes keep querying" do
    noisy =
      spawn_link(fn ->
        Stream.repeatedly(fn ->
          Engram.QueryRecorder.emit_foreign_query()
          Process.sleep(10)
        end)
        |> Stream.run()
      end)

    task = Task.async(fn -> Engram.QueryRecorder.record(fn -> :ok end) end)
    assert {:ok, {:ok, _queries}} = Task.yield(task, 3_000) || Task.shutdown(task)
    Process.unlink(noisy)
    Process.exit(noisy, :kill)
  end
end
