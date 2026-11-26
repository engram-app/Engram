defmodule Engram.KeywordStore.Tantivy do
  @moduledoc """
  Keyword store backend #2 (search storage roadmap P2): the kwsearch service,
  a Tantivy index of hashed per-user term counts (`native/kwsearch`).

  Not colocated. Writes go through the transactional outbox `keyword_feed`
  (`Engram.KeywordStore.Tantivy.Feed`), in the same Postgres transaction as
  the chunk rows they mirror, and kwsearch applies them in commit-safe order.
  Reads call kwsearch over HTTPS with a signed per-request token
  (`Engram.KeywordStore.Tantivy.Client`).

  `hybrid_search/3` runs the dense leg (the vector collection) and the
  keyword leg (kwsearch) in parallel and fuses them by point id
  (`Engram.Vector.Qdrant.fuse/4`). A keyword leg that fails or times out
  leaves the search dense-only and counts
  `[:engram, :search, :keyword_fallback]`; `search/2` (keyword mode) returns
  `{:error, :keyword_degraded}` instead, never an empty list.

  Written beside the sparse store while `:keyword_feed` is on (dual-write)
  and read while `:keyword_read` is `:tantivy` (`Engram.KeywordStore`). Not
  a sparse store itself: the sparse store is always written. SaaS only;
  self-host sets neither key (roadmap D11, P2 task 7).
  """

  alias Engram.KeywordStore.FeedKey
  alias Engram.KeywordStore.Tantivy.Client
  alias Engram.KeywordStore.Tantivy.Feed
  alias Engram.Logger.Metadata
  alias Engram.Native
  alias Engram.Vaults
  alias Engram.Vector.FilterId
  alias Engram.Vector.Qdrant

  require Logger

  @doc "Term counts per new chunk (before the transaction); `in_commit/3` writes them."
  @spec feed_terms([map()], FeedKey.t()) :: [{String.t(), binary()}]
  def feed_terms([], _key), do: []

  def feed_terms(entries, %FeedKey{filter_key: filter_key, language: language}) do
    texts = Enum.map(entries, &Map.fetch!(&1, :text))
    packed = Native.keyword_feed_terms(texts, filter_key, language)
    Enum.zip_with(entries, packed, fn e, t -> {e.id, t} end)
  end

  @doc "The index pass's rows, in its chunk-row transaction: `keep` is authoritative."
  @spec in_commit(map(), [String.t()], [{String.t(), binary()}]) :: :ok
  def in_commit(scope, keep, upserts), do: Feed.note_pass(scope, {:given, keep}, upserts)

  @doc """
  A rewrite of existing points (resparse, DEK re-key), outside any index
  pass: the keep set is read under the note lock in the feed's own
  transaction, and an upsert for a point no longer in it is dropped, so a
  pass that committed since the caller read its chunks is never undone.
  """
  @spec upsert(map(), [map()], FeedKey.t()) :: :ok
  def upsert(scope, entries, key),
    do: Feed.note_pass(scope, :current, feed_terms(entries, key))

  # No tenant: OrphanSweep's tenant-less point pass. kwsearch's own orphan
  # pass covers those (roadmap P2 task 3), so this names no shard.
  @spec delete_points(String.t() | nil, [String.t()]) :: :ok
  def delete_points(nil, _ids), do: :ok
  def delete_points(user_id, ids), do: Feed.delete_points(user_id, ids)

  @doc """
  Only a `:deleted` note (trash, hard delete) writes a delete and the
  deletion log. A `:rebuild` purge and a `:replaced` floor cleanup are
  covered by the index pass's own `delete_note_except`, written in its
  chunk-row transaction under the note lock; a second delete with a keep set
  read before that commit would carry a newer stamp and an older set.
  """
  @spec delete_note(String.t(), String.t(), term(), [String.t()], atom()) :: :ok
  def delete_note(user_id, vault_id, note_id, _keep, :deleted),
    do: Feed.delete_note(%{user_id: user_id, vault_id: vault_id, note_id: note_id})

  def delete_note(_user_id, _vault_id, _note_id, _keep, _reason), do: :ok

  @doc "A vault tombstone on the purge only; a reversible `:soft` drop writes nothing."
  @spec delete_vault(String.t(), String.t(), atom()) :: :ok
  def delete_vault(user_id, vault_id, :purge), do: Feed.delete_vault(user_id, vault_id)
  def delete_vault(_user_id, _vault_id, :soft), do: :ok

  @doc """
  A user tombstone on the purge only, under the canonical id: OrphanSweep
  passes every spelling it found (undashed, upper case), and each spelling
  of one user writes it once. A string that is no uuid at all names no
  tenant and writes nothing.
  """
  @spec delete_user(String.t(), atom()) :: :ok
  def delete_user(_user_id, :soft), do: :ok

  def delete_user(user_id, :purge) do
    # The spelling OrphanSweep compares in (`FilterId.canonical/1`), since
    # `Ecto.UUID.cast/1` alone refuses the vector store's undashed `u`.
    case user_id |> FilterId.canonical() |> Ecto.UUID.cast() do
      {:ok, id} -> Feed.delete_user(id)
      :error -> :ok
    end
  end

  @spec search(map(), keyword()) :: {:ok, [map()]} | {:error, :keyword_degraded}
  def search(sparse, search_opts) do
    case keyword_leg(sparse, search_opts) do
      {:ok, _hits} = ok -> ok
      {:error, reason} -> fallback(reason, :keyword_degraded)
    end
  end

  @spec hybrid_search(term(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def hybrid_search(dense, sparse, search_opts) do
    # Unlinked: a crash in the keyword leg must leave the search dense-only.
    keyword =
      Task.Supervisor.async_nolink(Engram.TaskSupervisor, fn ->
        keyword_leg(sparse, search_opts)
      end)

    dense_leg = Qdrant.search(nil, dense, Keyword.put(search_opts, :with_vector, false))
    keyword = Task.yield(keyword, timeout() + 100) || Task.shutdown(keyword, :brutal_kill)
    limit = Keyword.get(search_opts, :limit, 5)

    with {:ok, dense_hits} <- dense_leg do
      legs =
        case keyword do
          {:ok, {:ok, hits}} ->
            [dense_hits, hits]

          other ->
            _ = fallback(reason(other), :dense_only)
            [dense_hits]
        end

      Qdrant.fuse(nil, legs, limit, search_opts)
    end
  end

  defp keyword_leg(sparse, search_opts) do
    user_id = Keyword.fetch!(search_opts, :user_id)
    # No active vault: nothing to read, so no request (kwsearch would answer
    # 400 to an empty list, counted as a fallback).
    case vault_ids(to_string(user_id), Keyword.get(search_opts, :vault_id)) do
      [] -> {:ok, []}
      vaults -> Client.search(to_string(user_id), vaults, sparse.indices, search_opts)
    end
  end

  defp reason({:ok, {:error, reason}}), do: reason
  defp reason({:exit, _}), do: :kwsearch_crashed
  defp reason(nil), do: :timeout

  # Bounded reason only (`Metadata.safe_reason`), never a response body.
  defp fallback(reason, outcome) do
    label = reason_label(reason)

    Logger.warning(
      "keyword leg failed: #{outcome}",
      Metadata.with_category(:warning, :search, reason: label)
    )

    :telemetry.execute([:engram, :search, :keyword_fallback], %{count: 1}, %{
      outcome: outcome,
      reason: label
    })

    {:error, :keyword_degraded}
  end

  defp reason_label({:kwsearch_status, status}), do: "status_#{status}"
  defp reason_label({:kwsearch_transport, mod}), do: Metadata.safe_reason(mod)
  defp reason_label(reason), do: Metadata.safe_reason(reason)

  defp timeout, do: Keyword.get(Engram.ServiceConfig.get(:kwsearch, []), :timeout_ms, 1_000)

  # The token names the vaults the request may read. No vault scope (an
  # all-vaults search) means the user's active vaults, never an empty list.
  defp vault_ids(user_id, nil), do: Enum.map(Vaults.active_vault_ids(user_id), &to_string/1)
  defp vault_ids(_user_id, ids), do: ids |> List.wrap() |> Enum.map(&to_string/1)
end
