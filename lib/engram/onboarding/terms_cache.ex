defmodule Engram.Onboarding.TermsCache do
  @moduledoc """
  Per-node ETS cache recording that a user has accepted a given TOS version.

  TOS acceptance is append-only and monotonic per version: once a user has
  accepted the current version it can never become un-accepted for that
  version. So we cache positive results only, keyed by `{user_id, version}`.
  A version bump changes the key, which misses naturally and forces a fresh
  check against the new version — no explicit invalidation required.

  Negative results are never cached: a user who hasn't accepted yet will soon,
  and the next check (post-acceptance) reads through and caches the positive.

  The table is `:public` (the value is a non-secret boolean), so request
  processes read and write directly with no GenServer hop. This process exists
  only to own the table for the application's lifetime.
  """

  use GenServer

  @table :engram_terms_cache

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec accepted?(user_id :: integer(), version :: String.t()) :: boolean()
  def accepted?(user_id, version) do
    :ets.member(@table, {user_id, version})
  end

  @spec mark_accepted(user_id :: integer(), version :: String.t()) :: :ok
  def mark_accepted(user_id, version) do
    :ets.insert(@table, {{user_id, version}})
    :ok
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
