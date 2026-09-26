defmodule Engram.Logger.ExceptionEgressTest do
  @moduledoc """
  Egress canary: a crash over a PLAIN term (a client payload map, not a
  redacted struct) must not carry the term out of the process through any sink
  that renders exceptions.

  `MatchError`, `CaseClauseError`, `KeyError`, `Oban.PerformError` and friends
  build their message from `inspect(term)`. `RedactFilter` gates metadata keys
  and never sees message text, and `redact: true` only covers structs. So every
  sink that formats an exception applies the one allowlist
  (`Engram.Logger.Metadata.safe_reason/1`) at the point the text is produced.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Engram.Logger.RedactedError
  alias Engram.Logger.SafeException

  @canary "Medical/canary-e61f.md"

  defp payload, do: %{"path" => @canary, "update" => Base.encode64(@canary)}

  defp raised(fun) do
    fun.()
  rescue
    e -> {e, __STACKTRACE__}
  end

  defp match_error, do: raised(fn -> {:ok, _} = Function.identity({:error, payload()}) end)

  defp refute_canary(text) do
    refute text =~ "canary-e61f", "leaked the canary:\n#{text}"
    refute text =~ Base.encode64(@canary), "leaked the base64 payload:\n#{text}"
  end

  describe "SafeException.sanitize/1" do
    test "a term-carrying exception keeps its type name but not its term" do
      {e, _} = match_error()
      safe = SafeException.sanitize(e)

      assert %RedactedError{type: MatchError} = safe
      assert Exception.message(safe) =~ "MatchError"
      refute_canary(Exception.message(safe))
    end

    test "an allowlisted exception passes through unchanged" do
      e = %DBConnection.ConnectionError{message: "tcp recv: closed"}
      assert SafeException.sanitize(e) == e
    end

    test "a wrapped Oban reason keeps its safe tag" do
      e = %Oban.PerformError{message: inspect({:error, payload()}), reason: {:error, payload()}}
      safe = SafeException.sanitize(e)

      assert Exception.message(safe) =~ "Oban.PerformError"
      assert Exception.message(safe) =~ ":error"
      refute_canary(Exception.message(safe))
    end
  end

  describe "SafeException.sanitize_reason/1" do
    test "{exception, stacktrace} is sanitized and frame arguments are dropped" do
      {e, st} = raised(fn -> String.to_integer(@canary) end)
      {safe, safe_st} = SafeException.sanitize_reason({e, st})

      assert is_exception(safe)
      assert Enum.all?(safe_st, fn {_m, _f, arity, _loc} -> is_integer(arity) end)
      refute_canary(Exception.format(:error, safe, safe_st))
    end

    test "an Erlang error reason is normalized, then sanitized" do
      {_, st} = match_error()
      {safe, _} = SafeException.sanitize_reason({{:badmatch, payload()}, st})

      assert %RedactedError{type: MatchError} = safe
    end

    test "exit reasons keep their atom tags only" do
      assert SafeException.sanitize_reason(:normal) == :normal
      assert SafeException.sanitize_reason({:shutdown, :closed}) == {:shutdown, :closed}
      refute_canary(inspect(SafeException.sanitize_reason({:shutdown, payload()})))
      refute_canary(inspect(SafeException.sanitize_reason(payload())))
    end
  end

  describe "crash reports (Loki text and Sentry crash_reason)" do
    defmodule Crasher do
      use GenServer

      def init(state), do: {:ok, state}

      # The shape a channel crash takes: a match over the client payload.
      def handle_info({:crdt_create, payload}, state) do
        %{"path" => "Expected/" <> _} = payload
        {:noreply, state}
      end
    end

    defp capture_crash(start) do
      capture_log([metadata: [:crash_reason]], fn ->
        {pid, ref} = start.()
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      end)
    end

    test "a GenServer crash over a payload map" do
      log =
        capture_crash(fn ->
          {:ok, pid} = GenServer.start(Crasher, nil)
          ref = Process.monitor(pid)
          send(pid, {:crdt_create, payload()})
          {pid, ref}
        end)

      assert log =~ "terminating"
      assert log =~ "MatchError"
      refute_canary(log)
    end

    test "a Task crash over a payload map" do
      log =
        capture_crash(fn ->
          {:ok, pid} = Task.start(fn -> Map.fetch!(payload(), "missing-#{@canary}") end)
          {pid, Process.monitor(pid)}
        end)

      assert log =~ "KeyError"
      refute_canary(log)
    end

    # Plain `spawn` reports through the emulator's "Error in process" format
    # message, delivered asynchronously after the process is already gone, so
    # this drives the translator directly. It also covers the `crash_reason`
    # metadata Sentry's LoggerHandler turns into the reported exception.
    # (proc_lib/supervisor reports are SASL-domain, dropped before translation
    # while `handle_sasl_reports` is off.)
    test "a bare spawn crash over a payload map" do
      {_e, st} = match_error()
      format = ~c"Error in process ~p with exit value:~n~p~n"

      assert {:ok, msg, meta} =
               Engram.Logger.SafeTranslator.translate(
                 :info,
                 :error,
                 :format,
                 {format, [self(), {{:badmatch, payload()}, st}]}
               )

      assert IO.iodata_to_binary(msg) =~ "MatchError"
      refute_canary(IO.iodata_to_binary(msg))
      refute_canary(inspect(meta[:crash_reason]))
    end
  end

  describe "HTTP request crashes (Bandit)" do
    test "Bandit's own exception log is off, so its raw Exception.format never runs" do
      http = Application.fetch_env!(:engram, EngramWeb.Endpoint)[:http]
      assert http[:http_options][:log_exceptions_with_status_codes] == []
    end

    test "our replacement logs the type and location, never the term" do
      {e, st} = match_error()

      log =
        capture_log(fn ->
          EngramWeb.RequestExceptionLogger.handle_event(
            [:bandit, :request, :exception],
            %{},
            %{kind: :error, exception: e, stacktrace: st},
            nil
          )
        end)

      assert log =~ "MatchError"
      assert log =~ "exception_egress_test.exs"
      refute_canary(log)
    end

    test "a 4xx exception (not a server error) is not logged" do
      e = %Phoenix.Router.NoRouteError{conn: nil, router: EngramWeb.Router, plug_status: 404}

      log =
        capture_log(fn ->
          EngramWeb.RequestExceptionLogger.handle_event(
            [:bandit, :request, :exception],
            %{},
            %{kind: :error, exception: e, stacktrace: []},
            nil
          )
        end)

      assert log == ""
    end
  end

  describe "Oban errors column" do
    test "prod config routes jobs through the sanitizing engine" do
      assert Application.fetch_env!(:engram, Oban)[:engine] == Engram.Oban.SafeEngine
    end

    test "the engine implements every Oban.Engines.Basic callback" do
      for {fun, arity} <- Oban.Engines.Basic.__info__(:functions),
          {fun, arity} in Oban.Engine.behaviour_info(:callbacks) do
        assert function_exported?(Engram.Oban.SafeEngine, fun, arity),
               "SafeEngine is missing #{fun}/#{arity}"
      end
    end

    test "the stored error keeps type and location, not the term" do
      {e, st} = match_error()
      job = %Oban.Job{attempt: 1, unsaved_error: %{kind: :error, reason: e, stacktrace: st}}

      %{error: stored} = job |> Engram.Oban.SafeEngine.sanitize_job() |> Oban.Job.format_attempt()

      assert stored =~ "MatchError"
      assert stored =~ "exception_egress_test.exs"
      refute_canary(stored)
    end

    test "a {:error, reason} return keeps its tag" do
      reason = {:error, payload()}
      e = Oban.PerformError.exception({Engram.Workers.EmbedNote, reason})
      job = %Oban.Job{attempt: 1, unsaved_error: %{kind: :error, reason: e, stacktrace: []}}

      %{error: stored} = job |> Engram.Oban.SafeEngine.sanitize_job() |> Oban.Job.format_attempt()

      assert stored =~ ":error"
      refute_canary(stored)
    end
  end
end
