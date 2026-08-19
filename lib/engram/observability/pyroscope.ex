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

  Every `PYROSCOPE_SAMPLE_INTERVAL_MS` (prod: 2000) we walk
  `Process.list/0` and grab each process's `:current_stacktrace`. For
  every sample we increment a counter keyed by the collapsed stack
  (`mod:fun/arity;mod:fun/arity;...`). After a configurable window
  (default 10s) we serialize the accumulator as Pyroscope's `folded`
  (collapsed-stack) text format and POST it to
  `${GRAFANA_PYROSCOPE_URL}/ingest`. Counters reset on push.

  ## Sample rate is measured, not assumed

  We always declare `sampleRate=100` and rescale counts to match (see
  `scale_counts/3`), rather than deriving the rate from the configured
  interval. Two reasons, both of which produced wrong flame graphs:

    * Pyroscope parses `sampleRate` as an **integer**. Prod samples at
      0.5Hz, so the honest rate is not expressible — `div(1000, 2000)`
      floors to `0`, and clamping that to `1` made every absolute time
      read 2x low.
    * The configured interval is not the achieved one. `schedule_sample/1`
      fires *after* a pass completes, so the real period is
      `interval + pass_duration`. At the old 50ms setting with a ~15ms
      pass that is 15.4Hz, not the 20Hz the code claimed — a 23% error.

  Scaling from `passes / measured_window` removes both. It also gives the
  sampler implicit backpressure for free: if passes get slower, fewer land
  in the window and the scale factor grows to compensate, instead of the
  profiler silently drifting off its own stated units.

  ## What's profiled

  * **On-CPU time only.** A pass samples a process's `:current_stacktrace`
    solely when its `:status` says it is using or contending for a scheduler
    (`@on_cpu_statuses`). Processes parked in a `receive` are skipped.

    This filter is load-bearing, not a refinement. `:current_stacktrace`
    answers just as readily for a process blocked in `receive`, so sampling
    unconditionally produces a census of *where processes are parked* — which,
    on a normal node, is overwhelmingly `:gen_server.loop/7` and
    `:prim_inet.accept0/3`. A 2026-08-18 investigation into a prod CPU
    saturation pulled a flame graph that was 74% `:gen_server.loop/7` and
    found nothing, because the real consumer was a few hundred samples deep
    under idle noise. Only frames a parked process cannot be in — a pure-CPU
    NIF, a tight `Enum.reduce` — survived, and only by luck.

    The cost of the filter is a thinner profile: on an idle node most passes
    now record nothing at all, which is the correct answer. A sparse honest
    profile is worth more than a dense misleading one.

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

  # 1Hz. NOT the 100Hz Pyroscope-agent convention, deliberately: those
  # agents sample via an OS signal timer and cost microseconds. We have no
  # such hook from the BEAM, so a pass walks Process.list/0 and calls
  # Process.info(:current_stacktrace) on every process — O(processes), and
  # measured at ~15ms against ~745 live processes in prod.
  #
  # At a 10ms default (the old value) that is ~60% of a vCPU, and the
  # sampler is slower than its own interval. A 2026-07-04 prod regression
  # at 50ms already cost ~23% of a vCPU sustained (ECS avg CPU 3% -> 38%)
  # and ran for hours. Prod now sets PYROSCOPE_SAMPLE_INTERVAL_MS=2000.
  #
  # This default only applies when the env var is absent, i.e. exactly the
  # misconfiguration that would otherwise pin a scheduler. Start safe; an
  # operator who wants resolution sets the env var deliberately.
  @default_sample_interval_ms 1_000

  # The sampleRate we DECLARE to Pyroscope, with counts scaled to match
  # (see scale_counts/4). Pyroscope's ingest API parses sampleRate as an
  # integer, so a sub-1Hz sampler cannot state its true rate — prod runs
  # 0.5Hz, div(1000, 2000) floors to 0, and the old `max(1, ...)` clamp
  # reported 1Hz. Every absolute time in the flame graph read 2x low.
  #
  # Declaring a fixed rate and scaling counts sidesteps the integer floor
  # entirely, and lets us derive the scale from the rate we ACTUALLY
  # achieved rather than the one we configured.
  @declared_sample_rate 100

  # Push every 10s. Pyroscope's UI buckets profiles at this granularity
  # by default; shorter pushes increase ingest volume without UI win.
  @default_push_interval_ms 10_000

  @default_app_name "engram-saas-prod"
  @default_spy_name "elixirspy"
  @default_units "samples"

  # Profile types we ship in v1 (CPU only). Off-CPU + memory deferred.
  @profile_kind "cpu"

  # Process states that mean "this stack is consuming or contending for a
  # scheduler". Everything else (`:waiting`, `:suspended`, `:exiting`) is a
  # process at rest, and counting it turns a CPU profile into a census of idle
  # receive loops — see the moduledoc.
  #
  #   :running            — on a scheduler right now
  #   :garbage_collecting — on a scheduler, doing GC; real CPU, and attributing
  #                         it to the stack that allocated is the useful reading
  #   :runnable           — ready but waiting for a free scheduler. Not strictly
  #                         on-CPU, but it is precisely the demand that saturates
  #                         a node, and dropping it would blind the profile to
  #                         the queued work during the exact incident it's for.
  @on_cpu_statuses [:running, :garbage_collecting, :runnable]

  defstruct [
    :url,
    :username,
    :token,
    :app_name,
    :tags,
    :sample_interval_ms,
    :push_interval_ms,
    :spy_name,
    :window_started_at_ms,
    :sample_timer_ref,
    :push_timer_ref,
    counters: %{},
    # Passes actually completed this window. Divided by the measured window
    # duration at push time to get the achieved sample rate — which is never
    # the configured one, because schedule_sample/1 fires AFTER the pass
    # completes, so the real period is interval + pass_duration.
    passes_in_window: 0
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
      window_started_at_ms: now_ms(),
      sample_timer_ref: nil,
      push_timer_ref: nil,
      counters: %{},
      passes_in_window: 0
    }

    Logger.debug(
      "pyroscope profiler started: app=#{state.app_name} sample_interval_ms=#{sample_interval} push_interval_ms=#{push_interval}",
      Metadata.with_category(:debug, :boot, [])
    )

    {:ok, schedule_both(state)}
  end

  @impl true
  def handle_info(:sample, state) do
    {duration_us, {counters, process_count}} = :timer.tc(fn -> take_sample(state.counters) end)

    :telemetry.execute(
      [:engram, :pyroscope, :sample],
      %{duration_ms: duration_us / 1_000, process_count: process_count},
      %{}
    )

    {:noreply,
     %{
       state
       | counters: counters,
         passes_in_window: state.passes_in_window + 1,
         sample_timer_ref: schedule_sample(state)
     }}
  end

  @impl true
  def handle_info(:push, state) do
    {counters_to_push, window_started_at_ms} = {state.counters, state.window_started_at_ms}
    passes = state.passes_in_window
    push_window_end_ms = now_ms()

    spawn(fn ->
      do_push(state, counters_to_push, passes, window_started_at_ms, push_window_end_ms)
    end)

    new_state = %{
      state
      | counters: %{},
        passes_in_window: 0,
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
  # Returns {counters, process_count}. The count rides out of the same
  # Process.list/0 walk that does the sampling — computing it separately
  # meant snapshotting the whole process table twice per pass purely to
  # feed a telemetry gauge.
  @spec take_sample(map()) :: {map(), non_neg_integer()}
  def take_sample(counters) do
    self_pid = self()

    Enum.reduce(Process.list(), {counters, 0}, fn pid, {acc, n} ->
      if pid == self_pid do
        {acc, n + 1}
      else
        case Process.info(pid, [:status, :current_stacktrace]) do
          [{:status, status}, {:current_stacktrace, [_ | _] = stack}]
          when status in @on_cpu_statuses ->
            key = collapse(stack)
            {Map.update(acc, key, 1, &(&1 + 1)), n + 1}

          _ ->
            {acc, n + 1}
        end
      end
    end)
  end

  @doc false
  # Rescale raw sample counts so `count / @declared_sample_rate` equals the
  # real wall-clock time that stack was observed for.
  #
  # Necessary because Pyroscope's ingest API takes sampleRate as an integer
  # and our real rate is often not one — prod samples at ~0.5Hz. Deriving
  # the scale from `passes / window_ms` rather than from the configured
  # interval also absorbs timer drift: schedule_sample/1 fires AFTER a pass
  # completes, so a 50ms interval with a 15ms pass runs at 15.4Hz, not 20Hz,
  # and the old code would have overstated the rate by 23%.
  #
  # max(1, ...) keeps a stack seen exactly once from rounding away to zero
  # and vanishing from the flame graph entirely.
  @spec scale_counts(map(), non_neg_integer(), integer()) :: map()
  def scale_counts(counters, passes, window_ms)
      when passes <= 0 or window_ms <= 0,
      do: counters

  def scale_counts(counters, passes, window_ms) do
    factor = @declared_sample_rate * (window_ms / 1_000) / passes

    Map.new(counters, fn {stack, count} -> {stack, max(1, round(count * factor))} end)
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

  defp do_push(_state, counters, _passes, _from, _until) when map_size(counters) == 0 do
    # Empty window — nothing to push. Happens during startup before the first
    # sample fires, and routinely on an idle node: since take_sample/1 only
    # records processes on (or contending for) a scheduler, a window in which
    # nothing ran yields no samples. A gap in the flame graph is then the
    # truthful answer ("no CPU was used"), not a dropped push.
    :ok
  end

  defp do_push(state, counters, passes, from_ms, until_ms) do
    body =
      counters
      |> scale_counts(passes, until_ms - from_ms)
      |> render_folded()

    name_with_tags = "#{state.app_name}{#{state.tags}}"

    query = [
      {"name", name_with_tags},
      {"from", to_seconds(from_ms)},
      {"until", to_seconds(until_ms)},
      {"format", "folded"},
      {"spyName", state.spy_name},
      {"sampleRate", @declared_sample_rate},
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
