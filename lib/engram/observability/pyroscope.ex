defmodule Engram.Observability.Pyroscope do
  @moduledoc """
  Continuous BEAM CPU profiler that pushes collapsed-stack samples to
  Grafana Cloud Pyroscope.

  ## Why a custom sampler, not a Hex package

  There is no maintained Hex package for BEAM → Pyroscope in 2026:

    * `hauleth/pyroscope_otp` / `erlang-pyroscope` are unmaintained
      (no commits in years) and predate Pyroscope's current ingest API.
    * Grafana ships official agents for Go/Java/Python/Ruby/.NET/Node/Rust
      and an eBPF profiler, but no BEAM-native client.
    * `eflambe` is BEAM-aware but designed for ad-hoc profiling, not
      continuous push — wrapping it would mean tearing down/restoring
      tracing every push interval.

  So we walk the same path the unmaintained libs did, talking to the
  Pyroscope HTTP `/ingest` endpoint directly. The implementation is
  tiny — a sampler GenServer, no NIF, no extra deps (Req is already
  in the tree).

  ## How it samples

  Every 10ms we walk `Process.list/0` and grab each process's
  `:current_stacktrace`. For every sample we increment a counter
  keyed by the collapsed stack (`mod:fun/arity;mod:fun/arity;...`).
  After a configurable window (default 10s) we serialize the
  accumulator as Pyroscope's `folded` (collapsed-stack) text format
  and POST it to `${GRAFANA_PYROSCOPE_URL}/ingest`. Counters reset
  on push.

  Sampling at 100Hz across N processes yields N×100 samples/sec.
  Pyroscope normalizes via the `sampleRate=100` query param so flame
  widths read as wall-clock proportions, not raw counts.

  ## What's profiled

  * Wall-clock CPU (`process_info(:current_stacktrace)` returns the
    process's instantaneous frame whether it's running on a scheduler
    or parked in a receive — Pyroscope's flame graphs treat them
    uniformly).

  Off-CPU and memory profiles are deferred (not landed in v1). They
  need different sampling strategies (`erlang:process_info(:memory)`
  diff for memory, separate scheduler-state filter for off-CPU) and
  separate `name=engram.{cpu,memory,offcpu}` series; track in a
  follow-up.

  ## Tags / labels

  Pushed as `name=engram-saas-prod{service=engram,env=prod,instance=<hostname>}`.
  We deliberately do NOT tag per-tenant — profile storage cardinality
  explodes on high-cardinality labels and Grafana Cloud charges for it.

  ## No-op when unconfigured

  When `GRAFANA_PYROSCOPE_URL` is unset (dev, test, self-host), the
  GenServer is not added to the supervision tree at all (see
  `Engram.Application`). The `child_spec/1` callback returns
  `:ignore` to make that decision composable.
  """

  use GenServer

  alias Engram.Logger.Metadata

  require Logger

  # 100Hz CPU sampling — matches the convention every Pyroscope agent
  # uses, so flame widths read directly as a fraction of wall-clock
  # CPU time (1 sample ≈ 10ms of work).
  @default_sample_interval_ms 10

  # Push every 10s. Pyroscope's UI buckets profiles at this granularity
  # by default; shorter pushes increase ingest volume without UI win.
  @default_push_interval_ms 10_000

  @default_app_name "engram-saas-prod"
  @default_spy_name "elixirspy"
  @default_units "samples"

  # Profile types we ship in v1 (CPU only). Off-CPU + memory deferred.
  @profile_kind "cpu"

  defstruct [
    :url,
    :username,
    :token,
    :app_name,
    :tags,
    :sample_interval_ms,
    :push_interval_ms,
    :spy_name,
    :sample_rate,
    :window_started_at_ms,
    :sample_timer_ref,
    :push_timer_ref,
    counters: %{}
  ]

  # ── Public API ────────────────────────────────────────────────────

  @doc """
  Build a child spec. Returns `:ignore` (a valid supervisor child
  result) when the URL is unset, so `Engram.Application` can just
  list us unconditionally.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec() | :ignore
  def child_spec(opts) do
    if configured?() do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]},
        restart: :permanent,
        shutdown: 5_000,
        type: :worker
      }
    else
      :ignore
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns true when the prod env vars are present. Used by
  `Engram.Application` to decide whether to add the worker.
  """
  @spec configured?() :: boolean()
  def configured? do
    case Application.get_env(:engram, :pyroscope) do
      cfg when is_list(cfg) ->
        is_binary(Keyword.get(cfg, :url)) and
          Keyword.get(cfg, :url) != "" and
          is_binary(Keyword.get(cfg, :username)) and
          is_binary(Keyword.get(cfg, :token))

      _ ->
        false
    end
  end

  @doc """
  Parse a millisecond interval from an env var string. Returns the
  default for nil, blank, non-integer, or non-positive input so a
  fat-fingered env value can never disable or invert the timer.
  """
  @spec parse_interval_ms(String.t() | nil, pos_integer()) :: pos_integer()
  def parse_interval_ms(nil, default) when is_integer(default) and default > 0, do: default

  def parse_interval_ms(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  # ── GenServer callbacks ───────────────────────────────────────────

  @impl true
  def init(opts) do
    cfg = Application.get_env(:engram, :pyroscope, [])

    sample_interval =
      Keyword.get(
        opts,
        :sample_interval_ms,
        Keyword.get(cfg, :sample_interval_ms, @default_sample_interval_ms)
      )

    push_interval =
      Keyword.get(
        opts,
        :push_interval_ms,
        Keyword.get(cfg, :push_interval_ms, @default_push_interval_ms)
      )

    state = %__MODULE__{
      url: String.trim_trailing(Keyword.fetch!(cfg, :url), "/"),
      username: Keyword.fetch!(cfg, :username),
      token: Keyword.fetch!(cfg, :token),
      app_name: Keyword.get(cfg, :app_name, @default_app_name),
      tags: build_tags(cfg),
      sample_interval_ms: sample_interval,
      push_interval_ms: push_interval,
      spy_name: Keyword.get(cfg, :spy_name, @default_spy_name),
      sample_rate: div(1_000, sample_interval),
      window_started_at_ms: now_ms(),
      sample_timer_ref: nil,
      push_timer_ref: nil,
      counters: %{}
    }

    Logger.debug(
      "pyroscope profiler started: app=#{state.app_name} sample_interval_ms=#{sample_interval} push_interval_ms=#{push_interval}",
      Metadata.with_category(:debug, :boot, [])
    )

    {:ok, schedule_both(state)}
  end

  @impl true
  def handle_info(:sample, state) do
    process_count = length(Process.list())
    {duration_us, counters} = :timer.tc(fn -> take_sample(state.counters) end)

    :telemetry.execute(
      [:engram, :pyroscope, :sample],
      %{duration_ms: duration_us / 1_000, process_count: process_count},
      %{}
    )

    {:noreply, %{state | counters: counters, sample_timer_ref: schedule_sample(state)}}
  end

  @impl true
  def handle_info(:push, state) do
    {counters_to_push, window_started_at_ms} = {state.counters, state.window_started_at_ms}
    push_window_end_ms = now_ms()

    spawn(fn ->
      do_push(state, counters_to_push, window_started_at_ms, push_window_end_ms)
    end)

    new_state = %{
      state
      | counters: %{},
        window_started_at_ms: push_window_end_ms,
        push_timer_ref: schedule_push(state)
    }

    {:noreply, new_state}
  end

  # ── Sampling ──────────────────────────────────────────────────────

  @doc false
  # Snapshot every process's current stacktrace and increment the
  # counter keyed by the collapsed stack. We skip our own pid so the
  # sampler doesn't profile itself dominating its own flame.
  @spec take_sample(map()) :: map()
  def take_sample(counters) do
    self_pid = self()

    Enum.reduce(Process.list(), counters, fn pid, acc ->
      if pid == self_pid do
        acc
      else
        case Process.info(pid, :current_stacktrace) do
          {:current_stacktrace, [_ | _] = stack} ->
            key = collapse(stack)
            Map.update(acc, key, 1, &(&1 + 1))

          _ ->
            acc
        end
      end
    end)
  end

  # Pyroscope "folded" / "collapsed stack" format: each *line* is one
  # stack, frames separated by ';', root frame on the left, leaf on
  # the right, followed by ' <count>'. We invert the BEAM stack so the
  # entry point reads first.
  @doc false
  @spec collapse([tuple()]) :: String.t()
  def collapse(stack) do
    stack
    |> Enum.reverse()
    |> Enum.map_join(";", &format_frame/1)
  end

  defp format_frame({mod, fun, arity, _loc}) when is_integer(arity) do
    "#{inspect(mod)}.#{fun}/#{arity}"
  end

  defp format_frame({mod, fun, args, _loc}) when is_list(args) do
    "#{inspect(mod)}.#{fun}/#{length(args)}"
  end

  defp format_frame(other), do: inspect(other)

  # ── Push to Pyroscope ─────────────────────────────────────────────

  @doc false
  @spec render_folded(map()) :: iolist()
  def render_folded(counters) do
    counters
    |> Enum.map(fn {stack, count} -> [stack, ?\s, Integer.to_string(count), ?\n] end)
  end

  defp do_push(_state, counters, _from, _until) when map_size(counters) == 0 do
    # Empty window — nothing to push. Happens during startup before
    # the first sample fires, or if every Process.list/0 frame was
    # filtered (unlikely outside tests).
    :ok
  end

  defp do_push(state, counters, from_ms, until_ms) do
    body = render_folded(counters)
    name_with_tags = "#{state.app_name}{#{state.tags}}"

    query = [
      {"name", name_with_tags},
      {"from", to_seconds(from_ms)},
      {"until", to_seconds(until_ms)},
      {"format", "folded"},
      {"spyName", state.spy_name},
      {"sampleRate", state.sample_rate},
      {"units", @default_units},
      {"aggregationType", "sum"},
      {"profileType", @profile_kind}
    ]

    url = state.url <> "/ingest"

    case Req.post(url,
           params: query,
           body: IO.iodata_to_binary(body),
           headers: [{"content-type", "text/plain"}],
           auth: {:basic, "#{state.username}:#{state.token}"},
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning(
          "pyroscope ingest rejected: status=#{status} body=#{inspect(resp_body)}",
          Metadata.with_category(:warning, :boot, [])
        )

      {:error, reason} ->
        Logger.warning(
          "pyroscope ingest failed: #{inspect(reason)}",
          Metadata.with_category(:warning, :boot, [])
        )
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp build_tags(cfg) do
    base = [
      {"service", "engram"},
      {"env", to_string(Keyword.get(cfg, :env, "prod"))},
      {"instance", Keyword.get(cfg, :instance, hostname())}
    ]

    Enum.map_join(base, ",", fn {k, v} -> ~s(#{k}="#{v}") end)
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
    end
  end

  defp schedule_both(state) do
    %{
      state
      | sample_timer_ref: schedule_sample(state),
        push_timer_ref: schedule_push(state)
    }
  end

  defp schedule_sample(state),
    do: Process.send_after(self(), :sample, state.sample_interval_ms)

  defp schedule_push(state),
    do: Process.send_after(self(), :push, state.push_interval_ms)

  defp now_ms, do: System.system_time(:millisecond)

  defp to_seconds(ms), do: div(ms, 1_000)
end
