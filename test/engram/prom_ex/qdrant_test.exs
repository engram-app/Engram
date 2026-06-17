defmodule Engram.PromEx.QdrantTest do
  @moduledoc """
  Verifies the Qdrant PromEx plugin and the wrapping `:telemetry.span`
  in `Engram.Vector.Qdrant`.

  Cardinality contract: tags only `:op` (bounded enum) + `:status`.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.Qdrant, as: QdrantPlugin
  alias Engram.ServiceConfig
  alias PromEx.MetricTypes.Event

  describe "event_metrics/1" do
    test "returns Event struct(s) prefixed [:engram, :prom_ex, :qdrant]" do
      result = QdrantPlugin.event_metrics(otp_app: :engram)
      events = List.wrap(result)
      assert Enum.all?(events, &match?(%Event{}, &1))

      metrics = Enum.flat_map(events, & &1.metrics)
      assert Enum.any?(metrics, fn m -> Enum.at(m.name, 2) == :qdrant end)
    end

    test "declares a latency distribution + counter on [:engram, :qdrant, :request, :stop]" do
      metrics =
        QdrantPlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      target = [:engram, :qdrant, :request, :stop]

      assert Enum.any?(metrics, fn m ->
               match?(%Telemetry.Metrics.Distribution{}, m) and m.event_name == target
             end)

      assert Enum.any?(metrics, fn m ->
               match?(%Telemetry.Metrics.Counter{}, m) and m.event_name == target
             end)
    end

    test "no high-cardinality tags" do
      metrics =
        QdrantPlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      banned = [:user_id, :vault_id, :tenant_id, :collection, :point_id, :path]

      for m <- metrics, tag <- m.tags do
        refute tag in banned, "Qdrant metric #{inspect(m.name)} has banned tag #{inspect(tag)}"
      end
    end
  end

  describe "telemetry events from Engram.Vector.Qdrant" do
    setup do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:engram, :qdrant, :request, :stop],
        fn _name, m, meta, _ -> send(test_pid, {:qdrant_stop, ref, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      # Per-process overrides (not global put_env) so this suite runs async.
      ServiceConfig.put_override(:qdrant_url, "http://127.0.0.1:1")
      # Avoid Req's transient retry loop blowing the test runtime
      ServiceConfig.put_override(:qdrant_retry, false)

      {:ok, ref: ref}
    end

    test "search/3 emits :stop with op=:search", %{ref: ref} do
      _ = Engram.Vector.Qdrant.search("test_col", [0.0], user_id: "u1")
      assert_receive {:qdrant_stop, ^ref, %{duration: _}, %{op: :search, status: :error}}, 5_000
    end

    test "upsert_points/2 emits :stop with op=:upsert", %{ref: ref} do
      _ = Engram.Vector.Qdrant.upsert_points("test_col", [])
      assert_receive {:qdrant_stop, ^ref, %{duration: _}, %{op: :upsert, status: :error}}, 5_000
    end
  end
end
