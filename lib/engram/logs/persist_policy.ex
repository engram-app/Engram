defmodule Engram.Logs.PersistPolicy do
  @moduledoc """
  Which client log lines `client_logs` keeps. The one source of truth for the
  info allowlist.

  Stored: every warn and error line, plus info lines whose message starts with
  an `info_allowlist/0` prefix. Everything else (plain info, debug) is dropped
  at ingest and counted (`[:engram, :client_logs, :dropped]`).

  Why: plain info was ~93% of steady-state rows, was read by no prod caller,
  and warn/error lines are what `GET /api/logs` is used for when debugging a
  stuck user. The allowlist keeps the low-volume first-sync milestones that
  say where a user's first sync stopped (`docs/context/first-sync-anatomy.md`
  in the workspace repo).

  Reach of the plugin milestones: `rlog().info` lines are sent only when the
  user turned plugin diagnostics on (off by default), so on a typical first
  sync none of them arrive and only the warn anomalies do. Do not count on
  them being there; making them always ship needs the plugin's forced path.
  The web SPA sends its info lines with no opt-in, so its breadcrumbs do arrive.

  Applies only when `:client_logs_persist_all` is false: SaaS. CI (the e2e log
  oracle reads info lines), test and self-host (no Loki, so `client_logs` is
  the only copy of a client line) keep everything; see
  `Engram.RuntimeConfig.client_logs_persist_all?/2`.
  """

  @stored_levels ~w(warn error)

  # Exact plugin message prefixes (engram-obsidian-sync src/). Prefix match,
  # so a line's trailing counts never matter.
  @info_allowlist [
    # The first-sync tripwires. All three ship at warn today (`rlog().anomaly`
    # / `rlog().warn`) and are stored by level anyway; listed so a level
    # change in a future plugin cannot silently drop them.
    "catch_up_skipped_sync_gate_closed",
    "replay_produced_no_files",
    "manifest validator:",
    # First-sync milestones, info (main.ts, sync.ts). One line each per sync.
    "Layout ready — starting initial sync",
    "Vault not registered — skipping initial sync",
    "sync_gate_opened",
    # "pullAll started — replay from 0" / "pullAll replay done — applied=N",
    # also the "pullAll(deleteLocalExtras)" variant.
    "pullAll",
    # Web SPA deaf-note breadcrumbs (frontend/src/observability/remote-log.ts:
    # a deaf-note hunt is a `GET /api/logs` query). Not diagnostic, so they
    # never reach Loki; this is their only store. One line per join / resync.
    "crdt channel joined",
    "resync ("
  ]

  # The levels a client may send. Anything else is stored and counted as
  # "other": the client sends any string as `level`, and a raw value would be
  # a cardinality bomb on the metric and an open set in `client_logs.level`.
  @metric_levels ~w(debug info warn error)

  @doc "Info message prefixes that are stored even when filtering."
  def info_allowlist, do: @info_allowlist

  @doc "True when a bounded entry should be written to `client_logs` under the filter."
  def persist?(%{level: level, message: message}) do
    level in @stored_levels or String.starts_with?(message, @info_allowlist)
  end

  @doc "Every value `client_logs.level` can hold: `metric_level/1`'s range."
  def levels, do: @metric_levels ++ ["other"]

  @doc "`level` bounded to `levels/0`: the metric tag and the stored value."
  def metric_level(level) when level in @metric_levels, do: level
  def metric_level(_level), do: "other"
end
