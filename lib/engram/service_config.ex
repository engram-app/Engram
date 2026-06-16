defmodule Engram.ServiceConfig do
  @moduledoc """
  Single read-seam for the external-service config that tests need to override
  per-process: the Voyage embedder + Qdrant client base URLs, API keys, and
  their peer tuning knobs.

  ## Why this exists

  Those clients used to read their config straight from global
  `Application.get_env(:engram, ...)`. That forced every test that points them
  at a per-test `Bypass` port (via `Application.put_env/3`) to run
  `async: false` — two async tests would clobber the same global `:voyage_url`
  / `:qdrant_url` key mid-flight. Routing the reads through `get/2` lets a test
  install a **per-process** override instead, so the Voyage/Qdrant Bypass test
  families can flip to `async: true`.

  ## Mechanism

  Mirrors how `Mox` / `Ecto.Sandbox` isolate per-test state across inline child
  processes: an override is stored in a shared ETS table keyed by the owning
  process, and a reader resolves its owner by scanning `[self() | $callers]`
  (the caller chain `Task` and friends propagate automatically). This covers
  the three ways the blocked suites reach these clients — a direct call in the
  test process, an inline `Oban.Testing.perform_job/2`, and a `Task` child.

  ## Prod path

  The override machinery is **compile-time gated** (`@is_test_build`). In a
  non-test build `get/2` is a plain `Application.get_env/3` — byte-identical to
  the old reads, zero hot-path cost, and `put_override/2` does not exist.
  """

  # Mirrors the `@is_test_build` pattern in `Engram.Embedders.Voyage` /
  # `EngramWeb.Plugs.RateLimit` (config.exs sets `:engram, :env, Mix.env()`).
  @build_env Application.compile_env(:engram, :env, :prod)
  @is_test_build @build_env == :test

  @table :engram_service_config_overrides

  if @is_test_build do
    @doc """
    Reads `key`, preferring a per-process override over global app env.

    Resolution order: the first override found scanning `[self() | $callers]`,
    then `Application.get_env(:engram, key, default)`.
    """
    @spec get(atom(), term()) :: term()
    def get(key, default \\ nil) do
      case fetch_override(key) do
        {:ok, value} -> value
        :error -> Application.get_env(:engram, key, default)
      end
    end

    @doc """
    Installs a per-process override for `key`, owned by the calling process.

    Visible to `get/2` from this process and any `$callers` descendant of it
    (e.g. a `Task` it spawns, or an inline `perform_job/2`). Test builds only.
    """
    @spec put_override(atom(), term()) :: :ok
    def put_override(key, value) do
      ensure_table()
      :ets.insert(@table, {{self(), key}, value})
      :ok
    end

    @doc """
    Idempotently creates the shared override table. Called once from
    `test_helper.exs` so the table is owned by the long-lived suite runner
    (a finishing async test must not destroy a concurrent test's overrides).
    """
    @spec ensure_table() :: :ok
    def ensure_table do
      case :ets.whereis(@table) do
        :undefined ->
          # `:public` so any owner/caller process can read and write. The
          # rescue guards the create/create race when two processes ensure
          # concurrently before `test_helper` has run.
          try do
            :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          rescue
            ArgumentError -> :ok
          end

        _ref ->
          :ok
      end

      :ok
    end

    # `:error` (no override) is distinct from `{:ok, nil}` (override TO nil),
    # so a key can be overridden to `nil` and still beat app env. A missing
    # table means no overrides exist yet → behave exactly like app env.
    defp fetch_override(key) do
      case :ets.whereis(@table) do
        :undefined ->
          :error

        _ref ->
          [self() | Process.get(:"$callers", [])]
          |> Enum.find_value(:error, fn pid ->
            case :ets.lookup(@table, {pid, key}) do
              [{_, value}] -> {:ok, value}
              [] -> nil
            end
          end)
      end
    end
  else
    @spec get(atom(), term()) :: term()
    def get(key, default \\ nil), do: Application.get_env(:engram, key, default)
  end
end
