defmodule Engram.ServiceConfig.Overrides do
  @moduledoc """
  Runtime overrides of an allowlist of config keys, stored in the global
  `service_overrides` table and read through `Engram.ServiceConfig.get/2`.

  Why: a TF env flip plus the ECS rollout measured 6m46s to 8m49s after
  merge, and while it rolls old and new tasks serve side by side. A row here
  moves every node within seconds and a task booted later reads the same
  row, so there is no split brain between old and new tasks. The keys left
  are the v5 rebuild kill switch (`index_rebuild`) and the v5 step not
  taken yet (`tenant_idf`).

  ## Reads

  The whole table (a handful of rows) is one `Engram.Cache` entry per node,
  `:service_overrides`, TTL 15s. A write evicts it on this node and, through
  `Engram.Cluster.CacheSync`, on every peer; the TTL bounds a lost eviction
  (and a raw-SQL edit, which evicts nothing).

  Outside a transaction the load runs in a short-lived task with a 2s
  budget, so a hung database never blocks a Qdrant call for longer; inside
  one it reads on the caller's connection. Neither path raises. On a
  failed load the node keeps the overrides it last read
  (`:service_overrides_last_good`) and retries after the TTL; a node that has
  never read the table falls back to env. Keeping the last read values
  rather than env is deliberate: a DB blip must not flip one node back to
  env while its peers keep the override.

  A row whose key is not in `keys/0` (a key a later or earlier release
  allows, e.g. a retired v5 flag written by an old node mid-rollout) is
  ignored, with one warning per node per distinct set of such keys.

  ## Writes

  `put/3` and `delete/2` validate the key against `keys/0` and the value
  against its type, log key, old and new value and the operator, then evict
  cluster-wide. Values are booleans and short enums, so nothing logged is a
  secret.
  """

  import Ecto.Query

  alias Engram.Cache
  alias Engram.Logger.Metadata
  alias Engram.Repo

  require Logger

  @types %{
    tenant_idf: :boolean,
    index_rebuild: {:enum, ~w(off dry_run on)}
  }

  @by_name Map.new(Map.keys(@types), &{Atom.to_string(&1), &1})

  @load_timeout_ms 2_000

  @doc "The keys that can be overridden at runtime."
  # No @spec: dialyzer's :underspecs flags `[atom()]` against the literal list.
  def keys, do: Map.keys(@types)

  @doc "`{:ok, value}` when `key` is overridden, else `:error`."
  @spec fetch(atom()) :: {:ok, term()} | :error
  def fetch(key), do: Map.fetch(Cache.fetch(:service_overrides, :all, &load/0), key)

  @spec put(atom() | String.t(), term(), keyword()) :: :ok | {:error, term()}
  def put(key, value, opts \\ []) do
    with {:ok, key} <- resolve(key),
         :ok <- validate(key, value) do
      change(key, {:set, value}, opts)
    end
  end

  @spec delete(atom() | String.t(), keyword()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) do
    with {:ok, key} <- resolve(key), do: change(key, :clear, opts)
  end

  # No @spec: the inferred row map is narrower than any spec worth writing.
  def list do
    from(o in "service_overrides",
      order_by: o.key,
      select: %{key: o.key, value: o.value, updated_by: o.updated_by, updated_at: o.updated_at}
    )
    |> Repo.all()
    |> Enum.flat_map(fn row ->
      case resolve(row.key) do
        {:ok, key} -> [%{row | key: key}]
        {:error, _} -> []
      end
    end)
  end

  # -- reads ------------------------------------------------------------------

  # ponytail: no single-flight; concurrent misses after a TTL or eviction each
  # run one tiny SELECT. Add a per-node loader process if traces show a herd.
  defp load do
    if Process.whereis(Repo) do
      case read() do
        {:ok, overrides} ->
          :ok = Cache.put(:service_overrides_last_good, :all, overrides)
          overrides

        {:error, reason} ->
          fallback(reason)
      end
    else
      # Compile time (a module attribute reading a flag) or boot before the
      # repo starts: nothing to read yet and nothing worth a warning. Not
      # stored, so the first read once the repo is up goes to the table.
      Cache.no_store(last_good())
    end
  end

  # Inside a transaction the caller already holds a connection: read on it.
  # A task would need a second one, and N workers each holding one inside
  # `with_tenant` could drain the pool waiting on themselves. In a savepoint:
  # a failed SELECT (table not migrated yet, a cancelled statement) would
  # otherwise abort the CALLER's transaction, failing whatever write path
  # read the flag.
  defp read do
    if in_transaction?(), do: guarded_read(mode: :savepoint), else: read_in_task()
  end

  # `Repo.in_transaction?/0` raises once the repo is gone (shutdown).
  defp in_transaction? do
    Repo.in_transaction?()
  rescue
    _ -> false
  end

  # Outside one, a task bounds a hung database to @load_timeout_ms.
  defp read_in_task do
    task = Task.async(fn -> guarded_read([]) end)

    case Task.yield(task, @load_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  defp guarded_read(opts) do
    {:ok, read_table(opts)}
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  defp read_table(opts \\ []) do
    {known, ignored} =
      from(o in "service_overrides", select: {o.key, o.value})
      |> Repo.all(opts)
      |> Enum.split_with(fn {name, value} ->
        # A row a newer or older release wrote, or a bad raw-SQL edit.
        match?({:ok, _}, resolve(name)) and validate(@by_name[name], value) == :ok
      end)

    :ok = warn_ignored(Enum.map(ignored, &elem(&1, 0)))
    Map.new(known, fn {name, value} -> {@by_name[name], value} end)
  end

  @ignored_key {__MODULE__, :ignored}

  # ponytail: persistent_term written only when the set changes (a handful of
  # times per release), so its global GC is noise.
  defp warn_ignored(names) do
    names = Enum.sort(names)

    if names != :persistent_term.get(@ignored_key, []) do
      :persistent_term.put(@ignored_key, names)

      if names != [],
        do:
          Logger.warning(
            "service overrides ignored, not overridable in this release: " <>
              Enum.map_join(names, ", ", &inspect/1),
            Metadata.with_category(:warning, :data)
          )
    end

    :ok
  end

  defp fallback(reason) do
    Logger.warning(
      "service overrides unreadable; serving the last values read, or env",
      Metadata.with_category(:warning, :data, reason: safe(reason))
    )

    last_good()
  end

  defp last_good do
    case Cache.get(:service_overrides_last_good, :all) do
      {:ok, overrides} -> overrides
      :miss -> %{}
    end
  end

  defp safe(%{__exception__: true} = e), do: Metadata.safe_reason(e)
  defp safe(reason), do: Metadata.safe_exit_reason(reason)

  # -- writes -----------------------------------------------------------------

  defp change(key, op, opts) do
    by = operator(opts)

    {:ok, {old, new}} =
      Repo.transaction(fn ->
        current = read_table()

        next =
          case op do
            {:set, value} -> Map.put(current, key, value)
            :clear -> Map.delete(current, key)
          end

        _ = write(key, op, by)
        {Map.fetch(current, key), Map.fetch(next, key)}
      end)

    :ok = Cache.evict(:service_overrides, :all)
    log_change(key, old, new, by)
  end

  defp write(key, {:set, value}, by) do
    Repo.query!(
      """
      INSERT INTO service_overrides (key, value, updated_by, updated_at)
      VALUES ($1, $2, $3, now())
      ON CONFLICT (key) DO UPDATE
        SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now()
      """,
      [Atom.to_string(key), value, by]
    )
  end

  defp write(key, :clear, _by),
    do: Repo.query!("DELETE FROM service_overrides WHERE key = $1", [Atom.to_string(key)])

  defp log_change(key, old, new, by) do
    verb = if new == :error, do: "cleared", else: "set"

    Logger.warning(
      "service override #{verb} key=#{key} old=#{shown(old)} new=#{shown(new)} by=#{by}",
      Metadata.with_category(:warning, :data)
    )
  end

  defp shown({:ok, value}), do: inspect(value)
  defp shown(:error), do: "(env)"

  # Operator names are free text from a remote shell: keep them to a short
  # identifier so the log line cannot be forged or carry anything else.
  defp operator(opts) do
    raw = Keyword.get(opts, :by) || System.get_env("ENGRAM_OPERATOR") || "unknown"
    cleaned = String.replace(to_string(raw), ~r/[^A-Za-z0-9@._-]/, "")
    if cleaned == "", do: "unknown", else: String.slice(cleaned, 0, 64)
  end

  # -- validation -------------------------------------------------------------

  defp resolve(key) when is_atom(key),
    do: if(Map.has_key?(@types, key), do: {:ok, key}, else: {:error, {:unknown_key, key}})

  defp resolve(key) when is_binary(key) do
    case Map.fetch(@by_name, key) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:unknown_key, key}}
    end
  end

  defp resolve(key), do: {:error, {:unknown_key, key}}

  defp validate(key, value) do
    ok? =
      case Map.fetch!(@types, key) do
        :boolean -> is_boolean(value)
        {:enum, allowed} -> value in allowed
      end

    if ok?, do: :ok, else: {:error, {:invalid_value, key, value}}
  end
end
