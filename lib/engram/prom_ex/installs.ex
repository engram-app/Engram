defmodule Engram.PromEx.Installs do
  @moduledoc """
  PromEx plugin that makes the self-host install census (`install_pings`)
  visible in Grafana: installs seen in the last 30 days, per
  `os` / `arch` / `runtime`.

  SaaS only: self-host has no collector rows, so it emits nothing there.

  Cardinality contract: all three labels are fixed enums
  (`Engram.Telemetry.InstallPing`), so the series count is capped at
  4 x 3 x 2 = 24. Every combination is emitted on every poll, zeros included,
  so a group that goes quiet reads 0 instead of freezing at its last value.
  NEVER add `version` or the install id as a label. Every app node computes the
  same number from the DB: aggregate with `max`, never `sum`.
  """

  use PromEx.Plugin

  import Ecto.Query, only: [from: 2]

  alias Engram.Repo
  alias Engram.Telemetry.InstallPing

  @event [:engram, :installs, :seen]
  @window_days 30

  @impl true
  def polling_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :installs)
    poll_rate = Keyword.get(opts, :installs_poll_rate, :timer.minutes(5))

    Polling.build(
      :engram_installs_polling_metrics,
      poll_rate,
      {__MODULE__, :execute_install_metrics, []},
      [
        last_value(
          metric_prefix ++ [:seen],
          event_name: @event,
          measurement: :count,
          tags: [:os, :arch, :runtime],
          description:
            "Self-host installs that pinged the census collector in the last #{@window_days} days. " <>
              "Aggregate with max, never sum: every node reports the same DB count."
        )
      ]
    )
  end

  @spec execute_install_metrics() :: :ok
  def execute_install_metrics do
    if Application.get_env(:engram, :billing_enabled, false) do
      emit_counts(recent_counts())
    else
      :ok
    end
  end

  defp emit_counts(counts) do
    for os <- InstallPing.oses(),
        arch <- InstallPing.arches(),
        runtime <- InstallPing.runtimes() do
      {os, arch, runtime}
    end
    |> Enum.each(fn {os, arch, runtime} = key ->
      :telemetry.execute(
        @event,
        %{count: Map.get(counts, key, 0)},
        %{os: os, arch: arch, runtime: runtime}
      )
    end)
  end

  defp recent_counts do
    cutoff = DateTime.utc_now(:second) |> DateTime.add(-@window_days * 86_400)

    from(p in InstallPing,
      where: p.updated_at > ^cutoff,
      group_by: [p.os, p.arch, p.runtime],
      select: {{p.os, p.arch, p.runtime}, count(p.id)}
    )
    |> Repo.all(skip_tenant_check: true)
    |> Map.new()
  end
end
