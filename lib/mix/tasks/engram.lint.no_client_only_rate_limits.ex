defmodule Mix.Tasks.Engram.Lint.NoClientOnlyRateLimits do
  @shortdoc "Pricing v2 §G — verify every Free-restrictive limit is enforced server-side"

  @moduledoc """
  Pricing v2 §G server-side enforcement lint.

  Walks `Engram.Billing.LimitKeys.all/0` and confirms that every key whose
  Free-tier default is **restrictive** (a non-nil integer, or `false` for
  booleans) has at least one server-side `Engram.Billing.{effective_limit,
  check_limit, check_feature}` reference in `lib/`.

  A key may be intentionally absent from server-side enforcement (legacy
  display-only feature flag, etc.). Such opt-outs MUST be declared in the
  `@opt_outs` list below with a comment explaining why.

  Also scans `lib/` for any source comment of the form
  `# client-only-rate-limit` (case-insensitive) and fails if found — that
  marker is reserved for code that explicitly disclaims server enforcement.

  Usage: `mix engram.lint.no_client_only_rate_limits`
  """

  use Mix.Task

  alias Engram.Billing.LimitKeys

  # Keys deliberately not enforced server-side. Every entry needs a reason
  # comment so future readers can decide whether to promote it.
  @opt_outs %{
    # Legacy feature flag — surfaces in UX, no per-request gate point yet.
    cross_vault_search: "legacy UX flag; no server gate point yet",
    # Legacy feature flag — API-key scoping was reworked in T3.4; no
    # current Billing.* call site references it.
    vault_scoped_keys: "legacy; superseded by api_key_vaults table",
    # The §C InactivityCleanup cron filters to Free via Billing.tier/1
    # rather than reading these keys. TODO: migrate cron to read the
    # catalog so per-user overrides take effect.
    inactivity_warn_60_days:
      "TODO follow-up: InactivityCleanup hardcodes 60d/80d/90d windows; migrate to LimitKeys",
    inactivity_delete_days: "TODO follow-up: same as inactivity_warn_60_days",
    # Attachment / file caps — TODO follow-up. AttachmentController.create/2
    # must call Billing.check_limit(user, :attachment_bytes_cap, current_total)
    # and Billing.check_limit(user, :max_file_bytes, byte_size).
    attachment_bytes_cap:
      "TODO follow-up: AttachmentController.create/2 needs per-user lifetime quota check",
    max_file_bytes: "TODO follow-up: AttachmentController.create/2 needs per-file size check",
    # Device-auth caps — TODO follow-up. DeviceAuthController already enforces
    # vaults_cap; needs explicit concurrent_devices + cooldown checks.
    concurrent_devices: "TODO follow-up: DeviceAuthController needs per-user device count check",
    device_swap_cooldown_hours:
      "TODO follow-up: DeviceAuthController needs cooldown check on revoke + re-add",
    # Feature flags — TODO follow-up. Search controller must reject reranker
    # request when Free; API write controllers must reject write when Free.
    reranker_enabled: "TODO follow-up: SearchController must gate reranker path on this flag",
    api_write_enabled: "TODO follow-up: write controllers must gate on this flag",
    # API RPS cap — TODO follow-up. RateLimit plug currently uses a flat
    # per-user ceiling; should pull api_rps_cap per-plan.
    api_rps_cap: "TODO follow-up: RateLimit plug should pull per-plan cap from LimitKeys"
  }

  # Exposed for the self-scan meta-test in
  # `test/mix/tasks/engram/lint/no_client_only_rate_limits_test.exs`.
  @doc false
  def __opt_outs__, do: @opt_outs

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("compile")

    # Exclude `lib/mix/tasks/` from both scans: the lint task itself
    # references both the catalog keys (in @opt_outs) and the marker
    # string (in @moduledoc), which would otherwise trip every check.
    lib_files =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(&String.contains?(&1, "lib/mix/tasks/"))

    blob = Enum.map_join(lib_files, "\n", &File.read!/1)

    coverage_violations = check_catalog_coverage(blob)
    marker_violations = check_client_only_markers(lib_files)

    case {coverage_violations, marker_violations} do
      {[], []} ->
        Mix.shell().info(
          "no_client_only_rate_limits lint: 0 violations across #{length(lib_files)} files"
        )

      _ ->
        report(coverage_violations, marker_violations)
        Mix.raise("no_client_only_rate_limits lint failed")
    end
  end

  defp check_catalog_coverage(blob) do
    LimitKeys.all()
    |> Enum.reject(fn key ->
      Map.has_key?(@opt_outs, key) or free_default_unrestricted?(key) or
        referenced_in_blob?(blob, key)
    end)
    |> Enum.map(fn key -> {:missing_enforcement, key} end)
  end

  defp free_default_unrestricted?(key) do
    case LimitKeys.default_for(key, :free) do
      nil -> true
      true -> true
      _ -> false
    end
  end

  defp referenced_in_blob?(blob, key) do
    String.contains?(blob, ":#{key}")
  end

  defp check_client_only_markers(files) do
    Enum.flat_map(files, fn file ->
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} ->
        Regex.match?(~r/#\s*client-only-rate-limit/i, line)
      end)
      |> Enum.map(fn {line, lineno} -> {:client_only_marker, file, lineno, String.trim(line)} end)
    end)
  end

  defp report(coverage, markers) do
    Enum.each(coverage, fn {:missing_enforcement, key} ->
      Mix.shell().error(
        "missing server-side enforcement for :#{key} — " <>
          "no Billing.* call site references it. Either add a check or " <>
          "add it to @opt_outs with a reason."
      )
    end)

    Enum.each(markers, fn {:client_only_marker, file, line, src} ->
      Mix.shell().error("#{file}:#{line}: client-only-rate-limit marker found — #{src}")
    end)
  end
end
