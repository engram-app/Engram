defmodule Engram.PromEx.ReliabilityTest do
  @moduledoc """
  Verifies the Reliability PromEx plugin metric shape — the cross-cutting
  incident counters (auth rejections, RLS tenant tripwire, embed failures,
  Oban discards) reach the scraped /metrics endpoint, not just LiveDashboard.

  Event emission is covered by the respective context/plug tests; this guards
  Prometheus registration + the cardinality contract.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.Reliability, as: Plugin
  alias PromEx.MetricTypes.Event

  defp metrics do
    Plugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)
  end

  defp counter_for(event_name) do
    Enum.find(metrics(), fn m ->
      match?(%Telemetry.Metrics.Counter{}, m) and m.event_name == event_name
    end)
  end

  describe "event_metrics/1" do
    test "returns Event struct(s) prefixed [:engram, :prom_ex, :reliability]" do
      events = Plugin.event_metrics(otp_app: :engram) |> List.wrap()
      assert Enum.all?(events, &match?(%Event{}, &1))
      assert Enum.any?(metrics(), fn m -> Enum.at(m.name, 2) == :reliability end)
    end

    test "counts auth rejections tagged by reason + source" do
      m = counter_for([:engram, :auth, :rejected])
      assert m, "expected a counter on [:engram, :auth, :rejected]"
      assert :reason in m.tags
      assert :source in m.tags
    end

    test "counts the RLS tenant-guard tripwire tagged by table" do
      assert %{tags: tags} = counter_for([:engram, :repo, :tenant_guard_violation])
      assert :table in tags
    end

    test "counts honored tenant-check bypasses tagged by table" do
      assert %{tags: tags} = counter_for([:engram, :repo, :tenant_check_skipped])
      assert :table in tags
    end

    test "counts embed failures tagged by error_kind + status" do
      assert %{tags: tags} = counter_for([:engram, :embed, :failed])
      assert :error_kind in tags
      assert :status in tags
    end

    test "counts Oban discards tagged by worker/queue/error_kind (not job_id)" do
      assert %{tags: tags} = counter_for([:engram, :oban, :discarded])
      assert :worker in tags
      assert :queue in tags
      assert :error_kind in tags
    end

    test "no per-tenant / high-cardinality tags" do
      banned = [:user_id, :vault_id, :note_id, :tenant_id, :job_id]

      for m <- metrics(), tag <- m.tags do
        refute tag in banned, "Reliability metric #{inspect(m.name)} has banned tag #{inspect(tag)}"
      end
    end
  end

  describe "registration" do
    test "plugin is wired into Engram.PromEx" do
      assert Engram.PromEx.Reliability in Engram.PromEx.plugins()
    end
  end
end
