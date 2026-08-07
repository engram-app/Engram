defmodule EngramWeb.TelemetryControllerTest do
  use EngramWeb.ConnCase, async: false

  # Timestamps must be computed per call, not in a module attribute: a
  # module attribute is frozen at compile time, and CI reuses a mix.lock-keyed
  # _build cache, so a stale compile-time timestamp would trip the sanitizer's
  # 300s clock-skew guard on cache-hit runs and flake this file.
  defp valid_span do
    now = System.system_time(:microsecond)

    %{
      "trace_id" => "11111111111111111111111111111111",
      "parent_span_id" => "2222222222222222",
      "name" => "obsidian.push",
      "start_us" => now,
      "end_us" => now + 5_000,
      "attributes" => %{"engram.surface" => "obsidian"}
    }
  end

  setup :authed_api_conn

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    :ok
  end

  defp enable_otel do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318")
    on_exit(fn -> System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT") end)
  end

  test "accepts a valid beacon batch", %{conn: conn} do
    enable_otel()

    conn = post(conn, ~p"/api/telemetry/spans", %{"spans" => [valid_span()]})
    assert json_response(conn, 202)["accepted"] == 1
  end

  test "drops malformed entries but accepts the batch", %{conn: conn} do
    enable_otel()

    bad = Map.put(valid_span(), "trace_id", "nope")
    conn = post(conn, ~p"/api/telemetry/spans", %{"spans" => [valid_span(), bad]})
    assert json_response(conn, 202)["accepted"] == 1
  end

  test "no-ops (204) when OTEL disabled", %{conn: conn} do
    System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT")

    conn = post(conn, ~p"/api/telemetry/spans", %{"spans" => [valid_span()]})
    assert response(conn, 204)
  end

  test "rejects a batch larger than the per-request cap", %{conn: conn} do
    enable_otel()

    spans = List.duplicate(valid_span(), 21)
    conn = post(conn, ~p"/api/telemetry/spans", %{"spans" => spans})
    assert json_response(conn, 422)
  end

  test "rate-limits after too many requests", %{conn: conn} do
    enable_otel()

    # The limiter is a FIXED window: 60 hits / 60_000 ms, Hammer ETS bucketed
    # by div(now_ms, scale_ms). Firing exactly 60 requests and asserting the
    # 61st denies assumes the whole loop lands in ONE bucket. When it straddles
    # a minute boundary the counter resets mid-loop and the 61st request is
    # legitimately allowed — so the test failed on a limiter that was working
    # correctly. Allowing up to 2x the limit across a boundary is inherent to
    # fixed windows, not a bug; the false assumption was in this test.
    #
    # Drive until the limiter actually denies. Bounded well above 2x the limit
    # so a limiter that never denies fails the test instead of hanging.
    denied =
      Enum.reduce_while(1..200, nil, fn _, _ ->
        resp = post(conn, ~p"/api/telemetry/spans", %{"spans" => [valid_span()]})
        if resp.status == 429, do: {:halt, resp}, else: {:cont, nil}
      end)

    assert denied, "limiter never denied within 200 requests (limit is 60/min)"
    assert json_response(denied, 429) == %{"error" => "rate_limited"}
  end
end
