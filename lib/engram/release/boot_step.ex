defmodule Engram.Release.BootStep do
  @moduledoc """
  The owner-run boot steps `Engram.Release.migrate/0` runs after the
  migrations, on the migrator connection and inside the migration lock
  (release K's `Engram.Release.FolderHashDrop`, release L's
  `Engram.Release.NotesPathExpand`). The shared shape lives here once:

    * a completion ledger per step (`Engram.DataMigrations`): a done step
      costs one read and runs nothing;
    * a kill switch per step, a flags-only boolean key (default on), read
      from the flags source ONCE per boot for all steps
      (`Engram.ServiceConfig.Flags.read_once/2`, 3 s budget: the reader has
      not started in the migrate eval), and only when some step is pending.
      Each pending step logs `<step> flags read source=<appconfig|file|none>
      value=<true|false|absent>` at info in the `:boot` category, which ships
      to Loki, so prod can prove the switch was read. An unreadable source is
      a warning and the step runs (default on);
    * a session (`in_session/2`) with a short `lock_timeout` and a
      `statement_timeout`, so a statement waits on a lock for seconds, never
      queues writers behind it for longer, and never runs unbounded;
    * never fails boot: an error, a lock timeout, a raise or an exit is a
      `<step> deferred` warning, the ledger row stays open and the next boot
      retries. Each step is idempotent, so a rerun from any point is safe.
  """

  alias Engram.DataMigrations
  alias Engram.Logger.Metadata
  alias Engram.ServiceConfig.Flags

  require Logger

  @enforce_keys [:name, :version, :flag, :apply]
  defstruct @enforce_keys

  @typedoc """
  `apply` runs the step on the repo: `:ok` (done, the ledger closes) or
  `{:defer, reason}` (left for the next boot). It may raise.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          version: pos_integer(),
          flag: atom(),
          apply: (module() -> :ok | {:defer, term()})
        }

  @type result :: :skipped | :disabled | :done | :deferred

  @flags_timeout_ms 3_000
  # LockTimeoutRetry's value (priv/repo/migrations/lock_timeout_retry.exs).
  @lock_timeout "5s"
  @statement_timeout_ms 30_000

  @doc "The per-statement server-side bound `in_session/2` sets."
  def statement_timeout_ms, do: @statement_timeout_ms

  @doc """
  Runs `steps` in order on `repo` (a migrator-credential repo) and returns
  `[{name, result}]`. One step's failure never stops the next. Never raises.
  `opts`: `:flags_timeout_ms`.
  """
  @spec run_all(module(), [t()], keyword()) :: [{String.t(), result()}]
  def run_all(repo, steps, opts \\ []) do
    timeout = Keyword.get(opts, :flags_timeout_ms, @flags_timeout_ms)

    {results, _flags} =
      Enum.map_reduce(steps, :unread, fn step, flags ->
        {result, flags} = run_one(repo, step, flags, timeout)
        {{step.name, result}, flags}
      end)

    results
  end

  defp run_one(repo, step, flags, timeout) do
    if DataMigrations.done?(step.name, step.version) do
      {:skipped, flags}
    else
      flags = if flags == :unread, do: read_flags(timeout), else: flags

      result =
        if enabled?(step, flags), do: apply_step(repo, step), else: :disabled

      {result, flags}
    end
  rescue
    e -> {deferred(step, e), flags}
  catch
    kind, reason -> {deferred(step, {kind, reason}), flags}
  end

  defp apply_step(repo, step) do
    case step.apply.(repo) do
      :ok ->
        :ok = DataMigrations.mark_done(step.name, step.version)

        Logger.info(
          "#{step.name} done",
          Metadata.with_category(:info, :boot, migration: step.name, version: step.version)
        )

        :done

      {:defer, reason} ->
        deferred(step, reason)
    end
  end

  # {:ok, source label, flags} | {:none} | {:error, source label, reason}
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
      "#{step.name} flags unreadable; running with the default (on)",
      Metadata.with_category(:warning, :boot, migration: step.name, reason: safe(reason))
    )

    true
  end

  # The positive proof the kill switch was read. Values are a boolean or
  # absent (the flags parser validates the type), so nothing logged is secret.
  defp flags_read(step, source, value) do
    Logger.info(
      "#{step.name} flags read source=#{source} value=#{value}",
      Metadata.with_category(:info, :boot, migration: step.name)
    )

    value != false
  end

  @doc """
  Runs `fun` on one pinned connection of `repo` under a #{@lock_timeout}
  `lock_timeout` and a #{@statement_timeout_ms} ms `statement_timeout`,
  reset afterwards. No checkout deadline: each statement carries its own
  bound (a client timeout a little past the server's), and DBConnection's
  default deadline would cover the whole block.
  """
  @spec in_session(module(), (-> result)) :: result when result: term()
  def in_session(repo, fun) do
    repo.checkout(
      fn ->
        repo.query!("SET lock_timeout = '#{@lock_timeout}'")
        repo.query!("SET statement_timeout = #{@statement_timeout_ms}")

        try do
          fun.()
        after
          repo.query!("RESET lock_timeout")
          repo.query!("RESET statement_timeout")
        end
      end,
      timeout: :infinity
    )
  end

  @doc """
  Runs `statements` in order inside `in_session/2`; the first error stops
  the rest and comes back as `{:defer, error}`.
  """
  @spec exec(module(), [String.t()]) :: :ok | {:defer, term()}
  def exec(repo, statements) do
    Enum.reduce_while(statements, :ok, fn sql, :ok ->
      case query(repo, sql) do
        {:ok, _} -> {:cont, :ok}
        {:error, e} -> {:halt, {:defer, e}}
      end
    end)
  end

  @doc "One statement under the session's bounds: `{:ok, result} | {:error, e}`."
  @spec query(module(), String.t(), list()) :: {:ok, term()} | {:error, term()}
  def query(repo, sql, params \\ []),
    do: repo.query(sql, params, timeout: @statement_timeout_ms + 5_000)

  @doc """
  `:valid`, `:invalid` (a failed or killed CONCURRENTLY build: never done)
  or `:absent`, for the index `name` in the public schema.
  """
  @spec index_state(module(), String.t()) :: :valid | :invalid | :absent
  def index_state(repo, name) do
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
  CONCURRENTLY IF NOT EXISTS` statement) inside `in_session/2`: a valid one
  is done; an INVALID one is dropped first; after the build it must read
  valid. A failed build's INVALID leftover is dropped at once (an invalid
  UNIQUE index still enforces uniqueness on writes); if that drop fails
  too, the next attempt drops it before building.
  """
  @spec build_index(module(), String.t(), String.t()) :: :ok | {:defer, term()}
  def build_index(repo, name, create) do
    case index_state(repo, name) do
      :valid ->
        :ok

      state ->
        drop = "DROP INDEX CONCURRENTLY IF EXISTS #{name}"
        pre = if state == :invalid, do: [drop], else: []

        with :ok <- exec(repo, pre),
             :ok <- built(repo, name, exec(repo, [create])) do
          :ok
        else
          {:defer, _} = defer ->
            _ = if index_state(repo, name) == :invalid, do: exec(repo, [drop])
            defer
        end
    end
  end

  defp built(repo, name, :ok) do
    if index_state(repo, name) == :valid, do: :ok, else: {:defer, :index_invalid_after_build}
  end

  defp built(_repo, _name, defer), do: defer

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

  defp safe(%{__exception__: true} = e), do: Metadata.safe_reason(e)
  defp safe(reason) when is_atom(reason) or is_binary(reason), do: to_string(reason)
  defp safe(reason), do: Metadata.safe_exit_reason(reason)
end
