defmodule EngramWeb.HealthController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias EngramWeb.Schemas.HealthStatus

  require Logger

  operation(:index,
    operation_id: "health",
    summary: "Liveness probe",
    security: [],
    description: "Cheap liveness check. Always 200 if the app is up.",
    responses: [
      ok: {"Service is up", "application/json", HealthStatus}
    ]
  )

  def index(conn, _params) do
    json(conn, %{status: "ok", version: Application.spec(:engram, :vsn) |> to_string()})
  end

  operation(:deep,
    operation_id: "health-deep",
    summary: "Readiness probe",
    security: [],
    description:
      "Checks dependencies whose absence fails every request (Postgres), plus BEAM cluster join on clustered deploys. 503 when degraded.",
    responses: [
      ok: {"All critical deps ok", "application/json", HealthStatus},
      service_unavailable: {"Degraded", "application/json", HealthStatus}
    ]
  )

  # ALB target group readiness probe. Only checks dependencies whose
  # absence makes EVERY request fail — Postgres is that one. Qdrant,
  # S3 etc. stay OUT so a single dep outage cannot pull all tasks
  # from rotation. Surface those via /api/health/diagnostics (auth-gated)
  # and per-dep CloudWatch/Grafana alarms.
  #
  # Clustered deploys (DNS_CLUSTER_QUERY set) additionally gate on
  # cluster join, so a rolling deploy's new task doesn't take traffic
  # while its PubSub is still per-node (WS clients on it would silently
  # miss cross-node note_changed fan-out). Bounded by a boot grace so
  # broken clustering can never wedge a deploy — Engram.Cluster.Readiness.
  def deep(conn, _params) do
    checks =
      %{"postgres" => check_postgres()}
      |> put_cluster_check(Engram.Cluster.Readiness.check(cluster_readiness_opts()))

    all_ok = Enum.all?(checks, fn {_k, v} -> ok_status?(v) end)
    status = if all_ok, do: "ok", else: "degraded"
    http_status = if all_ok, do: 200, else: 503

    conn
    |> put_status(http_status)
    |> json(%{status: status, checks: checks})
  end

  # Values this controller itself produces are always exactly "ok" or
  # "ok: <detail>" — never a bare prefix match. Keeps a future check value
  # that merely starts with "ok" (e.g. an error message) from false-passing.
  defp ok_status?("ok"), do: true
  defp ok_status?("ok: " <> _), do: true
  defp ok_status?(_), do: false

  # Test seam only — lets ExUnit inject peers/resolver/uptime without real
  # distribution. Unset everywhere else (empty opts = live node defaults).
  defp cluster_readiness_opts do
    Application.get_env(:engram, :cluster_readiness_opts, [])
  end

  defp put_cluster_check(checks, :not_clustered), do: checks
  defp put_cluster_check(checks, :ready), do: Map.put(checks, "cluster", "ok")
  defp put_cluster_check(checks, {:ready, :alone}), do: Map.put(checks, "cluster", "ok: alone")

  @grace_expired_logged_key {__MODULE__, :cluster_grace_expired_logged}

  defp put_cluster_check(checks, {:ready, :grace_expired}) do
    message =
      "cluster readiness: unjoined past boot grace — passing to avoid wedging the deploy; " <>
        "check Cloud Map A-records, ecs_task SG (EPMD 4369 + dist ports), RELEASE_COOKIE"

    # First observation of a sustained split logs at warning (drives the
    # alert); every probe after that (~8/min) would otherwise duplicate it,
    # so subsequent probes log at debug instead. A VM restart clears this
    # naturally (persistent_term is process-free but node-scoped).
    level =
      if :persistent_term.get(@grace_expired_logged_key, false) do
        :debug
      else
        :persistent_term.put(@grace_expired_logged_key, true)
        :warning
      end

    Logger.log(level, message, Engram.Logger.Metadata.with_category(level, :lifecycle, []))

    Map.put(checks, "cluster", "ok: unjoined_grace_expired")
  end

  defp put_cluster_check(checks, :waiting),
    do: Map.put(checks, "cluster", "waiting: cluster_unjoined")

  # diagnostics/2 is admin-gated in the router and intentionally excluded
  # from the public OpenAPI spec.
  operation(:diagnostics, false)

  # Full dependency matrix for humans + Grafana. Admin-gated in router.
  # BootCanary is reported by reading the :boot_canary_enabled config
  # rather than re-running the canary verify (which hits the DB on every
  # probe). If the canary was enabled at boot and the app is alive, the
  # guard's init/1 must have succeeded — so "verified" is sound.
  def diagnostics(conn, _params) do
    checks = %{
      "postgres" => check_postgres(),
      "qdrant" => check_qdrant(),
      "s3" => check_s3(),
      "kms" => check_kms(),
      "voyage" => check_voyage(),
      "paddle" => check_paddle(),
      "clerk_jwks" => check_clerk_jwks()
    }

    boot_canary =
      if Application.get_env(:engram, :boot_canary_enabled, true),
        do: "verified",
        else: "disabled"

    json(conn, %{checks: checks, boot_canary: boot_canary})
  end

  # T3.0.1 follow-up — never `inspect/1` an error reason into a JSON
  # response body. Postgrex / Mint structs interpolated via inspect can
  # carry connection strings, hostnames, or dependency-internal shapes.
  # `format_error/1` keeps the message low-cardinality and predictable.

  defp check_postgres do
    case Ecto.Adapters.SQL.query(Engram.Repo, "SELECT 1", []) do
      {:ok, _} -> "ok"
      {:error, reason} -> "error: #{format_error(reason)}"
    end
  rescue
    e -> "error: #{Exception.message(e)}"
  end

  defp check_qdrant do
    qdrant_url = Application.get_env(:engram, :qdrant_url, "http://localhost:6333")

    case Req.get("#{qdrant_url}/healthz", receive_timeout: 5_000, retry: false) do
      {:ok, %{status: status}} when status in 200..299 -> "ok"
      {:ok, %{status: status}} -> "error: status #{status}"
      {:error, reason} -> "error: #{format_error(reason)}"
    end
  rescue
    e -> "error: #{Exception.message(e)}"
  end

  defp check_s3 do
    case Application.get_env(:engram, :storage_bucket) do
      nil ->
        "error: missing_config"

      bucket ->
        case ExAws.S3.head_bucket(bucket) |> ExAws.request() do
          {:ok, _} -> "ok"
          {:error, reason} -> "error: #{format_error(reason)}"
        end
    end
  rescue
    e -> "error: #{Exception.message(e)}"
  end

  # KMS reachability is proven at boot via BootCanary (wrap+unwrap
  # round-trip through the CMK). Re-running it here on every probe is
  # expensive and changes nothing; if the app is alive, boot passed.
  defp check_kms do
    case Application.get_env(:engram, :key_provider) do
      :aws_kms -> "verified_at_boot"
      :local -> "skipped: provider=local"
      _other -> "skipped: provider=unknown"
    end
  end

  defp check_voyage do
    if System.get_env("VOYAGE_API_KEY"),
      do: "configured",
      else: "error: missing_env VOYAGE_API_KEY"
  end

  defp check_paddle do
    if System.get_env("PADDLE_API_KEY"),
      do: "configured",
      else: "error: missing_env PADDLE_API_KEY"
  end

  defp check_clerk_jwks do
    if System.get_env("CLERK_JWKS_URL"),
      do: "configured",
      else: "error: missing_env CLERK_JWKS_URL"
  end

  defp format_error(%{__exception__: true} = e), do: Exception.message(e)
end
