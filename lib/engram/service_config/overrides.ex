defmodule Engram.ServiceConfig.Overrides do
  @moduledoc """
  Runtime overrides of an allowlist of config keys, stored in the global
  `service_overrides` table and read through `Engram.ServiceConfig.get/2`.

  Why: a TF env flip plus the ECS rollout measured 6m46s to 8m49s after
  merge, and while it rolls old and new tasks serve side by side. The v5
  rollout needs every step reversible in about 5 minutes. A row here moves
  every node within seconds and a task booted later reads the same row, so
  there is no split brain between old and new tasks.

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
  the old Qdrant cluster while its peers stay on v2.

  ## Writes

  `put/3` and `delete/2` validate the key against `keys/0`, the value against
  its type, and the GO SEQUENCE invariants (the ones engram-infra's
  v5_flags.tf validates for env) over the effective config after the change.
  They serialise on a table lock, log key, old and new value and the
  operator, then evict cluster-wide. Values are booleans and short enums, so
  nothing logged is a secret.
  """

  import Ecto.Query

  alias Engram.Cache
  alias Engram.Logger.Metadata
  alias Engram.Repo
  alias Engram.ServiceConfig

  require Logger

  @boolean_keys ~w(write_v5_layout v5_payload_format chunk_text_write chunk_text_read
                   vector_cache_enabled embed_models_per_plan index_budget_enabled tenant_idf
                   qdrant_tenant_graph)a

  @types Map.merge(Map.new(@boolean_keys, &{&1, :boolean}), %{
           index_rebuild: {:enum, ~w(off dry_run on)},
           qdrant_active_cluster: {:enum, ~w(old v2)}
         })

  @by_name Map.new(Map.keys(@types), &{Atom.to_string(&1), &1})

  # Each key's reader default, for the invariant check when env leaves it unset.
  @defaults Map.merge(Map.new(@boolean_keys, &{&1, false}), %{
              index_rebuild: "off",
              qdrant_active_cluster: "old"
            })

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
      change(key, {:set, value}, operator(opts))
    end
  end

  @spec delete(atom() | String.t(), keyword()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) do
    with {:ok, key} <- resolve(key), do: change(key, :clear, operator(opts))
  end

  @spec list() :: [%{key: atom(), value: term(), updated_by: String.t(), updated_at: term()}]
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
    case read() do
      {:ok, overrides} ->
        :ok = Cache.put(:service_overrides_last_good, :all, overrides)
        overrides

      {:error, reason} ->
        fallback(reason)
    end
  end

  # Inside a transaction the caller already holds a connection: read on it.
  # A task would need a second one, and N workers each holding one inside
  # `with_tenant` could drain the pool waiting on themselves.
  defp read do
    if Repo.in_transaction?(), do: guarded_read(), else: read_in_task()
  end

  # Outside one, a task bounds a hung database to @load_timeout_ms.
  defp read_in_task do
    task = Task.async(&guarded_read/0)

    case Task.yield(task, @load_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  defp guarded_read do
    {:ok, read_table()}
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  defp read_table do
    from(o in "service_overrides", select: {o.key, o.value})
    |> Repo.all()
    |> Enum.flat_map(fn {name, value} ->
      # A row a newer release wrote, or a bad raw-SQL edit, is ignored.
      with {:ok, key} <- resolve(name),
           :ok <- validate(key, value) do
        [{key, value}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp fallback(reason) do
    Logger.warning(
      "service overrides unreadable; serving the last values read, or env",
      Metadata.with_category(:warning, :data, reason: safe(reason))
    )

    case Cache.get(:service_overrides_last_good, :all) do
      {:ok, overrides} -> overrides
      :miss -> %{}
    end
  end

  defp safe(%{__exception__: true} = e), do: Metadata.safe_reason(e)
  defp safe(reason), do: Metadata.safe_exit_reason(reason)

  # -- writes -----------------------------------------------------------------

  defp change(key, op, by) do
    result =
      Repo.transaction(fn ->
        # Serialises writers so two operators cannot each pass the invariant
        # check against the other's stale view. Readers (ACCESS SHARE) are not
        # blocked.
        Repo.query!("LOCK TABLE service_overrides IN EXCLUSIVE MODE")
        current = read_table()

        next =
          case op do
            {:set, value} -> Map.put(current, key, value)
            :clear -> Map.delete(current, key)
          end

        case invariant_violation(next) do
          nil ->
            write(key, op, by)
            {Map.fetch(current, key), Map.fetch(next, key)}

          message ->
            Repo.rollback({:invariant, message})
        end
      end)

    case result do
      {:ok, {old, new}} ->
        :ok = Cache.evict(:service_overrides, :all)
        log_change(key, old, new, by)

      {:error, _} = error ->
        error
    end
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

  # The env-side twins live in engram-infra's v5_flags.tf validations; this
  # keeps a runtime flip from reaching a state TF would refuse.
  defp invariant_violation(overrides) do
    get = fn key -> Map.get_lazy(overrides, key, fn -> env(key) end) end
    rebuild = get.(:index_rebuild)

    cond do
      rebuild in ["dry_run", "on"] and get.(:write_v5_layout) != true ->
        "index_rebuild=#{rebuild} needs write_v5_layout=true"

      rebuild == "on" and get.(:vector_cache_enabled) != true ->
        "index_rebuild=on needs vector_cache_enabled=true"

      get.(:qdrant_tenant_graph) == true and
          ServiceConfig.env(:legacy_filter_fields, true) != false ->
        "qdrant_tenant_graph=true needs LEGACY_FILTER_FIELDS=false"

      get.(:qdrant_active_cluster) == "v2" and ServiceConfig.env(:qdrant_url_v2) in [nil, ""] ->
        "qdrant_active_cluster=v2 needs QDRANT_URL_V2"

      true ->
        nil
    end
  end

  defp env(key), do: ServiceConfig.env(key, Map.fetch!(@defaults, key))
end
