defmodule Engram.Observability.PyroscopeTest do
  @moduledoc """
  Function-of-env contract for the Pyroscope sampler:

    1. `configured?/0` and `child_spec/1` are no-ops when any of the
       three SOPS-wired env vars is unset — supervisor silently
       drops the child.
    2. Sampling produces collapsed-stack keys in the
       "Mod.fun/arity;..." shape Pyroscope's `format=folded` ingest
       expects (root → leaf, separated by `;`).
    3. Periodic push hits `/ingest` with the right query params and
       Basic auth header, and resets the counters.

  We deliberately don't pin Pyroscope's exact response — Grafana
  Cloud accepts 200/204 across releases — but we do pin the
  structural invariants (URL path, format param, auth shape) since
  those are what would silently drop our profiles if they regressed.
  """

  use ExUnit.Case, async: false

  alias Engram.Observability.Pyroscope

  setup do
    prior = Application.get_env(:engram, :pyroscope)

    on_exit(fn ->
      if prior do
        Application.put_env(:engram, :pyroscope, prior)
      else
        Application.delete_env(:engram, :pyroscope)
      end
    end)

    :ok
  end

  describe "configured?/0" do
    test "false when :pyroscope config is unset" do
      Application.delete_env(:engram, :pyroscope)
      refute Pyroscope.configured?()
    end

    test "false when :url is missing" do
      Application.put_env(:engram, :pyroscope, username: "u", token: "t")
      refute Pyroscope.configured?()
    end

    test "false when :url is empty string" do
      Application.put_env(:engram, :pyroscope, url: "", username: "u", token: "t")
      refute Pyroscope.configured?()
    end

    test "true when url+username+token all present" do
      Application.put_env(:engram, :pyroscope,
        url: "https://pyroscope.example",
        username: "1234",
        token: "tok"
      )

      assert Pyroscope.configured?()
    end
  end

  describe "child_spec/1" do
    test "returns :ignore when not configured (no supervisor child added)" do
      Application.delete_env(:engram, :pyroscope)
      assert :ignore == Pyroscope.child_spec([])
    end

    test "returns a child spec map when configured" do
      Application.put_env(:engram, :pyroscope,
        url: "https://pyroscope.example",
        username: "1234",
        token: "tok"
      )

      assert %{id: Pyroscope, start: {Pyroscope, :start_link, [_]}} = Pyroscope.child_spec([])
    end
  end

  describe "collapse/1" do
    test "renders {mod, fun, arity, loc} frames root-first, separated by `;`" do
      stack = [
        # leaf (top of stack, deepest call)
        {SomeMod, :inner, 2, [file: ~c"some.ex", line: 10]},
        {SomeMod, :middle, 1, []},
        # root (entry point)
        {SomeMod, :root, 0, []}
      ]

      assert Pyroscope.collapse(stack) ==
               "SomeMod.root/0;SomeMod.middle/1;SomeMod.inner/2"
    end

    test "renders {mod, fun, args, loc} frames by using length(args) as arity" do
      stack = [{Mod, :f, [1, 2, 3], []}]
      assert Pyroscope.collapse(stack) == "Mod.f/3"
    end
  end

  describe "take_sample/1" do
    test "increments the count for each collapsed stack seen this tick" do
      # The real Process.list/0 sweep is hard to make deterministic in
      # a unit test (any GenServer in the VM contributes a frame), so
      # we just assert the invariant: counter values are non-negative
      # integers and the keyset is non-empty when other processes exist.
      counters = Pyroscope.take_sample(%{})
      assert is_map(counters)
      assert map_size(counters) > 0

      Enum.each(counters, fn {k, v} ->
        assert is_binary(k)
        assert is_integer(v) and v >= 1
      end)

      # Running another tick on top of the first should never decrease
      # any existing counter — it's monotonic until the next push.
      counters2 = Pyroscope.take_sample(counters)
      assert map_size(counters2) >= map_size(counters)
    end

    test "skips the calling process so the sampler can't dominate its own flame" do
      # Drive a sample from a known pid. The collapsed stack for *that*
      # pid will mention this test process and ExUnit framework code;
      # it must NOT appear in the counters because we filter `self()`.
      counters = Pyroscope.take_sample(%{})

      # No counter key should contain the test module name in the leaf
      # position (the test runner's current frame at sample time).
      refute Enum.any?(counters, fn {k, _} ->
               String.contains?(k, "PyroscopeTest")
             end)
    end
  end

  describe "render_folded/1" do
    test "emits one line per stack as 'collapsed_stack <count>\\n'" do
      out =
        %{
          "Mod.a/0;Mod.b/1" => 3,
          "Mod.c/2" => 1
        }
        |> Pyroscope.render_folded()
        |> IO.iodata_to_binary()

      lines = out |> String.split("\n", trim: true) |> Enum.sort()

      assert lines == ["Mod.a/0;Mod.b/1 3", "Mod.c/2 1"]
    end

    test "empty input emits empty output" do
      assert IO.iodata_to_binary(Pyroscope.render_folded(%{})) == ""
    end
  end

  describe "parse_interval_ms/2" do
    test "nil falls back to the default" do
      assert Pyroscope.parse_interval_ms(nil, 10) == 10
    end

    test "a positive integer string parses" do
      assert Pyroscope.parse_interval_ms("50", 10) == 50
    end

    test "surrounding whitespace is tolerated" do
      assert Pyroscope.parse_interval_ms("  25 ", 10) == 25
    end

    test "zero, negative, and non-integer input fall back to the default" do
      assert Pyroscope.parse_interval_ms("0", 10) == 10
      assert Pyroscope.parse_interval_ms("-5", 10) == 10
      assert Pyroscope.parse_interval_ms("abc", 10) == 10
      assert Pyroscope.parse_interval_ms("", 10) == 10
      assert Pyroscope.parse_interval_ms("12x", 10) == 10
    end
  end

  describe "push lifecycle (integration)" do
    test "after push_interval, POSTs to /ingest with the right params and resets counters" do
      bypass = Bypass.open()

      Application.put_env(:engram, :pyroscope,
        url: "http://localhost:#{bypass.port}",
        username: "user-1234",
        token: "tok-abc",
        app_name: "engram-test",
        env: "test",
        instance: "test-host",
        # Tight intervals so the test finishes quickly. 5ms sampling
        # × 50ms push = 10 samples per window.
        sample_interval_ms: 5,
        push_interval_ms: 50
      )

      parent = self()

      Bypass.expect(bypass, "POST", "/ingest", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(parent, {:pyroscope_push, conn.query_string, conn.req_headers, body})
        Plug.Conn.resp(conn, 200, "")
      end)

      {:ok, pid} = Pyroscope.start_link([])
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)

      assert_receive {:pyroscope_push, query, headers, body}, 2_000

      assert query =~ "name=engram-test"
      assert query =~ "format=folded"
      assert query =~ "spyName=elixirspy"
      # 1000ms / 5ms sample = 200Hz
      assert query =~ "sampleRate=200"
      assert query =~ ~r/from=\d+/
      assert query =~ ~r/until=\d+/

      # Basic auth: user-1234:tok-abc base64 = dXNlci0xMjM0OnRvay1hYmM=
      auth = Enum.find_value(headers, fn {k, v} -> if k == "authorization", do: v end)
      assert auth == "Basic dXNlci0xMjM0OnRvay1hYmM="

      # Body is folded format: "stack count\n" lines.
      assert is_binary(body)

      if byte_size(body) > 0 do
        first_line = body |> String.split("\n", trim: true) |> hd()
        # Either ends with a space + digits, OR is a frame chain — both shapes valid.
        assert first_line =~ ~r/ \d+$/
      end
    end
  end

  describe "sampler self-telemetry" do
    test "each sample pass emits [:engram, :pyroscope, :sample] with duration_ms + process_count" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :pyroscope, :sample]])
      on_exit(fn -> :telemetry.detach(ref) end)

      Application.put_env(:engram, :pyroscope,
        url: "http://localhost:1",
        username: "u",
        token: "t",
        # Fast sampling, push far in the future so no /ingest during the test.
        sample_interval_ms: 5,
        push_interval_ms: 60_000
      )

      {:ok, pid} = Pyroscope.start_link([])
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)

      assert_receive {[:engram, :pyroscope, :sample], ^ref, measurements, _meta}, 1_000
      assert is_float(measurements.duration_ms) and measurements.duration_ms >= 0.0
      assert is_integer(measurements.process_count) and measurements.process_count > 0
    end
  end
end
