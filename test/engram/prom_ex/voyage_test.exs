defmodule Engram.PromEx.VoyageTest do
  @moduledoc """
  Verifies the Voyage PromEx plugin declares Telemetry.Metrics events for
  Voyage embedding API latency + errors, and that the events the plugin
  subscribes to are actually emitted by `Engram.Embedders.Voyage`.

  Cardinality contract: tags MUST NOT include user_id, vault_id, or any
  per-tenant identifier. Only bounded labels (status, purpose) are allowed.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.Voyage, as: VoyagePlugin
  alias PromEx.MetricTypes.Event

  describe "event_metrics/1" do
    test "returns an Event.t() (or list) of Telemetry.Metrics with engram_prom_ex.voyage prefix" do
      result = VoyagePlugin.event_metrics(otp_app: :engram)
      events = List.wrap(result)

      assert Enum.all?(events, &match?(%Event{}, &1)),
             "event_metrics/1 must return PromEx.MetricTypes.Event structs"

      assert Enum.any?(events), "Voyage plugin must declare at least one event group"

      metrics = Enum.flat_map(events, & &1.metrics)

      assert Enum.any?(metrics, fn m ->
               Enum.take(m.name, 2) == [:engram, :prom_ex] and Enum.at(m.name, 2) == :voyage
             end),
             "Metrics must be prefixed with [:engram, :prom_ex, :voyage, ...]"
    end

    test "declares a latency distribution for embed requests" do
      metrics =
        VoyagePlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      assert Enum.any?(metrics, fn m ->
               match?(%Telemetry.Metrics.Distribution{}, m) and
                 m.event_name == [:engram, :voyage, :embed, :stop]
             end),
             "Must subscribe to [:engram, :voyage, :embed, :stop] with a distribution metric"
    end

    test "declares a counter for embed errors" do
      metrics =
        VoyagePlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      assert Enum.any?(metrics, fn m ->
               match?(%Telemetry.Metrics.Counter{}, m) and
                 m.event_name == [:engram, :voyage, :embed, :stop]
             end),
             "Must have a counter on the :stop event so error rate is derivable from `status` tag"
    end

    test "never includes high-cardinality tags (user_id, vault_id)" do
      metrics =
        VoyagePlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      banned = [:user_id, :vault_id, :tenant_id, :path, :path_hmac]

      for m <- metrics, tag <- m.tags do
        refute tag in banned,
               "Voyage plugin metric #{inspect(m.name)} has banned high-cardinality tag #{inspect(tag)}"
      end
    end
  end

  describe "telemetry events emitted by Embedders.Voyage" do
    test "embed_texts/1 emits [:engram, :voyage, :embed, :stop] with status + duration" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:engram, :voyage, :embed, :stop],
        fn _name, measurements, metadata, _ ->
          send(test_pid, {:embed_stop, ref, measurements, metadata})
        end,
        nil
      )

      on_exit_detach({__MODULE__, ref})

      # Hit a non-existent host so the call fast-fails with an error tuple
      # — exercises the error path and proves the span emits a `:stop` with
      # a status tag regardless of outcome.
      prev_url = Application.get_env(:engram, :voyage_url)
      prev_key = Application.get_env(:engram, :voyage_api_key)
      Application.put_env(:engram, :voyage_url, "http://127.0.0.1:1")
      Application.put_env(:engram, :voyage_api_key, "test")

      on_exit(fn ->
        if prev_url do
          Application.put_env(:engram, :voyage_url, prev_url)
        else
          Application.delete_env(:engram, :voyage_url)
        end

        if prev_key do
          Application.put_env(:engram, :voyage_api_key, prev_key)
        else
          Application.delete_env(:engram, :voyage_api_key)
        end
      end)

      _ = Engram.Embedders.Voyage.embed_texts(["hello"], retry: false, max_retries: 0)

      assert_receive {:embed_stop, ^ref, measurements, metadata}, 5_000
      assert is_integer(measurements[:duration])
      assert metadata[:status] in [:ok, :error]
      assert metadata[:purpose] in [:query, :index]
    end
  end

  defp on_exit_detach(handler_key) do
    on_exit(fn -> :telemetry.detach(handler_key) end)
  end
end
