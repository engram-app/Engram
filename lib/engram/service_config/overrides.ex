defmodule Engram.ServiceConfig.Overrides do
  @moduledoc """
  Runtime overrides of an allowlist of config keys, stored in the global
  `service_overrides` table and read through `Engram.ServiceConfig.get/2`.

  Why: a TF env flip plus the ECS rollout measured 6m46s to 8m49s after
  merge, and while it rolls old and new tasks serve side by side. A row here
  moves every node within seconds and a task booted later reads the same
  row, so there is no split brain between old and new tasks. The keys left
  are the v5 rebuild kill switch (`index_rebuild`) and the v5 step not
  taken yet (`tenant_idf`), plus the data migrations' kill switches
  (`file_times_backfill`, `attachment_name_key`): every data migration
  added since 2026-11-06 has one (`docs/context/data-migrations-ledger.md`).
  Retired ledgers' keys are gone (`note_body_columns_null*`, and in release J
  `note_folder_hash_null*`, `explicit_folder_reconcile`,
  `folder_marker_delete*`): a row left under one is ignored with the warning
  below.

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
  cluster-wide. Values are booleans, short enums and bounded integers, so nothing logged is a
  secret.

  ## Flags

  The keys in `flag_keys/0` are also read from the reviewed flags file
  (`Engram.ServiceConfig.Flags`, `docs/context/service-flags.md`). `fetch/1`
  is the one place precedence lives. Where a flags source is configured
  (prod, staging) a flag key reads flag, then env: a DB row for it is ignored
  (one warning per key per node) and `put/3` and `delete/2` refuse it with
  `{:error, :managed_by_flags}`. Every other key, and every key on self-host,
  reads DB row, then env. `paused_accounts` is flags-only everywhere.
  """

  import Ecto.Query

  alias Engram.Cache
  alias Engram.Logger.Metadata
  alias Engram.Repo
  alias Engram.ServiceConfig.Flags

  require Logger

  @types %{
    tenant_idf: :boolean,
    index_rebuild: {:enum, ~w(off dry_run on)},
    keyword_refresh: :boolean,
    keyword_refresh_backlog: {:integer, 0..1_000_000},
    # The `n` backfill (`ReconcileNotePayloads`): kill switch and pace.
    payload_backfill: :boolean,
    payload_backfill_points_per_min: {:integer, 1..100_000},
    rebuild_max_disk_percent: {:integer, 1..100},
    # Emergency plugin-version floor (`Engram.PluginVersion.effective_minimum/0`)
    # and its kill switch (absent = on; false = every lock is ignored). The lock
    # value is a validated JSON map, never free-form.
    plugin_floor: :plugin_lock,
    plugin_floor_enabled: :boolean,
    file_times_backfill: :boolean,
    folder_table_backfill: :boolean,
    # S6 step 4 phase 2 kill switch: off, folder creates insert marker rows
    # again (`Engram.Folders.MarkerStop`).
    folder_marker_stop: :boolean,
    # Every paced backfill chain's pressure gate (`Engram.Backfill.Throttle`).
    backfill_max_queue_ms: {:integer, 1..60_000},
    backfill_max_xact_s: {:integer, 1..86_400},
    # The plugin's `folder_op` wire (#2523 S4), default off: `Engram.Folders.Wire`.
    folder_ops: :boolean,
    # The S3 read switch's kill switch (#2523): off, notes are found and shown
    # by their stored path again (`Engram.Notes.Location.on?/0`).
    name_reads: :boolean,
    # `name_terms` backfill kill switch and the search leg's (`Engram.Search.NameTerms`).
    name_terms_backfill: :boolean,
    name_terms_search: :boolean,
    # Its pace: refs per hop and refs a second (`BackfillNameTerms`).
    name_terms_backfill_max_rows: {:integer, 1..100_000},
    name_terms_backfill_writes_per_s: {:integer, 1..10_000},
    # The name leg's fusion weights (percent of a Qdrant leg's) and its cap on
    # folder-only page slots (`Engram.Search.NameTerms.weights/0`), tuned by the
    # search-quality eval without a deploy.
    name_terms_title_weight_pct: {:integer, 0..1_000},
    name_terms_folder_weight_pct: {:integer, 0..1_000},
    name_terms_folder_slots: {:integer, 0..1_000},
    # The `NoteName` backfill (`BackfillNoteNames`): kill switch, rows per hop, rows a second.
    note_name_backfill: :boolean,
    note_name_backfill_max_rows: {:integer, 1..100_000},
    note_name_backfill_writes_per_s: {:integer, 1..10_000},
    # `Engram.Workers.InactivityCleanup` (#2566): the soft-delete kill switch
    # (default on) and the days between the final notice and the delete.
    inactivity_soft_delete: :boolean,
    inactivity_delete_grace_days: {:integer, 0..365},
    # The `NoteMeta` migration's kill switch (title/tags/links rule heal), default off.
    note_meta_backfill: :boolean,
    # The daily embed token ceiling's kill switch (`Engram.EmbedCeiling`),
    # default on; off is the uncapped behaviour from before it.
    embed_daily_ceiling: :boolean,
    # Rename link rewrites (`RewriteNoteLinks.enabled?/0`), default on: off,
    # queued rewrites snooze, none is dropped.
    link_rewrite: :boolean,
    # `Engram.Workers.OrphanSweep.enabled?/0`, default on: off, the daily
    # sweep returns before any pass (no Qdrant, S3 or DB deletes).
    orphan_sweep: :boolean,
    # S6 step 6: the attachment name key fill ledger, kill switch and pace.
    attachment_name_key: :boolean,
    attachment_name_key_max_fixed: {:integer, 1..1_000_000},
    # S6 step 1b: the root folder reference fill (`DataMigrations.RootRefs`).
    root_refs: :boolean,
    # S6 step 6 phase 2: folder renames leave attachments in place (kill switch).
    attachment_write_stop: :boolean,
    # SaaS only (`Engram.Logs`): true, `POST /api/logs` writes no `client_logs`
    # rows; lines still ship to Loki. Default off. CI and self-host always
    # write, whatever this says.
    client_logs_stop_writes: :boolean,
    # Flags-only (`Engram.ServiceConfig.Flags.paused?/1`, `Engram.ClientGate`):
    # `[%{"id" => uuid, "until" => UTC ISO 8601}]`. Never a DB row.
    paused_accounts: :paused_accounts
  }

  # The keys the reviewed flags file owns: exactly the `properties` of
  # engram-infra `service_flags/schema.json`. Change both together.
  @flag_keys ~w(folder_marker_delete folder_marker_delete_max_fixed folder_ops
                client_logs_stop_writes plugin_floor_enabled plugin_floor paused_accounts)a
  @flags_only [:paused_accounts]

  @by_name Map.new(Map.keys(@types), &{Atom.to_string(&1), &1})

  @load_timeout_ms 2_000

  @doc "The keys that can be overridden at runtime."
  # No @spec: dialyzer's :underspecs flags `[atom()]` against the literal list.
  def keys, do: Map.keys(@types)

  @doc "The keys the reviewed flags file owns (`Engram.ServiceConfig.Flags`)."
  def flag_keys, do: @flag_keys

  @doc "`{:ok, key}` when the flags-file `name` is a flag key, else `:error`."
  # No @spec: dialyzer's :underspecs flags `atom()` against the literal keys.
  def flag_key(name) do
    case resolve(name) do
      {:ok, key} when key in @flag_keys -> {:ok, key}
      _ -> :error
    end
  end

  @doc """
  `{:ok, value}` when `key` is overridden, else `:error` (the caller's env,
  then its default, applies). Where a flags source is configured a flag key
  reads ONLY the flags (a DB row for it is ignored, `managed/1`); every other
  key, and every key on self-host, reads the DB override.
  """
  @spec fetch(atom()) :: {:ok, term()} | :error
  def fetch(key) do
    if managed?(key),
      do: Flags.fetch(key),
      else: Map.fetch(Cache.fetch(:service_overrides, :all, &load/0), key)
  end

  @doc "Whether `key` is read from the flags file only (a source is configured)."
  @spec managed?(atom()) :: boolean()
  def managed?(key), do: key in @flag_keys and Flags.configured?()

  @spec put(atom() | String.t(), term(), keyword()) :: :ok | {:error, term()}
  def put(key, value, opts \\ []) do
    with {:ok, key} <- resolve(key),
         :ok <- writable(key),
         :ok <- validate(key, value) do
      change(key, {:set, value}, opts)
    end
  end

  @spec delete(atom() | String.t(), keyword()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) do
    with {:ok, key} <- resolve(key), :ok <- writable(key), do: change(key, :clear, opts)
  end

  # A DB write to a key the flags file owns would be shadowed by it (or, on a
  # failed flags read, surface as a value nobody reviewed).
  defp writable(key) do
    if key in @flags_only or managed?(key),
      do: {:error, :managed_by_flags},
      else: :ok
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

    {managed, read} =
      known
      |> Enum.map(fn {name, value} -> {@by_name[name], value} end)
      |> Enum.split_with(fn {key, _} -> managed?(key) end)

    :ok = warn_managed(Enum.map(managed, &elem(&1, 0)))
    Map.new(read)
  end

  @managed_key {__MODULE__, :managed}

  # A row left under a flag key from before flags shipped: ignored, and
  # visible once per key per node (persistent_term, written only on change).
  defp warn_managed(keys) do
    seen = :persistent_term.get(@managed_key, [])

    case Enum.sort(keys) -- seen do
      [] ->
        :ok

      new ->
        :persistent_term.put(@managed_key, Enum.sort(seen ++ new))

        Enum.each(new, fn key ->
          Logger.warning(
            "db override ignored, managed by flags key=#{key}",
            Metadata.with_category(:warning, :data)
          )
        end)
    end
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

  @doc """
  Checks `value` against `key`'s type. The one validator for DB writes, DB
  reads and the flags file (`Engram.ServiceConfig.Flags`).
  """
  @spec validate(atom(), term()) :: :ok | {:error, {:invalid_value, atom(), term()}}
  def validate(key, value) do
    ok? =
      case Map.fetch!(@types, key) do
        :boolean -> is_boolean(value)
        {:enum, allowed} -> value in allowed
        {:integer, range} -> is_integer(value) and value in range
        :plugin_lock -> match?({:ok, _}, Engram.PluginVersion.parse_lock(value))
        :paused_accounts -> match?({:ok, _}, Flags.parse_paused(value))
      end

    if ok?, do: :ok, else: {:error, {:invalid_value, key, value}}
  end
end
