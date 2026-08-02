defmodule Engram.Cache.NodeLocalEts do
  @moduledoc """
  Shared scaffolding for the node-local ETS caches (a `use` macro).

  Every node-local cache here is the same shape: a GenServer that owns a
  `:named_table, :public, :set` ETS table (read/write concurrency on) for the
  app's lifetime, with rescue-`ArgumentError` guards on every table op so an
  absent table (owner down / not yet started) degrades to a miss or no-op and
  the caller falls through to the authoritative source instead of crashing the
  request. This macro owns that scaffolding; each cache module keeps its public
  API, value shapes, and eviction semantics.

  All code is injected in `__using__` (module-body position) rather than
  `@before_compile`: overriding GenServer's `defoverridable` default
  `handle_info/2` only works from the module body, and it also lets a cache
  override `delete_local/1` the same way.

  ## Options

    * `:table` (required) — the ETS table name atom.
    * `:ttl` — milliseconds. Injects `cache_lookup/1`, `cache_put/2`, and
      `cache_fetch/2` over `{key, value, expires_at}` rows (monotonic ms).
    * `:cache_sync` — when true, subscribes to `Engram.Cluster.CacheSync` in
      `init/1` and installs the trailing catch-all `handle_info` clause that
      ignores `{:cache_sync, _}` messages addressed to other caches.
    * `:sync_evict` — tag atom; `{:cache_sync, {tag, key}}` calls
      `delete_local(key)`.
    * `:sync_evict_all` — list of tag atoms; each `{:cache_sync, tag}` calls
      `clear_local/0`. A cache may list tags it merely consumes (e.g.
      `GateCache` clearing on `VersionCache`'s `:version_evict_all`).
    * `:pg_channel` — Postgres NOTIFY channel to LISTEN on via the dedicated
      `Engram.PgNotifications` connection; each notification payload is passed
      to `delete_local/1`. Failure to LISTEN is non-fatal (logged; the TTL
      still bounds staleness). Requires `:pg_log_category`.
    * `:pg_log_category` — `Engram.Logger.Metadata` category for the LISTEN
      failure warnings.

  ## Injected functions

  `start_link/1`, `init/1`, and the guarded primitives `ets_lookup/1` (`[]` on
  absent table), `ets_insert/1` (`:ok`), `delete_local/1` (`:ets.delete/2` of
  the key, `defoverridable`), and `clear_local/0`. A cache whose eviction key
  differs from its storage key (e.g. `OverrideCache`, keyed by
  `{user_id, limit_key}` but evicted per user) overrides `delete_local/1`; the
  injected NOTIFY / cache_sync handlers call the override.
  """

  defmacro __using__(opts) do
    {:__block__, [], [setup_ast(opts), base_ast(), ttl_ast(), listen_pg_ast(), handle_info_ast()]}
  end

  defp setup_ast(opts) do
    quote bind_quoted: [opts: opts] do
      use GenServer

      require Logger

      @nle_table Keyword.fetch!(opts, :table)
      @nle_ttl Keyword.get(opts, :ttl)
      @nle_cache_sync Keyword.get(opts, :cache_sync, false)
      @nle_sync_evict Keyword.get(opts, :sync_evict)
      @nle_sync_evict_all Keyword.get(opts, :sync_evict_all, [])
      @nle_pg_channel Keyword.get(opts, :pg_channel)

      if @nle_pg_channel do
        @nle_pg_log_category Keyword.fetch!(opts, :pg_log_category)
        @nle_log_prefix __MODULE__ |> Module.split() |> List.last()
      end
    end
  end

  defp base_ast do
    quote do
      @doc false
      def start_link(_opts) do
        GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
      end

      @impl true
      def init(:ok) do
        _ =
          :ets.new(@nle_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

        :ok = subscribe_cache_sync()
        :ok = listen_pg()
        {:ok, %{}}
      end

      # Variant selection happens at compile time (module-body `if` on the
      # opts), so init/1 carries no dead runtime branches.
      if @nle_cache_sync do
        defp subscribe_cache_sync, do: Engram.Cluster.CacheSync.subscribe()
      else
        defp subscribe_cache_sync, do: :ok
      end

      @doc false
      def ets_lookup(key) do
        :ets.lookup(@nle_table, key)
      rescue
        # Table absent (cache process down) → behave as a miss; the caller
        # falls through to the authoritative source.
        ArgumentError -> []
      end

      @doc false
      def ets_insert(row) do
        :ets.insert(@nle_table, row)
        :ok
      rescue
        ArgumentError -> :ok
      end

      @doc false
      def delete_local(key) do
        :ets.delete(@nle_table, key)
      rescue
        ArgumentError -> true
      end

      # A cache whose eviction key differs from its storage key overrides this.
      defoverridable delete_local: 1

      @doc false
      def clear_local do
        :ets.delete_all_objects(@nle_table)
      rescue
        ArgumentError -> true
      end
    end
  end

  defp ttl_ast do
    quote do
      if @nle_ttl do
        @doc false
        def cache_lookup(key) do
          case :ets.lookup(@nle_table, key) do
            [{^key, value, expires_at}] ->
              if System.monotonic_time(:millisecond) < expires_at,
                do: {:ok, value},
                else: :stale

            _ ->
              :stale
          end
        rescue
          # Table absent (cache process down) → treat every read as stale; the
          # caller falls through to the authoritative source.
          ArgumentError -> :stale
        end

        @doc false
        def cache_put(key, value) do
          expires_at = System.monotonic_time(:millisecond) + @nle_ttl
          :ets.insert(@nle_table, {key, value, expires_at})
          :ok
        rescue
          ArgumentError -> :ok
        end

        @doc false
        def cache_fetch(key, fun) do
          case cache_lookup(key) do
            {:ok, value} ->
              value

            :stale ->
              value = fun.()
              cache_put(key, value)
              value
          end
        end
      end
    end
  end

  # LISTEN on a Postgres NOTIFY channel (e.g. the one fired by the
  # user_limit_overrides AFTER-write trigger, migration 20260612100000). This
  # is what makes raw-SQL writers (support-runbook grants, e2e helpers)
  # coherent: every node hears the NOTIFY directly from Postgres and evicts
  # within milliseconds, no app API involved. Failure to listen is non-fatal —
  # the TTL still bounds staleness — so log and continue.
  defp listen_pg_ast do
    quote do
      if @nle_pg_channel do
        defp listen_pg do
          case Process.whereis(Engram.PgNotifications) do
            nil ->
              Logger.warning(
                "#{@nle_log_prefix}: PG notifications process not running; TTL-only eviction",
                Engram.Logger.Metadata.with_category(:warning, @nle_pg_log_category, [])
              )

            _pid ->
              {:ok, _ref} =
                Postgrex.Notifications.listen(Engram.PgNotifications, @nle_pg_channel)

              :ok
          end
        catch
          kind, reason ->
            Logger.warning(
              "#{@nle_log_prefix}: failed to LISTEN #{@nle_pg_channel} " <>
                "(#{kind}: #{inspect(reason)}); TTL-only eviction",
              Engram.Logger.Metadata.with_category(:warning, @nle_pg_log_category, [])
            )
        end
      else
        defp listen_pg, do: :ok
      end
    end
  end

  defp handle_info_ast do
    quote unquote: false do
      if @nle_pg_channel do
        @impl true
        def handle_info({:notification, _pid, _ref, @nle_pg_channel, payload}, state) do
          _ = delete_local(payload)
          {:noreply, state}
        end
      end

      if @nle_sync_evict do
        @impl true
        def handle_info({:cache_sync, {@nle_sync_evict, key}}, state) do
          _ = delete_local(key)
          {:noreply, state}
        end
      end

      for nle_tag <- @nle_sync_evict_all do
        @impl true
        def handle_info({:cache_sync, unquote(nle_tag)}, state) do
          _ = clear_local()
          {:noreply, state}
        end
      end

      if @nle_cache_sync do
        # Ignore cache_sync messages addressed to other caches.
        @impl true
        def handle_info({:cache_sync, _other}, state), do: {:noreply, state}
      end
    end
  end
end
