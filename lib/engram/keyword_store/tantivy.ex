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

  SaaS only, behind `:keyword_store` (read through `Engram.ServiceConfig`).
  Self-host keeps `Engram.KeywordStore.QdrantSparse` (roadmap D11, P2 task 7).
  """
  @behaviour Engram.KeywordStore

  alias Engram.KeywordStore.Tantivy.Client
  alias Engram.KeywordStore.Tantivy.Feed
  alias Engram.Logger.Metadata
  alias Engram.Native
  alias Engram.Vector.Qdrant

  require Logger

  @doc "True when this backend is the configured keyword store."
  @spec configured?() :: boolean()
  def configured?, do: Engram.KeywordStore.impl() == __MODULE__

  # Term counts per new chunk, tokenized here (before the transaction) under
  # the pass's filter key; `in_commit/3` writes them.
  @impl true
  def index(scope, entries), do: {:ok, %{}, terms(scope, entries)}

  @impl true
  def in_commit(scope, keep, pending), do: Feed.note_pass(scope, keep, pending || [])

  # A rewrite of existing points (resparse, DEK re-key): a full note pass, so
  # it carries the note's current point set like an index pass does.
  @impl true
  def upsert(scope, entries) do
    upserts = terms(scope, entries)
    Feed.note_pass(scope, Feed.note_points(scope.user_id, scope.note_id), upserts)
  end

  # No tenant: OrphanSweep's tenant-less point pass. kwsearch's own orphan
  # pass covers those (roadmap P2 task 3), so this names no shard.
  @impl true
  def delete_points(nil, _ids), do: :ok
  def delete_points(user_id, ids), do: Feed.delete_points(user_id, ids)

  @impl true
  def delete_note(user_id, vault_id, note_id, []),
    do: Feed.delete_note(%{user_id: user_id, vault_id: vault_id, note_id: note_id})

  def delete_note(user_id, vault_id, note_id, keep),
    do: Feed.note_pass(%{user_id: user_id, vault_id: vault_id, note_id: note_id}, keep, [])

  @impl true
  def delete_vault(user_id, vault_id), do: Feed.delete_vault(user_id, vault_id)

  @impl true
  def delete_user(user_id), do: Feed.delete_user(user_id)

  @impl true
  def search(sparse, search_opts) do
    case keyword_leg(sparse, search_opts) do
      {:ok, _hits} = ok -> ok
      {:error, reason} -> fallback(reason, :keyword_degraded)
    end
  end

  @impl true
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
    vaults = search_opts |> Keyword.get(:vault_id) |> List.wrap() |> Enum.map(&to_string/1)
    Client.search(to_string(user_id), vaults, sparse.indices, search_opts)
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

  defp terms(_scope, []), do: []

  defp terms(scope, entries) do
    texts = Enum.map(entries, &Map.fetch!(&1, :text))
    packed = Native.keyword_feed_terms(texts, scope.filter_key, scope.language)
    Enum.zip_with(entries, packed, fn e, t -> {e.id, t} end)
  end
end
