defmodule EngramWeb.TelemetryController do
  @moduledoc """
  Ingest for client-reported trace beacons. Authed but untrusted: every entry
  is sanitized (`BeaconSanitizer`) before it is materialized as a span
  (`ClientSpan`). No-ops when tracing is off. Rate-limited per user.
  """
  use EngramWeb, :controller

  alias Engram.Observability.{BeaconSanitizer, ClientSpan, Otel}

  @max_per_request 20
  @rate_limit_per_min 60
  @rate_scale_ms 60_000

  def create(conn, %{"spans" => spans}) when is_list(spans) do
    cond do
      not Otel.enabled?() ->
        send_resp(conn, 204, "")

      length(spans) > @max_per_request ->
        conn |> put_status(422) |> json(%{error: "too_many_spans"})

      rate_limited?(conn) ->
        conn |> put_status(429) |> json(%{error: "rate_limited"})

      true ->
        now_us = System.system_time(:microsecond)

        accepted =
          spans
          |> Enum.map(&BeaconSanitizer.sanitize(&1, now_us))
          |> Enum.count(fn
            {:ok, entry} -> ClientSpan.record(entry) == :ok
            {:error, _} -> false
          end)

        conn |> put_status(202) |> json(%{accepted: accepted})
    end
  end

  def create(conn, _params), do: conn |> put_status(422) |> json(%{error: "bad_request"})

  defp rate_limited?(conn) do
    user_id = conn.assigns.current_user.id

    case EngramWeb.RateLimiter.hit(
           "telemetry_spans:#{user_id}",
           @rate_scale_ms,
           @rate_limit_per_min,
           :other
         ) do
      {:allow, _} -> false
      {:deny, _} -> true
    end
  end
end
