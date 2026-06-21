defmodule Engram.Onboarding.TermsCache do
  @moduledoc """
  Cache of each user's latest accepted version per document, keyed by
  `{user_id, document}`. Written on accept (monotonic — versions only ever
  advance). A cache miss falls through to the authoritative agreement query and
  back-fills.

  Backend: `:ets` — per-node table. Writes are node-local: an accept on one node
  does not push to others, so a peer node may hold a stale (older) accepted
  version until its own read-through refreshes it. This only ever over-gates
  (shows a notice / withholds access a little longer) — never a false accept,
  since the floor comparison is `>=`.
  """

  use GenServer

  @table :engram_terms_cache

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec accepted_version(user_id :: integer(), document :: String.t()) :: String.t() | nil
  def accepted_version(user_id, document), do: ets_get(user_id, document)

  @spec put_accepted(user_id :: integer(), document :: String.t(), version :: String.t()) :: :ok
  def put_accepted(user_id, document, version), do: ets_put(user_id, document, version)

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
