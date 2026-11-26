defmodule Engram.KeywordStore do
  @moduledoc """
  Where the keyword leg of search is STORED and searched (roadmap D4, P1).

  `Engram.KeywordIndex` is the codec (plaintext -> HMAC-keyed sparse
  vector). This is the storage seam: every write, delete and search of
  keyword data goes through these functions, so the backend can move off
  Qdrant (P2: Tantivy) without touching the callers.

  Every keyword write (`index/2` for the main index pass, `upsert/2` for
  an in-place rewrite) carries the note's user, vault and id, so a
  user-sharded backend can route it.

  Backend #1 is `Engram.KeywordStore.QdrantSparse`, which is what happened
  before the seam existed: the sparse `keyword` vector lives on the chunk's
  dense Qdrant point. It is the default everywhere (self-host and SaaS), so
  an upgrade needs no operator action. `:keyword_store` (read through
  `Engram.ServiceConfig`, per-process overridable in tests) picks another.

  ## Colocated backends

  A colocated backend keeps keyword data on the dense point, so:

    * `index/2` writes nothing and returns the named vectors to put on
      each dense point, so the one upsert writes both (as before);
    * the delete callbacks are no-ops, because the dense delete at the same
      call site removes the point and its keyword vector with it;
    * `hybrid_search/3` runs both legs in the one Qdrant batch request.

  A non-colocated backend writes in `index/2` and returns `%{}`. Every
  delete reaches the backend whether or not the dense delete succeeded
  (`Engram.Indexing.delete_points/2` and siblings). The parallel hybrid
  read (dense and keyword legs, then `Search.Fusion.rrf/2`) arrives with
  that backend in P2, and so does dropping sparse-only points from Qdrant
  (a chunk with no dense vector has nothing to put there).

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

  @typedoc """
  One chunk's keyword vector, keyed by its point id, and the text it was
  encoded from (a backend that stores raw term counts re-counts that text).
  """
  @type entry :: %{
          required(:id) => point_id(),
          required(:sparse) => KeywordIndex.packed_sparse(),
          optional(:text) => String.t()
        }

  @typedoc "The note the entries of one `upsert/2` belong to."
  @type scope :: %{
          required(:user_id) => user_id(),
          required(:vault_id) => term(),
          required(:note_id) => term(),
          optional(:filter_key) => binary(),
          optional(:language) => String.t() | nil
        }

  @type result :: :ok | {:error, term()}

  @doc """
  Index a note's new keyword docs (the main index pass). Returns, per point
  id, the named vectors a colocated backend wants on that dense point; a
  backend that stores keywords elsewhere returns `%{}` plus whatever it must
  write inside the chunk-row transaction (`pending`, handed to `in_commit/3`).
  Runs before that transaction, so CPU work (tokenizing) holds no row lock.
  """
  @callback index(scope(), [entry()]) ::
              {:ok, %{point_id() => map()}}
              | {:ok, %{point_id() => map()}, term()}
              | {:error, term()}

  @doc """
  Inside the index pass's chunk-row transaction (the note row is locked):
  `keep` is the note's full point set after the pass, `pending` what
  `index/2` returned. A transactional-outbox backend writes its feed rows
  here, so they commit or roll back with the chunk rows.
  """
  @callback in_commit(scope(), keep :: [point_id()], pending :: term()) :: :ok

  @optional_callbacks in_commit: 3

  @doc "Rewrite the keyword vectors of existing chunk points (resparse, DEK re-key)."
  @callback upsert(scope(), [entry()]) :: result()

  @doc """
  Delete the listed points. `user_id` nil means the tenant is unknown:
  OrphanSweep's point pass scans Qdrant ids with no payload. A sharded
  backend may treat that as a no-op and rely on its own orphan pass rather
  than fan the delete out to every shard.
  """
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

  @doc """
  `index/2` of the configured backend, always as `{:ok, vectors, pending}`
  (pending `nil` when the backend has nothing to write in the transaction).
  Called with no entries too: a pass that only drops or reuses chunks still
  changes the note's point set, which `in_commit/3` records.
  """
  @spec index(scope(), [entry()]) :: {:ok, %{point_id() => map()}, term()} | {:error, term()}
  def index(scope, entries) do
    case if(entries == [], do: {:ok, %{}}, else: impl().index(scope, entries)) do
      {:ok, vectors} -> {:ok, vectors, nil}
      {:ok, _vectors, _pending} = ok -> ok
      error -> error
    end
  end

  @doc "`in_commit/3` of the configured backend; a no-op where it has none."
  @spec in_commit(scope(), [point_id()], term()) :: :ok
  def in_commit(scope, keep, pending) do
    mod = impl()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :in_commit, 3),
      do: mod.in_commit(scope, keep, pending),
      else: :ok
  end

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
