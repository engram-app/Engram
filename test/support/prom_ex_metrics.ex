defmodule Engram.Test.PromExMetrics do
  @moduledoc """
  A PromEx plugin's `event_metrics/1`, built ONCE per test VM per options.

  A plugin with latency buckets compiles fresh `<group>.Bucket_N` modules on
  every call, so each call from a test REDEFINES a loaded module. The
  redefinition purges the old version through the code server, and the purge
  waits on a literal-area sweep of every process; with async suites holding
  large heaps and long dirty NIF calls, that held the code server for over a
  minute and timed out an unrelated `Application.app_dir` call
  (`PreflightTest`, CI 2026-10-20, 26 redefinitions in the failing
  partition, also seen on other branches). Tests read the structs; none
  needs a fresh module.
  """

  def of(plugin, opts \\ [otp_app: :engram]) do
    key = {__MODULE__, plugin, opts}

    case :persistent_term.get(key, nil) do
      nil ->
        metrics = plugin.event_metrics(opts)
        :persistent_term.put(key, metrics)
        metrics

      metrics ->
        metrics
    end
  end
end
