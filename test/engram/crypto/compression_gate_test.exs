defmodule Engram.Crypto.CompressionGateTest do
  # async: false: one test flips the app-wide gate key and kill switch.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Engram.Crypto
  alias Engram.Crypto.{CompressionGate, Envelope}

  @peer :"engram@10.0.0.2"

  @reasons [
    :cluster_reads_format_1,
    :members_missing,
    :peer_cannot_read,
    :peer_unreachable,
    :evaluation_failed
  ]

  defp one_hot(current), do: Map.new(@reasons, &{&1, if(&1 == current, do: 1, else: 0)})

  # Every {:reason, r, v} message in the mailbox, as %{r => v}.
  defp one_hot_reasons(acc \\ %{}) do
    receive do
      {:reason, r, v} ->
        refute Map.has_key?(acc, r), "reason #{r} emitted twice"
        one_hot_reasons(Map.put(acc, r, v))
    after
      0 -> acc
    end
  end

  defp ok_multicall(format), do: fn peers -> Enum.map(peers, fn _ -> {:ok, format} end) end

  describe "evaluate/1" do
    test "a single node (no role, no cluster query, no peers) is allowed" do
      assert {:allowed, _, nil} =
               CompressionGate.evaluate(role: nil, query: nil, peers: fn -> [] end)
    end

    test "every connected peer reading format 1 is allowed" do
      assert {:allowed, _, _} =
               CompressionGate.evaluate(
                 role: nil,
                 query: nil,
                 peers: fn -> [@peer] end,
                 multicall: ok_multicall(1)
               )
    end

    test "a peer reporting format 0 blocks" do
      assert {:blocked, :peer_cannot_read, @peer} =
               CompressionGate.evaluate(
                 role: nil,
                 query: nil,
                 peers: fn -> [@peer] end,
                 multicall: ok_multicall(0)
               )
    end

    test "a pre-R1 peer (no max_read_format/0) counts as 0" do
      undef = fn [_] -> [{:error, {:exception, :undef, []}}] end

      assert {:blocked, :peer_cannot_read, @peer} =
               CompressionGate.evaluate(
                 role: nil,
                 query: nil,
                 peers: fn -> [@peer] end,
                 multicall: undef
               )
    end

    test "an erpc error or timeout blocks" do
      down = fn [_] -> [{:error, {:erpc, :timeout}}] end

      assert {:blocked, :peer_unreachable, @peer} =
               CompressionGate.evaluate(
                 role: nil,
                 query: nil,
                 peers: fn -> [@peer] end,
                 multicall: down
               )
    end

    test "a discovered member that is not connected blocks" do
      assert {:blocked, :members_missing, nil} =
               CompressionGate.evaluate(
                 role: :web,
                 query: "engram.internal",
                 resolver: fn _ -> ["10.0.0.1", "10.0.0.2", "10.0.0.3"] end,
                 self_ip: "10.0.0.1",
                 peers: fn -> [@peer] end,
                 multicall: ok_multicall(1)
               )
    end

    test "a DNS failure (empty resolution) blocks" do
      assert {:blocked, :members_missing, nil} =
               CompressionGate.evaluate(
                 role: :web,
                 query: "engram.internal",
                 resolver: fn _ -> [] end,
                 self_ip: "10.0.0.1",
                 peers: fn -> [@peer] end,
                 multicall: ok_multicall(1)
               )
    end

    test "a full, format-1 cluster is allowed" do
      assert {:allowed, _, _} =
               CompressionGate.evaluate(
                 role: :web,
                 query: "engram.internal",
                 resolver: fn _ -> ["10.0.0.1", "10.0.0.2"] end,
                 self_ip: "10.0.0.1",
                 peers: fn -> [@peer] end,
                 multicall: ok_multicall(1)
               )
    end
  end

  describe "the cached verdict" do
    setup do
      key = {__MODULE__, System.unique_integer([:positive])}
      calls = :counters.new(1, [])
      format = :atomics.new(1, [])
      :atomics.put(format, 1, 1)

      multicall = fn peers ->
        :counters.add(calls, 1, 1)
        Enum.map(peers, fn _ -> {:ok, :atomics.get(format, 1)} end)
      end

      opts = [
        name: __MODULE__.Gate,
        key: key,
        monitor: false,
        refresh_ms: :timer.hours(1),
        role: nil,
        query: nil,
        peers: fn -> [@peer] end,
        multicall: multicall
      ]

      on_exit(fn -> :persistent_term.erase(key) end)
      %{opts: opts, key: key, calls: calls, format: format}
    end

    test "reads never evaluate: one erpc per refresh, none per allowed?/1 call",
         %{opts: opts, key: key, calls: calls} do
      start_supervised!({CompressionGate, opts})
      assert :counters.get(calls, 1) == 1

      for _ <- 1..1_000, do: assert(CompressionGate.allowed?(key))
      assert :counters.get(calls, 1) == 1
    end

    test "each transition logs and emits telemetry once", %{opts: opts, key: key, format: format} do
      handler = "gate-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:engram, :envelope, :compression_gate],
        fn _e, m, meta, _c -> send(parent, {:gate, m.allowed, meta.reason}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      start_supervised!({CompressionGate, opts})
      assert_received {:gate, 1, :cluster_reads_format_1}

      :atomics.put(format, 1, 0)

      log =
        capture_log([level: :warning], fn ->
          refute CompressionGate.refresh(opts[:name])
          refute CompressionGate.refresh(opts[:name])
        end)

      refute CompressionGate.allowed?(key)
      assert_received {:gate, 0, :peer_cannot_read}
      refute_received {:gate, _, _}
      assert length(String.split(log, "envelope compression blocked")) == 2

      :atomics.put(format, 1, 1)
      assert CompressionGate.refresh(opts[:name])
      assert CompressionGate.refresh(opts[:name])
      assert_received {:gate, 1, :cluster_reads_format_1}
      refute_received {:gate, _, _}
    end

    test "every reason change emits the one-hot reason gauge over all reasons",
         %{opts: opts, format: format} do
      handler = "gate-reason-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:engram, :envelope, :compression_gate, :reason],
        fn _e, m, meta, _c -> send(parent, {:reason, meta.reason, m.current}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      start_supervised!({CompressionGate, opts})
      assert one_hot_reasons() == one_hot(:cluster_reads_format_1)

      :atomics.put(format, 1, 0)
      refute CompressionGate.refresh(opts[:name])
      refute CompressionGate.refresh(opts[:name])
      assert one_hot_reasons() == one_hot(:peer_cannot_read)
      assert one_hot_reasons() == %{}
    end

    test "a block at first evaluation logs :info, not :warning", %{opts: opts} do
      opts = Keyword.put(opts, :multicall, fn peers -> Enum.map(peers, fn _ -> {:ok, 0} end) end)

      warn = capture_log([level: :warning], fn -> start_supervised!({CompressionGate, opts}) end)
      refute warn =~ "envelope compression blocked"
    end

    test "an evaluation that raises fails closed", %{opts: opts, key: key} do
      opts = Keyword.put(opts, :multicall, fn _ -> raise "boom" end)
      capture_log(fn -> start_supervised!({CompressionGate, opts}) end)
      refute CompressionGate.allowed?(key)
    end
  end

  describe "the effective decision" do
    @aad Crypto.aad_for_row(:notes, :content, Ecto.UUID.generate())

    setup do
      prev_switch = Application.get_env(:engram, :envelope_compression)
      prev_gate = CompressionGate.allowed?()

      on_exit(fn ->
        Application.put_env(:engram, :envelope_compression, prev_switch)
        :persistent_term.put({CompressionGate, :allowed}, prev_gate)
      end)
    end

    test "single-node test app: the gate allows, so the policy applies" do
      assert CompressionGate.allowed?()
      assert Envelope.mode_for(@aad) == :zstd
    end

    test "a blocked gate writes format 0 with the switch on" do
      Application.put_env(:engram, :envelope_compression, true)
      :persistent_term.put({CompressionGate, :allowed}, false)
      refute Envelope.compression_on?()
      assert Envelope.mode_for(@aad) == :none
      refute Engram.DataMigrations.EnvelopeFormat.enabled?()
    end

    test "the kill switch wins over an allowed gate" do
      :persistent_term.put({CompressionGate, :allowed}, true)
      Application.put_env(:engram, :envelope_compression, false)
      refute Envelope.compression_on?()
      assert Envelope.mode_for(@aad) == :none
    end
  end
end
