defmodule Engram.Logger.MetadataTest do
  use ExUnit.Case, async: true
  alias Engram.Logger.Metadata
  require OpenTelemetry.Tracer, as: Tracer

  test "stamps category and computed loki_ship for an info business event" do
    meta = Metadata.with_category(:info, :billing, paddle_subscription_id: "sub_1")
    assert meta[:category] == :billing
    assert meta[:loki_ship] == true
    assert meta[:paddle_subscription_id] == "sub_1"
  end

  test "routine info is tagged loki_ship false" do
    meta = Metadata.with_category(:info, :http, status: 200)
    assert meta[:loki_ship] == false
  end

  test "error always loki_ship true" do
    meta = Metadata.with_category(:error, :http, status: 500)
    assert meta[:loki_ship] == true
  end

  # Fluent Bit routes to Loki on plain STRING compares over the parsed record
  # (envs/prod/fluent-bit/firelens.conf); it never reads the `loki_ship`
  # BOOLEAN. Until `:ship` existed, every per-entry override at :info level was
  # silently dropped — the verbose client-diagnostics dial and
  # `expected_client_status` both shipped nothing for months
  # (engram-app/engram-infra#1095).
  test "ship_to_loki/1 sets the routing string as well as the boolean" do
    forced = Metadata.ship_to_loki(category: :client, loki_ship: false)
    assert forced[:loki_ship] == true
    assert forced[:ship] == "loki"
  end

  # Deliberately NOT stamped by with_category/3. The category defaults are
  # already matched by the config's severity + category rules; stamping :ship
  # on them too would widen those rules by side effect (:info + :websocket
  # ships per Category and is absent from the config's list, so it would start
  # flowing to a billed-on-ingest Loki with nobody deciding to).
  test "with_category/3 does NOT stamp the override string" do
    shipped = Metadata.with_category(:info, :billing, [])
    assert shipped[:loki_ship] == true
    refute Keyword.has_key?(shipped, :ship)

    dropped = Metadata.with_category(:info, :http, status: 200)
    assert dropped[:loki_ship] == false
    refute Keyword.has_key?(dropped, :ship)
  end

  # The anti-drift claim has to be enforced, not just asserted in prose: a bare
  # `Keyword.put(meta, :loki_ship, true)` anywhere reproduces the original
  # silent no-op with nothing failing. Metadata is the only module allowed to
  # write either field.
  test "no module outside Metadata writes :loki_ship or :ship directly" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(&String.ends_with?(&1, "logger/metadata.ex"))
      |> Enum.filter(fn f ->
        src = File.read!(f)

        String.contains?(src, "Keyword.put(meta, :loki_ship") or
          String.contains?(src, "Keyword.put(metadata, :loki_ship") or
          String.contains?(src, "Keyword.put(meta, :ship") or
          String.contains?(src, ":ship, \"loki\"")
      end)

    assert offenders == [],
           "write the routing fields via Metadata.ship_to_loki/1: #{inspect(offenders)}"
  end

  test "raises on unknown category to catch typos at the call site" do
    assert_raise ArgumentError, fn -> Metadata.with_category(:info, :nonsense, []) end
  end

  describe "with_category/3 trace correlation" do
    # NOTE: the task brief specified :websocket as the category, but that
    # atom does not exist in Engram.Logger.Category on this branch (it only
    # exists on the separate, unmerged origin/feat/ws-conn-tracing branch,
    # commit efc17bc0). Adding it here would require editing category.ex,
    # which is outside this task's file scope. Using :sync instead: it's an
    # existing valid category and is the one already used by the real-time
    # channel/websocket code in this branch (see crdt_channel.ex).
    test "adds hex trace_id and span_id when inside a span" do
      Tracer.with_span "test-span" do
        md = Metadata.with_category(:info, :sync, [])
        assert md[:trace_id] =~ ~r/\A[0-9a-f]{32}\z/
        assert md[:span_id] =~ ~r/\A[0-9a-f]{16}\z/
      end
    end

    test "omits trace_id/span_id when there is no active span" do
      md = Metadata.with_category(:info, :sync, [])
      refute Keyword.has_key?(md, :trace_id)
      refute Keyword.has_key?(md, :span_id)
    end
  end
end
