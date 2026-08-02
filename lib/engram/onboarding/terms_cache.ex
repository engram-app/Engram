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

  use Engram.Cache.NodeLocalEts, table: :engram_terms_cache

  @spec accepted_version(user_id :: integer(), document :: String.t()) :: String.t() | nil
  def accepted_version(user_id, document) do
    case ets_lookup({user_id, document}) do
      [{{^user_id, ^document}, version}] -> version
      _ -> nil
    end
  end

  @spec put_accepted(user_id :: integer(), document :: String.t(), version :: String.t()) :: :ok
  def put_accepted(user_id, document, version), do: ets_insert({{user_id, document}, version})
end
