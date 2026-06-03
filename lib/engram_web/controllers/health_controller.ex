defmodule EngramWeb.HealthController do
  use EngramWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok", version: Application.spec(:engram, :vsn) |> to_string()})
  end

  # ALB target group readiness probe. Only checks dependencies whose
  # absence makes EVERY request fail — Postgres is that one. Qdrant,
  # Redis, S3 etc. stay OUT so a single dep outage cannot pull all tasks
  # from rotation. Surface those via /api/health/diagnostics (auth-gated)
  # and per-dep CloudWatch/Grafana alarms.
  def deep(conn, _params) do
    checks = %{"postgres" => check_postgres()}
    all_ok = Enum.all?(checks, fn {_k, v} -> v == "ok" end)
    status = if all_ok, do: "ok", else: "degraded"
    http_status = if all_ok, do: 200, else: 503

    conn
    |> put_status(http_status)
    |> json(%{status: status, checks: checks})
  end

  # Full dependency matrix for humans + Grafana. Admin-gated in router.
  # BootCanary is reported by reading the :boot_canary_enabled config
  # rather than re-running the canary verify (which hits the DB on every
  # probe). If the canary was enabled at boot and the app is alive, the
  # guard's init/1 must have succeeded — so "verified" is sound.
  def diagnostics(conn, _params) do
    checks = %{
      "postgres" => check_postgres(),
      "qdrant" => check_qdrant(),
      "redis" => check_redis(),
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

  defp check_redis do
    case Engram.Cache.Redix.command(["PING"]) do
      {:ok, "PONG"} -> "ok"
      {:ok, _other} -> "error: unexpected_reply"
      {:error, reason} -> "error: #{format_error(reason)}"
    end
  rescue
    e -> "error: #{Exception.message(e)}"
  catch
    :exit, {:noproc, _} -> "error: not_started"
    :exit, _reason -> "error: exit"
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
