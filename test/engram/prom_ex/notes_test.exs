defmodule Engram.PromEx.NotesTest do
  @moduledoc """
  Verifies the Notes PromEx plugin metric shape. Event emission (the
  `[:engram, :notes, :utf8_scrub]` slow-path) is covered by
  `Engram.Notes.HelpersTest` and `Engram.NotesTest`; this guards Prometheus
  registration — `EngramWeb.Telemetry.metrics/0` feeds LiveDashboard only, so
  without this plugin the counter never reaches the scraped /metrics endpoint.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.Notes, as: NotesPlugin
  alias PromEx.MetricTypes.Event

  describe "event_metrics/1" do
    setup do
      metrics =
        NotesPlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      %{metrics: metrics}
    end

    test "returns Event struct(s) prefixed [:engram, :prom_ex, :notes]" do
      events = NotesPlugin.event_metrics(otp_app: :engram) |> List.wrap()
      assert Enum.all?(events, &match?(%Event{}, &1))
      metrics = Enum.flat_map(events, & &1.metrics)
      assert Enum.any?(metrics, fn m -> Enum.at(m.name, 2) == :notes end)
    end

    test "declares a boundary-tagged counter on [:engram, :notes, :utf8_scrub]", %{
      metrics: metrics
    } do
      assert Enum.any?(metrics, fn m ->
               match?(%Telemetry.Metrics.Counter{}, m) and
                 m.event_name == [:engram, :notes, :utf8_scrub] and
                 :boundary in m.tags
             end)
    end

    test "no high-cardinality tags", %{metrics: metrics} do
      banned = [:user_id, :vault_id, :tenant_id, :note_id, :path, :content]

      for m <- metrics, tag <- m.tags do
        refute tag in banned, "Notes metric #{inspect(m.name)} has banned tag #{inspect(tag)}"
      end
    end
  end
end
