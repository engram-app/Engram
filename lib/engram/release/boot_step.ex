defmodule Engram.Release.BootStep do
  @moduledoc """
  The owner-run boot steps `Engram.Release.migrate/0` runs after the
  migrations, on the migrator connection and inside the migration lock
  (release K's `Engram.Release.FolderHashDrop`, release L's
  `Engram.Release.NotesPathExpand`; the list is `Engram.Release.boot_steps/0`).
  The shared shape lives here once:

    * a completion ledger per step (`Engram.DataMigrations`): a done step
      costs one read and runs nothing;
    * a kill switch per step, a flags-only boolean key, read from the flags
      source ONCE per boot for all steps (`Engram.ServiceConfig.Flags.read_once/2`,
      3 s budget: the reader has not started in the migrate eval), and only
      when some step is pending. Absent means the step's `default` (on unless
      the step says otherwise). Each pending step logs `<step> flags read
      source=<appconfig|file|none> value=<true|false|absent>` at info in the
      `:boot` category, which ships to Loki, so prod can prove the switch was
      read. An unreadable source is a warning and the default applies;
    * one pinned session per step holding a session advisory lock on the
      step's name (`pg_try_advisory_lock`): a step another session holds (an
      orphaned build of a killed task still running) is skipped this boot;
    * ONE time budget for all steps of a boot (#{15_000} ms by default): each
      statement's `statement_timeout` is what is left of it (at most
      #{15_000} ms), and a step that starts with under #{1_000} ms left defers
      without running. The migration lock serializes a deploy's tasks and a
      step that keeps deferring is redone by each, so the last of three waits
      for both others: 3 x `worst_case_ms/0` (about 69 s) must fit the ECS
      web health-check grace (120 s);
    * lock waits: ALTER TABLE statements (which queue writers behind them)
      run under a 5 s `lock_timeout`; CONCURRENTLY statements (which block no
      DML, and whose waits for older transactions are lock waits) run with no
      `lock_timeout`, bounded by the budget alone;
    * never fails boot: an error, a timeout, a raise or an exit is a
      `<step> deferred` warning, the ledger row stays open and the next boot
      retries. Each step is idempotent, so a rerun from any point is safe.
  """

  alias Engram.DataMigrations
  alias Engram.Logger.Metadata
  alias Engram.ServiceConfig.Flags

  require Logger

  @enforce_keys [:name, :version, :flag, :apply]
  defstruct @enforce_keys ++ [default: true]

  @typedoc """
  `apply` runs the step in its session (`t:session/0`): `:ok` (done, the
  ledger closes) or `{:defer, reason}` (left for the next boot). It may
  raise. `default` is the kill switch's value when the flag is absent.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          version: pos_integer(),
          flag: atom(),
          apply: (session() -> :ok | {:defer, term()}),
          default: boolean()
        }

  @typedoc "A step's pinned connection and the boot's deadline (monotonic ms)."
  @type session :: %{repo: module(), deadline: integer()}

  @type result :: :skipped | :disabled | :done | :deferred | :busy

  @flags_timeout_ms 3_000
  # LockTimeoutRetry's value (priv/repo/migrations/lock_timeout_retry.exs).
  @lock_timeout "5s"
  @budget_ms 15_000
  @max_statement_ms 15_000
  @min_statement_ms 1_000
  # A failed build's INVALID leftover is dropped even with the budget spent:
  # an invalid UNIQUE index still enforces uniqueness on writes.
  @cleanup_ms 5_000

  @doc """
  One task's longest boot-step time: the flags read, the budget, and one
  cleanup drop past it. The migration lock serializes a deploy's tasks, so
  the last of three can wait for two others before its own.
  """
  # No @spec: dialyzer's :underspecs flags `pos_integer()` against the literal.
  def worst_case_ms, do: @flags_timeout_ms + @budget_ms + @cleanup_ms

  @doc """
  Runs `steps` in order on `repo` (a migrator-credential repo) and returns
  `[{name, result}]`. One step's failure never stops the next. Never raises.
  `opts`: `:flags_timeout_ms`, `:budget_ms` (all steps together).
  """
  @spec run_all(module(), [t()], keyword()) :: [{String.t(), result()}]
  def run_all(repo, steps, opts \\ []) do
    timeout = Keyword.get(opts, :flags_timeout_ms, @flags_timeout_ms)
    deadline = now() + Keyword.get(opts, :budget_ms, @budget_ms)

    {results, _flags} =
      Enum.map_reduce(steps, :unread, fn step, flags ->
        {result, flags} = run_one(repo, step, flags, timeout, deadline)
        {{step.name, result}, flags}
      end)

    results
  end

  defp run_one(repo, step, flags, timeout, deadline) do
    if DataMigrations.done?(step.name, step.version) do
      {:skipped, flags}
    else
      flags = if flags == :unread, do: read_flags(timeout), else: flags

      result =
        cond do
          not enabled?(step, flags) -> :disabled
          deadline - now() < @min_statement_ms -> deferred(step, :boot_budget_spent)
          true -> apply_step(repo, step, deadline)
        end

      {result, flags}
    end
  rescue
    e -> {deferred(step, e), flags}
  catch
    kind, reason -> {deferred(step, {kind, reason}), flags}
  end

  defp apply_step(repo, step, deadline) do
    case in_session(repo, step, %{repo: repo, deadline: deadline}) do
      :ok ->
        :ok = DataMigrations.mark_done(step.name, step.version)

        Logger.info(
          "#{step.name} done",
          Metadata.with_category(:info, :boot, migration: step.name, version: step.version)
        )

        :done

      :busy ->
        Logger.info(
          "#{step.name} held by another session; the next boot retries",
          Metadata.with_category(:info, :boot, migration: step.name)
        )

        :busy

      {:defer, reason} ->
        deferred(step, reason)
    end
  end

  # One pinned connection: the advisory lock, then the session's lock and
  # statement bounds, reset afterwards. No checkout deadline: each statement
  # carries its own bound, and DBConnection's default would cover the block.
  defp in_session(repo, step, session) do
    repo.checkout(
      fn ->
        key = lock_key(step.name)

        case repo.query!("SELECT pg_try_advisory_lock($1)", [key], log: false) do
          %{rows: [[true]]} ->
            repo.query!("SET lock_timeout = '#{@lock_timeout}'")

            try do
              step.apply.(session)
            after
              repo.query!("RESET lock_timeout")
              repo.query!("RESET statement_timeout")
              repo.query!("SELECT pg_advisory_unlock($1)", [key], log: false)
            end

          _ ->
            :busy
        end
      end,
      timeout: :infinity
    )
  end

  @doc "The session advisory lock key of the step `name` (int4 range)."
  @spec lock_key(String.t()) :: integer()
  def lock_key(name), do: :erlang.phash2({__MODULE__, name}, 2_147_483_647)

  # {:ok, source label, flags} | :none | {:error, source label, reason}
  defp read_flags(timeout_ms) do
    case Application.get_env(:engram, :service_flags) do
      nil ->
        :none

      source ->
        # The migrate eval starts no app. The fetch needs Req (and its Finch
        # pool, which ex_aws's Req client shares) and ex_aws, whose AuthCache
        # holds the task-role credentials that sign the AppConfig call.
        _ = Application.ensure_all_started([:req, :ex_aws])

        case Flags.read_once(source, timeout_ms) do
          {:ok, flags} -> {:ok, source_label(source), flags}
          {:error, reason} -> {:error, source_label(source), reason}
        end
    end
  rescue
    e -> {:error, "unknown", e}
  catch
    kind, reason -> {:error, "unknown", {kind, reason}}
  end

  defp source_label({:appconfig, _}), do: "appconfig"
  defp source_label({:file, _}), do: "file"

  defp enabled?(step, :none), do: flags_read(step, "none", :absent)

  defp enabled?(step, {:ok, source, flags}),
    do: flags_read(step, source, Map.get(flags, step.flag, :absent))

  defp enabled?(step, {:error, _source, reason}) do
    Logger.warning(
      "#{step.name} flags unreadable; running with the default (#{on_off(step.default)})",
      Metadata.with_category(:warning, :boot, migration: step.name, reason: safe(reason))
    )

    step.default
  end

  # The positive proof the kill switch was read. Values are a boolean or
  # absent (the flags parser validates the type), so nothing logged is secret.
  defp flags_read(step, source, value) do
    Logger.info(
      "#{step.name} flags read source=#{source} value=#{value}",
      Metadata.with_category(:info, :boot, migration: step.name)
    )

    if value == :absent, do: step.default, else: value
  end

  defp on_off(true), do: "on"
  defp on_off(false), do: "off"

  @doc """
  Runs `statements` in order in the session; the first error stops the rest
  and comes back as `{:defer, error}`. `opts` as `query/4`.
  """
  @spec exec(session(), [String.t()], keyword()) :: :ok | {:defer, term()}
  def exec(session, statements, opts \\ []) do
    Enum.reduce_while(statements, :ok, fn sql, :ok ->
      case query(session, sql, [], opts) do
        {:ok, _} -> {:cont, :ok}
        {:error, e} -> {:halt, {:defer, e}}
      end
    end)
  end

  @doc """
  One statement under the session's bounds: `statement_timeout` is what is
  left of the boot budget (at most #{@max_statement_ms} ms); under
  #{@min_statement_ms} ms left it is not sent (`{:error, :boot_budget_spent}`).
  A CONCURRENTLY statement runs with no `lock_timeout` (it blocks no DML,
  and its waits for older transactions are lock waits a 5 s bound would turn
  into chronic deferrals); `cleanup: true` bounds it by #{@cleanup_ms} ms
  instead of the budget.
  """
  @spec query(session(), String.t(), list(), keyword()) :: {:ok, term()} | {:error, term()}
  def query(%{repo: repo} = session, sql, params \\ [], opts \\ []) do
    left =
      if Keyword.get(opts, :cleanup, false),
        do: @cleanup_ms,
        else: min(session.deadline - now(), @max_statement_ms)

    if left < @min_statement_ms do
      {:error, :boot_budget_spent}
    else
      concurrent = Regex.match?(~r/\bCONCURRENTLY\b/i, sql)
      repo.query!("SET statement_timeout = #{left}")
      if concurrent, do: repo.query!("SET lock_timeout = 0")

      try do
        repo.query(sql, params, timeout: left + 5_000)
      after
        if concurrent, do: repo.query!("SET lock_timeout = '#{@lock_timeout}'")
      end
    end
  end

  @doc """
  `:valid`, `:invalid` (a failed or killed CONCURRENTLY build: never done)
  or `:absent`, for the index `name` in the public schema.
  """
  @spec index_state(session(), String.t()) :: :valid | :invalid | :absent
  def index_state(%{repo: repo}, name) do
    %{rows: rows} =
      repo.query!(
        "SELECT i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = $1 AND n.nspname = 'public'",
        [name],
        log: false
      )

    case rows do
      [[true]] -> :valid
      [[false]] -> :invalid
      [] -> :absent
    end
  end

  @doc """
  Builds the index `name` (`create` is its `CREATE [UNIQUE] INDEX
  CONCURRENTLY IF NOT EXISTS` statement): a valid one is done; an INVALID
  one is dropped first; after the build it must read valid. A failed or
  timed-out build's INVALID leftover is dropped at once (an invalid UNIQUE
  index still enforces uniqueness on writes); if that drop fails too, the
  next attempt drops it before building.
  """
  @spec build_index(session(), String.t(), String.t()) :: :ok | {:defer, term()}
  def build_index(session, name, create) do
    case index_state(session, name) do
      :valid ->
        :ok

      state ->
        drop = "DROP INDEX CONCURRENTLY IF EXISTS #{name}"
        pre = if state == :invalid, do: [drop], else: []

        with :ok <- exec(session, pre),
             :ok <- built(session, name, exec(session, [create])) do
          :ok
        else
          {:defer, _} = defer ->
            _ =
              if index_state(session, name) == :invalid,
                do: exec(session, [drop], cleanup: true)

            defer
        end
    end
  end

  defp built(session, name, :ok) do
    if index_state(session, name) == :valid,
      do: :ok,
      else: {:defer, :index_invalid_after_build}
  end

  defp built(_session, _name, defer), do: defer

  defp deferred(step, reason) do
    Logger.warning(
      "#{step.name} deferred; the next boot retries",
      Metadata.with_category(:warning, :boot, migration: step.name, reason: safe(reason))
    )

    _ = open_ledger(step)
    :deferred
  end

  # Best effort: a ledger write failing too must not fail boot.
  defp open_ledger(step) do
    DataMigrations.note_open(step.name, step.version)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp safe(%{__exception__: true} = e), do: Metadata.safe_reason(e)
  defp safe(reason) when is_atom(reason) or is_binary(reason), do: to_string(reason)
  defp safe(reason), do: Metadata.safe_exit_reason(reason)
end
