defmodule Engram.KeywordStore do
  @moduledoc """
  Where the keyword leg of search is STORED and searched (roadmap D4, P1).

  `Engram.KeywordIndex` is the codec (plaintext -> HMAC-keyed sparse
  vector). This is the storage seam: every write, delete and search of
  keyword data goes through these functions, so a backend can be added or
  retired without touching the callers.

  ## Write set and read store (roadmap P2 task 8)

  Writes and reads are configured apart, so the Tantivy rollout runs in
  reversible steps:

    * The sparse store (`:keyword_store`, a module implementing this
      behaviour, default `Engram.KeywordStore.QdrantSparse`) is ALWAYS
      written. There is no "stop sparse writes" mode yet: it is the last P2
      step, with its own release and its own yes, and `config/runtime.exs`
      refuses any setting that would stop them.
    * `:keyword_feed` (default false) ALSO writes the kwsearch feed
      (`Engram.KeywordStore.Tantivy`, a transactional outbox): dual-write.
    * `:keyword_read` (`:sparse`, the default, or `:tantivy`) picks the store
      searches read. `:tantivy` needs the feed on. Rolling reads back to the
      sparse store is a config flip, because it was never stopped.

  Self-host never sets either key, so it writes and reads the sparse store
  only, exactly as before the seam. All three keys read through
  `Engram.ServiceConfig` (per-process overridable in tests).

  ## The sparse store is colocated

  `QdrantSparse` keeps keyword data on the dense point: `index/2` returns
  the named vectors to put on each point, its deletes are no-ops (the dense
  delete at the same call site removes the point), and `hybrid_search/3`
  runs both legs in one Qdrant batch request.

  ## Filter contract (`search/2`, `hybrid_search/3`)

  `search_opts` is the keyword list `Engram.Search` builds: `:user_id`, the
  vault scope (`:vault_id`, one id or a list; absent for all of the user's
  vaults), `:note_scope` (`{:ids, ids}` or `{:exclude, ids}`, up to
  `Engram.Vector.Qdrant.max_note_ids/0`), and `:limit` up to
  `Engram.Vector.Qdrant.max_page/0`. Results are `%{qdrant_id, score}` maps
  keyed by the chunk's point id, the id space fusion merges on.
  """

  alias Engram.KeywordIndex
  alias Engram.KeywordStore.FeedKey
  alias Engram.KeywordStore.Tantivy
  alias Engram.ServiceConfig

  @type user_id :: String.t() | Ecto.UUID.t()
  @type point_id :: String.t()

  @typedoc """
  One chunk's keyword vector, keyed by its point id. `:text` (the encoded
  `context_text`) is present only while the feed is written, which
  re-counts it.
  """
  @type entry :: %{
          required(:id) => point_id(),
          required(:sparse) => KeywordIndex.packed_sparse(),
          optional(:text) => String.t()
        }

  @typedoc "The note the entries of one write belong to."
  @type scope :: %{user_id: user_id(), vault_id: term(), note_id: term()}

  @typedoc """
  Why a whole note's keyword docs go: `:deleted` (trash, hard delete: the
  deletion log records it), `:rebuild` (a purge ahead of a re-index) or
  `:replaced` (after a floor pass committed its new point set).
  """
  @type note_reason :: :deleted | :rebuild | :replaced

  @typedoc """
  `:purge` is the irreversible delete (account or vault hard delete),
  `:soft` a reversible drop of the derived index (inactivity soft delete,
  the vault cleanup before its purge point).
  """
  @type kind :: :purge | :soft

  @type result :: :ok | {:error, term()}

  @doc "Index a note's new keyword docs; returns the named vectors per dense point."
  @callback index(scope(), [entry()]) :: {:ok, %{point_id() => map()}} | {:error, term()}

  @doc "Rewrite the keyword vectors of existing chunk points (resparse, DEK re-key)."
  @callback upsert(scope(), [entry()]) :: result()

  @doc """
  Delete the listed points. `user_id` nil means the tenant is unknown:
  OrphanSweep's point pass scans Qdrant ids with no payload.
  """
  @callback delete_points(user_id() | nil, [point_id()]) :: result()

  @doc "Delete one note's points except `keep` (empty: all of them)."
  @callback delete_note(user_id(), term(), term(), keep :: [point_id()], note_reason()) ::
              result()

  @callback delete_vault(user_id(), vault_id :: term(), kind()) :: result()
  @callback delete_user(user_id(), kind()) :: result()

  @doc "Keyword-only search."
  @callback search(KeywordIndex.sparse(), search_opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Dense + keyword fused by point id (`Search.Fusion.rrf/2`)."
  @callback hybrid_search(dense :: term(), KeywordIndex.sparse(), search_opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "`hybrid_search/3`'s two ranked legs (dense, keyword), unfused."
  @callback hybrid_legs(dense :: term(), KeywordIndex.sparse(), search_opts :: keyword()) ::
              {:ok, [[map()]]} | {:error, term()}

  @doc "The sparse store: always written, read unless `:keyword_read` says `:tantivy`."
  @spec impl() :: module()
  def impl, do: ServiceConfig.get(:keyword_store, Engram.KeywordStore.QdrantSparse)

  @doc "True when the kwsearch feed is written (dual-write), or reads need it."
  @spec feed?() :: boolean()
  def feed?, do: ServiceConfig.get(:keyword_feed, false) == true or read() == :tantivy

  @doc "The store searches read: `:sparse` (default) or `:tantivy`."
  @spec read() :: :sparse | :tantivy
  def read, do: ServiceConfig.get(:keyword_read, :sparse)

  @doc """
  The index pass's keyword write: the sparse store's vectors for each dense
  point, and (feed on) the feed's term counts to write in the chunk-row
  transaction (`in_commit/3`). Tokenizing runs here, before that
  transaction, so it holds no row lock. `key` is nil while the feed is off.
  """
  @spec index(scope(), [entry()], FeedKey.t() | nil) ::
          {:ok, %{point_id() => map()}, term()} | {:error, term()}
  def index(scope, entries, key) do
    with {:ok, vectors} <- if(entries == [], do: {:ok, %{}}, else: impl().index(scope, entries)) do
      {:ok, vectors, if(feed?(), do: Tantivy.feed_terms(entries, key))}
    end
  end

  @doc """
  Inside the index pass's chunk-row transaction (the note row is locked):
  `keep` is the note's full point set after the pass. The feed's rows commit
  or roll back with the chunk rows. A no-op while the feed is off.
  """
  @spec in_commit(scope(), [point_id()], term()) :: :ok
  def in_commit(scope, keep, pending),
    do: if(feed?(), do: Tantivy.in_commit(scope, keep, pending || []), else: :ok)

  @spec upsert(scope(), [entry()], FeedKey.t() | nil) :: result()
  def upsert(_scope, [], _key), do: :ok

  def upsert(scope, entries, key),
    do: both(impl().upsert(scope, entries), fn -> Tantivy.upsert(scope, entries, key) end)

  @spec delete_points(user_id() | nil, [point_id()]) :: result()
  def delete_points(_user_id, []), do: :ok

  def delete_points(user_id, ids),
    do:
      both(impl().delete_points(str(user_id), ids), fn ->
        Tantivy.delete_points(str(user_id), ids)
      end)

  @spec delete_note(user_id(), term(), term(), [point_id()], note_reason()) :: result()
  def delete_note(user_id, vault_id, note_id, keep, reason) do
    {u, v} = {str(user_id), str(vault_id)}

    both(impl().delete_note(u, v, note_id, keep, reason), fn ->
      Tantivy.delete_note(u, v, note_id, keep, reason)
    end)
  end

  @spec delete_vault(user_id(), term(), kind()) :: result()
  def delete_vault(user_id, vault_id, kind) do
    {u, v} = {str(user_id), str(vault_id)}
    both(impl().delete_vault(u, v, kind), fn -> Tantivy.delete_vault(u, v, kind) end)
  end

  @spec delete_user(user_id(), kind()) :: result()
  def delete_user(user_id, kind),
    do:
      both(impl().delete_user(str(user_id), kind), fn ->
        Tantivy.delete_user(str(user_id), kind)
      end)

  @spec search(KeywordIndex.sparse(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(sparse, search_opts), do: reader().search(sparse, search_opts)

  @spec hybrid_search(term(), KeywordIndex.sparse(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def hybrid_search(dense, sparse, search_opts),
    do: reader().hybrid_search(dense, sparse, search_opts)

  @spec hybrid_legs(term(), KeywordIndex.sparse(), keyword()) ::
          {:ok, [[map()]]} | {:error, term()}
  def hybrid_legs(dense, sparse, search_opts),
    do: reader().hybrid_legs(dense, sparse, search_opts)

  defp reader, do: if(read() == :tantivy, do: Tantivy, else: impl())

  # The feed write runs whatever the sparse store returned (and only while
  # the feed is on); the first error wins.
  defp both(sparse, feed) do
    feed = if feed?(), do: feed.(), else: :ok
    if sparse == :ok, do: feed, else: sparse
  end

  defp str(nil), do: nil
  defp str(id), do: to_string(id)
end
