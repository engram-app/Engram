defmodule Engram.Onboarding.TermsCache do
  @moduledoc """
  Cache of each user's latest accepted version per document, keyed by
  `{user_id, document}`. Written on accept (monotonic — versions only ever
  advance). A cache miss falls through to the authoritative agreement query and
  back-fills.

  Two backends, selected by `Engram.Cache.backend/0`:

    * `:ets`   — per-node table (default; self-host). Writes are node-local: an
      accept on one node does not push to others, so a peer node may hold a
      stale (older) accepted version until its own read-through refreshes it.
      This only ever over-gates (shows a notice / withholds access a little
      longer) — never a false accept, since the floor comparison is `>=`.

    * `:redis` — cluster-shared (SaaS). Key `terms:{user_id}:{document}` so an
      accept on one node is immediately visible to all. A TTL bounds memory;
      expiry just triggers a DB read-through + back-fill. Fails open to `nil`.
  """

  use GenServer

  alias Engram.Cache

  @table :engram_terms_cache

  # Memory-bound TTL only — the value is monotonic and re-derivable from the DB,
  # so expiry costs one read-through. The container's allkeys-lru policy is the
  # backstop; this just caps how long an evicted-then-recreated key lingers.
  @redis_ttl_seconds 86_400

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec accepted_version(user_id :: integer(), document :: String.t()) :: String.t() | nil
  def accepted_version(user_id, document) do
    case Cache.backend() do
      :redis -> redis_get(user_id, document)
      _ -> ets_get(user_id, document)
    end
  end

  @spec put_accepted(user_id :: integer(), document :: String.t(), version :: String.t()) :: :ok
  def put_accepted(user_id, document, version) do
    case Cache.backend() do
      :redis -> Cache.redis_set(:terms, key(user_id, document), version, @redis_ttl_seconds)
      _ -> ets_put(user_id, document, version)
    end
  end

  defp redis_get(user_id, document) do
    case Cache.redis_get(:terms, key(user_id, document)) do
      {:ok, version} -> version
      :miss -> nil
    end
  end

  defp ets_get(user_id, document) do
    case :ets.lookup(@table, {user_id, document}) do
      [{{^user_id, ^document}, version}] -> version
      _ -> nil
    end
  rescue
    # Table absent → report nothing cached so the caller re-queries the DB.
    ArgumentError -> nil
  end

  defp ets_put(user_id, document, version) do
    :ets.insert(@table, {{user_id, document}, version})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp key(user_id, document), do: "terms:#{user_id}:#{document}"

  @impl true
  def init(:ok) do
    _ =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{}}
  end
end
