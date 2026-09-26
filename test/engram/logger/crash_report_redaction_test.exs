defmodule Engram.Logger.CrashReportRedactionTest do
  @moduledoc """
  A crashing GenServer's report prints its last message. For a Phoenix channel
  that is the client payload (`crdt_create` carries a plaintext `path`,
  `crdt_msg` a base64 Yjs update), and the report goes to Loki at error level
  and is parsed by Sentry's LoggerHandler into `extra.last_message`.
  `RedactFilter` never sees it: it gates metadata keys, not message text.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @canary "Medical/canary-9c1e.md"

  defmodule Crasher do
    use GenServer

    def init(state), do: {:ok, state}
    def handle_info({:crdt_create, _payload}, _state), do: raise("boom")
  end

  test "a GenServer crash report does not print the last message's strings" do
    log =
      capture_log(fn ->
        {:ok, pid} = GenServer.start(Crasher, %{path: @canary})
        ref = Process.monitor(pid)
        send(pid, {:crdt_create, %{"path" => @canary, "update" => Base.encode64(@canary)}})
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      end)

    # The report itself still lands, so a pass is not an empty capture.
    assert log =~ "terminating"
    assert log =~ "boom"

    refute log =~ "canary-9c1e"
    refute log =~ Base.encode64(@canary)
  end
end
