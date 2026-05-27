defmodule Engram.Onboarding.TermsCache do
  @moduledoc """
  Per-node ETS cache of each user's latest accepted version per document, keyed
  by `{user_id, document}`. Invalidated explicitly on accept (monotonic — only
  ever advances). A cache miss falls through to the authoritative agreement
  query.
  """

  use GenServer

  @table :engram_terms_cache

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec accepted_version(user_id :: integer(), document :: String.t()) :: String.t() | nil
  def accepted_version(user_id, document) do
    case :ets.lookup(@table, {user_id, document}) do
      [{{^user_id, ^document}, version}] -> version
      _ -> nil
    end
  rescue
    # Table absent → report nothing cached so the caller re-queries the DB.
    ArgumentError -> nil
  end

  @spec put_accepted(user_id :: integer(), document :: String.t(), version :: String.t()) :: :ok
  def put_accepted(user_id, document, version) do
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
