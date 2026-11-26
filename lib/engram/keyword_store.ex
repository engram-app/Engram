defmodule Engram.KeywordStore do
  @moduledoc """
  Where the keyword leg of search is STORED and searched (roadmap D4, P1).

  `Engram.KeywordIndex` is the codec (plaintext -> HMAC-keyed sparse
  vector). This is the storage seam: every write, delete and search of
  keyword data goes through these functions, so the backend can move off
  Qdrant (P2: Tantivy) without touching the callers.

  Backend #1 is `Engram.KeywordStore.QdrantSparse`, which is what happened
  before the seam existed: the sparse `keyword` vector lives on the chunk's
  dense Qdrant point. It is the default everywhere (self-host and SaaS), so
  an upgrade needs no operator action. `:keyword_store` (read through
  `Engram.ServiceConfig`, per-process overridable in tests) picks another.

  ## Colocated backends

  A colocated backend keeps keyword data on the dense point, so:

    * the main index write puts the backend's `point_vectors/1` on the
      dense point it upserts anyway (one request, as before);
    * the delete callbacks are no-ops, because the dense delete at the same
      call site removes the point and its keyword vector with it;
    * `hybrid_search/3` runs both legs in the one Qdrant batch request.

  Every call site still calls the delete functions here, so a backend that
  stores keywords elsewhere gets every delete. The non-colocated write and
  hybrid read (dense and keyword in parallel, then `Search.Fusion.rrf/2`)
  arrive with that backend in P2.

  ## Filter contract (`search/2`, `hybrid_search/3`)

  `search_opts` is the keyword list `Engram.Search` builds: `:user_id`, the
  vault scope (`:vault_id`, one id or a list), `:note_scope` (`{:ids, ids}`
  or `{:exclude, ids}`, up to `Engram.Vector.Qdrant.max_note_ids/0`), and
  `:limit` up to `Engram.Vector.Qdrant.max_page/0` (the `:too_wide`
  oversample; Search post-filters those hits in Postgres). Results are
  `%{qdrant_id, score}` maps keyed by the chunk's point id, the id space
  fusion merges on.
  """

  alias Engram.KeywordIndex

  @type user_id :: String.t() | Ecto.UUID.t()
  @type point_id :: String.t()

  @typedoc "One chunk's keyword vector, keyed by its point id."
  @type entry :: %{id: point_id(), sparse: KeywordIndex.packed_sparse()}

  @typedoc "The note the entries of one `upsert/2` belong to."
  @type scope :: %{user_id: user_id(), vault_id: term(), note_id: term()}

  @type result :: :ok | {:error, term()}

  @doc "The named vectors a colocated backend adds to the chunk's dense point (`%{}` if none)."
  @callback point_vectors(KeywordIndex.packed_sparse()) :: map()

  @doc "Rewrite the keyword vectors of existing chunk points (resparse, DEK re-key)."
  @callback upsert(scope(), [entry()]) :: result()

  @doc "Delete the listed points. `user_id` is nil when the tenant is unknown (orphan sweep)."
  @callback delete_points(user_id() | nil, [point_id()]) :: result()

  @doc "Delete one note's points except `keep` (empty: all of them)."
  @callback delete_note(user_id(), vault_id :: term(), note_id :: term(), keep :: [point_id()]) ::
              result()

  @callback delete_vault(user_id(), vault_id :: term()) :: result()
  @callback delete_user(user_id()) :: result()

  @doc "Keyword-only search."
  @callback search(KeywordIndex.sparse(), search_opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Dense + keyword fused by point id (`Search.Fusion.rrf/2`)."
  @callback hybrid_search(dense :: term(), KeywordIndex.sparse(), search_opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "The configured backend."
  @spec impl() :: module()
  def impl, do: Engram.ServiceConfig.get(:keyword_store, Engram.KeywordStore.QdrantSparse)

  @spec point_vectors(KeywordIndex.packed_sparse()) :: map()
  def point_vectors(sparse), do: impl().point_vectors(sparse)

  @spec upsert(scope(), [entry()]) :: result()
  def upsert(_scope, []), do: :ok
  def upsert(scope, entries), do: impl().upsert(scope, entries)

  @spec delete_points(user_id() | nil, [point_id()]) :: result()
  def delete_points(_user_id, []), do: :ok
  def delete_points(user_id, ids), do: impl().delete_points(str(user_id), ids)

  @spec delete_note(user_id(), term(), term(), [point_id()]) :: result()
  def delete_note(user_id, vault_id, note_id, keep \\ []),
    do: impl().delete_note(str(user_id), str(vault_id), note_id, keep)

  @spec delete_vault(user_id(), term()) :: result()
  def delete_vault(user_id, vault_id), do: impl().delete_vault(str(user_id), str(vault_id))

  @spec delete_user(user_id()) :: result()
  def delete_user(user_id), do: impl().delete_user(str(user_id))

  @spec search(KeywordIndex.sparse(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(sparse, search_opts), do: impl().search(sparse, search_opts)

  @spec hybrid_search(term(), KeywordIndex.sparse(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def hybrid_search(dense, sparse, search_opts),
    do: impl().hybrid_search(dense, sparse, search_opts)

  defp str(nil), do: nil
  defp str(id), do: to_string(id)
end
