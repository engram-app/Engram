defmodule Engram.Search.NameTerms do
  @moduledoc """
  The Postgres title and folder-name recall leg of search (O(1) folder rename
  plan, stage S1; Engram#2523 section 3.6).

  From R3a on, a rename writes nothing to Qdrant, so a renamed note's vectors
  keep its OLD filename and folder words until its next edit. This leg is how
  search still finds a note by its NEW name: a per-token posting table,
  `name_terms`, of note titles and filenames (`ref_kind` 0) and folder names
  (`ref_kind` 1). A row's `dim` is the keyword leg's sparse dimension
  (`Engram.KeywordIndex.QdrantSparse.dim/2`, HMAC under the user's DEK
  filter key) of one token of `Engram.KeywordIndex.Tokenizer` (English stems
  on both sides), folded to a signed int4. No plaintext token is stored.

  ## Writers

  Shared hooks every writer goes through (all Postgres only):

    * `on_note_written/2`: the index pass (`Engram.Indexing.run_in_commit`,
      under a savepoint; covers web and MCP creates and H1 title edits), note
      rename and move (`Notes.rename_note/5`, after its commit) and CRDT
      create / rename (`Notes.genesis_crdt_note/5`);
    * `put_folders/3`: folder create, revive and rename (`Engram.Folders.Rows`);
    * `on_note_deleted/2` (`Engram.Workers.DeleteNoteIndex`, every soft
      delete) and `on_folders_deleted/1` (`Folders.Rows` delete and merge
      retire): a deleted ref's rows go and its stamp is cleared, so a
      restore reads as stale and is rewritten;
    * DEK rotation (`resync/4`) and the self-heal (`heal_window/3`, the
      backfill chain `Engram.Workers.BackfillNameTerms` and
      `Engram.Bookkeeping.Drain`, which also sweeps orphans,
      `sweep_orphans/2`).

  A note's terms are the tokens of its title (frontmatter, else first H1,
  else filename) and of its filename stem; a folder's, the tokens of its own
  segment. At most #{32} distinct dims per ref, in token order.

  ## Self-heal

  Every write stamps its ref with `<<version>> <> hmac`: `notes.basename_hmac`
  or `folders.name_hmac`, the key of the name the terms were computed from,
  compare-and-set against the row (a stale or rotated key writes nothing). A
  writer that renames without rewriting the terms (the previous release, a
  rolling deploy, a rollback) leaves the stamp behind the hmac, and the
  partial indexes `notes_name_terms_stale` / `folders_name_terms_stale` hold
  exactly those rows: the backfill chain heals them, the drain heals what an
  older node writes after the ledger closed. A folder rename leaves its
  child notes' basenames, and so their stamps, alone. A name that never
  decrypts is stamped `<<0>> <> hmac` and leaves the index.

  Accepted (ranking only): a previous-release content edit that changes only
  the H1 title keeps the old title terms until this release's next index
  pass (Qdrant holds the new title); two concurrent index passes of one note
  with different titles can leave the union of both term sets.

  ## Search

  `leg/6` is the seam `Engram.Search` gathers its legs through (keyword and
  hybrid; `:vector` never gets it). On unless the `name_terms_search`
  override is false, from the first rename after deploy: not gated on the
  backfill, since a ref without terms is simply not found by this leg. Its
  notes are narrowed to the search's filters first (`Search.in_scope/3`),
  then fused into the Qdrant candidates by RRF (`Engram.Search.Fusion`,
  k = 2): exact-filename notes first (`HMAC(basename_key(query))`, one probe
  on the `basename_hmac` index), then notes by matching title terms, then
  the notes anywhere under matching folders. Each note stands for its first
  chunk's point, so every later step (hydrate, rerank, MMR) is the existing
  one. B2's re-rank can replace `fuse/3`.

  ## Cost per operation

    * note rename: read at most 32 term rows, delete plus insert at most 32,
      one stamp write; only that note's rows. A move keeps the basename, so
      it writes nothing.
    * folder create or rename: the same for that folder's rows only. Child
      notes and descendant folders are not touched.
    * note or folder delete: delete at most 32 rows, one stamp write.
    * index pass: the read; writes only when the title's terms changed.
    * search, constant in vault size and in notes per folder:
      - at most #{16} query terms x 2 kinds x #{2_000} postings scanned
        (index order), each one primary-key probe of its ref, of which at
        most #{500} live ones count (notes and folders have separate budgets;
        dead rows never fill the live budget; past #{2_000} dead rows on one
        term a live ref can be missed, counted as `scan_capped`, until the
        delete hooks or the orphan sweep remove them);
      - one exact-name probe;
      - folders: at most #{200} descendant folders, at most #{32} levels, one
        query per level; then at most #{50} notes per folder, cut to #{50};
      - one first-chunk probe (LIMIT 1) per note, at most #{3 * 50} notes;
      - one bounded filter resolve for a filtered search.
    * DEK rotation: one rewrite of the user's rows, O(notes + folders),
      Postgres only, no Voyage call.

  ## What it reveals

  Per user only (the dims are keyed by that user's DEK): to a reader of the
  database, which of that user's titles and folder names share a word, and
  how many words each has. No cross-user dictionary. A u32 collision is a
  ranking-only false positive.
  """

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Folders.Folder
  alias Engram.Folders.Rows
  alias Engram.KeywordIndex.QdrantSparse
  alias Engram.KeywordIndex.Tokenizer
  alias Engram.Links
  alias Engram.Logger.Metadata
  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Search.Fusion

  require Logger

  defmodule Row do
    @moduledoc "One `name_terms` posting (see `Engram.Search.NameTerms`)."
    use Ecto.Schema

    @primary_key false
    schema "name_terms" do
      field :vault_id, Ecto.UUID
      field :dim, :integer
      field :ref_kind, :integer
      field :ref_id, Ecto.UUID
      field :user_id, Ecto.UUID
    end
  end

  @version 1
  @max_terms 32
  @max_query_terms 16
  @postings 500
  @k 50
  @scan_cap 2_000
  @max_folders 200
  @max_depth 32
  @rrf_k 2
  @lang :en
  @note 0
  @folder 1

  @doc "The stamp version: bump it (and the stale indexes' text) to rewrite every ref."
  def version, do: @version

  @doc "Most term rows one ref holds."
  def max_terms, do: @max_terms

  @doc "Most postings the leg reads per query term."
  def postings, do: @postings

  # ---- terms ----------------------------------------------------------------

  @doc """
  The distinct dims of `texts`' tokens under `filter_key`, in token order,
  at most `cap`: the keyword leg's tokenizer and HMAC.
  """
  @spec dims([String.t() | nil], binary(), pos_integer()) :: [integer()]
  def dims(texts, filter_key, cap \\ @max_terms) do
    texts
    |> Enum.flat_map(&Tokenizer.tokens(&1 || "", @lang))
    |> Enum.uniq()
    |> Enum.map(&signed(QdrantSparse.dim(filter_key, &1)))
    |> Enum.uniq()
    |> Enum.take(cap)
  end

  defp signed(u32) do
    <<s::signed-32>> = <<u32::unsigned-32>>
    s
  end

  defp note_texts(path, title), do: [title, path |> Path.basename() |> Path.rootname()]

  # ---- writers --------------------------------------------------------------

  @doc """
  The single post-write hook of every note writer (index pass, rename, move,
  CRDT create and rename): rewrites the note's terms from its decrypted
  `path` and `title`. Inside a caller's transaction (the index pass commit)
  it runs under a savepoint, so a failure here rolls back only its own
  statements. Never fails the caller's write: any error is logged, and the
  stale stamp leaves the note to the self-heal.
  """
  @spec on_note_written(map() | Ecto.UUID.t(), map()) :: :ok
  def on_note_written(_user, %{kind: kind}) when kind not in [nil, "note"], do: :ok

  def on_note_written(user, %{id: id, path: path} = note) when is_binary(path) do
    with %{} = user <- load_user(user),
         {:ok, fk} <- Crypto.dek_filter_key(user) do
      ref = {id, note.vault_id, dims(note_texts(path, Map.get(note, :title)), fk), hmac(fk, path)}
      Repo.with_tenant!(user.id, fn -> savepoint(fn -> put(Repo, user.id, @note, [ref]) end) end)
    end

    :ok
  rescue
    e -> write_failed(e)
  end

  def on_note_written(_user, _note), do: :ok

  # In a transaction, a failed statement aborts it: isolate ours.
  defp savepoint(fun) do
    if Repo.in_transaction?() do
      _ = Repo.query!("SAVEPOINT s1_terms")

      try do
        result = fun.()
        _ = Repo.query!("RELEASE SAVEPOINT s1_terms")
        result
      rescue
        e ->
          _ = Repo.query!("ROLLBACK TO SAVEPOINT s1_terms")
          reraise e, __STACKTRACE__
      end
    else
      fun.()
    end
  end

  @doc """
  The folder writers' hook (`Engram.Folders.Rows` create and rename):
  `refs` are `{id, vault_id, segment}` of folder rows whose name was just
  written under `fk`. Runs in the caller's tenant transaction.
  """
  @spec put_folders(Ecto.UUID.t(), binary(), [{Ecto.UUID.t(), Ecto.UUID.t(), String.t()}]) :: :ok
  def put_folders(_user_id, _fk, []), do: :ok

  def put_folders(user_id, fk, refs) do
    put(
      Repo,
      user_id,
      @folder,
      for(
        {id, vault_id, segment} <- refs,
        do: {id, vault_id, dims([segment], fk), name_hmac(fk, segment)}
      )
    )
  end

  @doc """
  The shared delete hook of notes (`Engram.Workers.DeleteNoteIndex`, which
  every soft delete, trash and folder-delete cascade enqueues): the note's
  rows go, and its stamp is cleared so a restore reads as stale and the
  drain rewrites it. Postgres only, idempotent.
  """
  @spec on_note_deleted(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def on_note_deleted(user_id, note_id) do
    Repo.with_tenant!(user_id, fn -> forget(Repo, Note, @note, [note_id]) end)
  end

  @doc "`on_note_deleted/2` for folder rows (`Folders.Rows` delete and merge retire), in the caller's tenant."
  @spec on_folders_deleted([Ecto.UUID.t()]) :: :ok
  def on_folders_deleted([]), do: :ok
  def on_folders_deleted(ids), do: forget(Repo, Folder, @folder, ids)

  defp forget(repo, schema, kind, ids) do
    repo.delete_all(from(r in Row, where: r.ref_id in ^ids and r.ref_kind == ^kind))

    repo.update_all(
      from(r in schema,
        where: r.id in ^ids and not is_nil(r.deleted_at) and not is_nil(r.name_terms_stamp)
      ),
      set: [name_terms_stamp: nil]
    )

    :ok
  end

  @doc """
  One page of the orphan sweep (`Engram.Bookkeeping.Drain`): the next #{500}
  refs after `after_id` (on `name_terms_ref`), and the rows of those whose
  note or folder is gone or deleted are removed (a purge or an older
  release's delete that skipped `on_note_deleted/2`). `{refs_read, last_ref |
  nil, removed}`. `repo` is the scope's.
  """
  @spec sweep_orphans(module(), Ecto.UUID.t() | nil) ::
          {non_neg_integer(), Ecto.UUID.t() | nil, non_neg_integer()}
  def sweep_orphans(repo, after_id) do
    refs =
      from(r in Row,
        distinct: true,
        order_by: r.ref_id,
        limit: 500,
        select: {r.ref_id, r.ref_kind}
      )
      |> then(fn q -> if after_id, do: where(q, [r], r.ref_id > ^after_id), else: q end)
      |> repo.all()

    live =
      MapSet.new(
        live_ids(repo, Note, for({id, @note} <- refs, do: id)) ++
          live_ids(repo, Folder, for({id, @folder} <- refs, do: id))
      )

    dead = for {id, _} <- refs, not MapSet.member?(live, id), do: id

    {removed, _} =
      if dead == [],
        do: {0, nil},
        else: repo.delete_all(from(r in Row, where: r.ref_id in ^dead))

    {length(refs), refs |> List.last() |> then(&(&1 && elem(&1, 0))), removed}
  end

  defp live_ids(_repo, _schema, []), do: []

  defp live_ids(repo, Note, ids),
    do:
      repo.all(
        from(n in Note,
          where: n.id in ^ids and n.kind == "note" and is_nil(n.deleted_at),
          select: n.id
        )
      )

  defp live_ids(repo, Folder, ids),
    do: repo.all(from(f in Folder, where: f.id in ^ids and is_nil(f.deleted_at), select: f.id))

  defp hmac(fk, path), do: Crypto.hmac_field(fk, Links.basename_key(path))
  defp name_hmac(fk, segment), do: Folder.name_hmac(fk, segment)

  defp load_user(%Engram.Accounts.User{} = user), do: user

  defp load_user(user_id) when is_binary(user_id),
    do: Repo.get(Engram.Accounts.User, user_id)

  defp write_failed(e) do
    Logger.warning(
      "name_terms write failed; the self-heal rewrites it",
      Metadata.with_category(:warning, :search, reason: Metadata.safe_reason(e))
    )

    :ok
  end

  # `refs`: `{ref_id, vault_id, dims, hmac}`. Only the refs whose row still
  # carries `hmac` (the key and name the dims were computed from) are
  # written: a renamed-since or rotated-since row is the self-heal's. Reads
  # the refs' rows, deletes and inserts the difference, stamps what moved.
  defp put(repo, user_id, kind, refs) do
    schema = if kind == @note, do: Note, else: Folder
    current = current_refs(repo, schema, refs)
    refs = Enum.filter(refs, fn {id, _, _, _} -> Map.has_key?(current, id) end)

    if refs != [] do
      ids = Enum.map(refs, &elem(&1, 0))

      have =
        repo.all(
          from(r in Row,
            where: r.ref_id in ^ids and r.ref_kind == ^kind,
            select: {r.ref_id, r.vault_id, r.dim}
          )
        )
        |> MapSet.new()

      want = for {id, v, dims, _} <- refs, d <- dims, into: MapSet.new(), do: {id, v, d}

      drop(repo, kind, MapSet.difference(have, want))
      add(repo, user_id, kind, MapSet.difference(want, have))

      stale = for {id, _, _, h} <- refs, current[id] != stamp(h), do: {id, stamp(h)}
      stamp!(repo, schema, stale)
    end

    :ok
  end

  # %{id => stamp} for the refs whose row's hmac is the one given.
  defp current_refs(repo, schema, refs) do
    col = hmac_col(schema)

    repo.all(
      from(r in schema,
        join:
          v in fragment(
            "SELECT * FROM unnest(?::uuid[], ?::bytea[]) AS t(id, h)",
            ^Enum.map(refs, &Ecto.UUID.dump!(elem(&1, 0))),
            ^Enum.map(refs, &elem(&1, 3))
          ),
        on: r.id == field(v, :id) and field(r, ^col) == field(v, :h),
        select: {r.id, r.name_terms_stamp}
      )
    )
    |> Map.new()
  end

  defp hmac_col(Note), do: :basename_hmac
  defp hmac_col(Folder), do: :name_hmac

  defp stamp(hmac), do: <<@version>> <> hmac
  defp unreadable_stamp(hmac), do: <<0>> <> hmac

  defp drop(repo, kind, pairs) do
    if MapSet.size(pairs) > 0 do
      {ids, dims} =
        pairs |> Enum.map(fn {id, _v, d} -> {Ecto.UUID.dump!(id), d} end) |> Enum.unzip()

      repo.delete_all(
        from(r in Row,
          join:
            v in fragment("SELECT * FROM unnest(?::uuid[], ?::int4[]) AS t(id, dim)", ^ids, ^dims),
          on: r.ref_id == field(v, :id) and r.dim == field(v, :dim) and r.ref_kind == ^kind
        )
      )
    end
  end

  defp add(repo, user_id, kind, pairs) do
    rows =
      for {id, v, d} <- pairs,
          do: %{vault_id: v, dim: d, ref_kind: kind, ref_id: id, user_id: user_id}

    rows
    |> Enum.chunk_every(5_000)
    |> Enum.each(&repo.insert_all(Row, &1, on_conflict: :nothing))
  end

  defp stamp!(_repo, _schema, []), do: :ok

  defp stamp!(repo, schema, stamps) do
    {ids, values} = stamps |> Enum.map(fn {id, s} -> {Ecto.UUID.dump!(id), s} end) |> Enum.unzip()

    repo.update_all(
      from(r in schema,
        join:
          v in fragment("SELECT * FROM unnest(?::uuid[], ?::bytea[]) AS t(id, s)", ^ids, ^values),
        on: r.id == field(v, :id),
        update: [set: [name_terms_stamp: field(v, :s)]]
      ),
      []
    )

    :ok
  end

  # ---- self-heal --------------------------------------------------------------

  @doc """
  One id window of `Note` or `Folder` (`Engram.Backfill.IdWindows`): rewrites
  the terms of every stale live ref in it (the stale-index predicate), each
  under its owner's current key. `{fixed, left?}`; `left?` when a user's key
  could not be loaded. `ctx.repo` is the scope's (maintenance on the fleet).
  """
  @spec heal_window(module(), [Ecto.UUID.t()], map()) :: {non_neg_integer(), boolean()}
  def heal_window(schema, ids, %{repo: repo}) do
    schema
    |> stale_rows(repo, ids)
    |> Enum.group_by(& &1.user_id)
    |> Enum.reduce({0, false}, fn {user_id, rows}, {fixed, left?} ->
      case user_keys(repo, user_id) do
        {:ok, dek, fk} -> {fixed + rewrite(repo, schema, user_id, dek, fk, rows), left?}
        :no_dek -> {fixed, left?}
        :error -> {fixed, true}
      end
    end)
  end

  @doc """
  One user's stale refs of `schema`, at most #{1_000}, read off the stale
  index and healed in the user's tenant: the drain's repair. Returns how many.
  """
  @spec heal_user(module(), Ecto.UUID.t()) :: non_neg_integer()
  def heal_user(schema, user_id) do
    {:ok, fixed} =
      Repo.with_tenant(user_id, fn ->
        ids =
          from(r in stale_query(schema), where: r.user_id == ^user_id, limit: 1_000, select: r.id)
          |> Repo.all()

        if ids == [], do: 0, else: ids |> then(&heal_window(schema, &1, %{repo: Repo})) |> elem(0)
      end)

    fixed
  end

  @doc "The live refs of `schema` whose terms are stale: the stale partial indexes' predicate."
  @spec stale_query(Note | Folder) :: Ecto.Query.t()
  def stale_query(schema),
    do: from(r in schema) |> live(schema) |> stale_only(:stale, hmac_col(schema))

  defp live(query, Note),
    do:
      where(query, [n], n.kind == "note" and is_nil(n.deleted_at) and not is_nil(n.basename_hmac))

  defp live(query, Folder), do: where(query, [f], is_nil(f.deleted_at))

  @doc """
  DEK rotation (`Engram.Crypto.UserDekRotation`, before the flip, after the
  notes and folders sweeps re-keyed `basename_hmac` / `name_hmac`): every
  live ref of the user, rewritten under the NEW key. Postgres only.
  """
  @spec resync(Ecto.UUID.t(), binary(), binary(), module()) :: :ok
  def resync(user_id, new_dek, new_fk, schema) do
    Engram.Backfill.IdWindows.each_batch(user_id, schema, fn ids ->
      rows = stale_rows(schema, Repo, ids, :all)
      _ = rewrite(Repo, schema, user_id, new_dek, new_fk, rows)
      :ok
    end)
  end

  @doc "The stale-index predicate texts, by table (the drain probes and their pin test)."
  def stale_sql(:notes),
    do:
      "kind = 'note' AND deleted_at IS NULL AND basename_hmac IS NOT NULL " <>
        "AND name_terms_stamp IS DISTINCT FROM ('\\x01'::bytea || basename_hmac) " <>
        "AND name_terms_stamp IS DISTINCT FROM ('\\x00'::bytea || basename_hmac)"

  def stale_sql(:folders),
    do:
      "deleted_at IS NULL " <>
        "AND name_terms_stamp IS DISTINCT FROM ('\\x01'::bytea || name_hmac) " <>
        "AND name_terms_stamp IS DISTINCT FROM ('\\x00'::bytea || name_hmac)"

  defp stale_rows(schema, repo, ids, which \\ :stale)

  defp stale_rows(Note, repo, ids, which) do
    from(n in subquery(Engram.Backfill.IdWindows.by_id(Note, ids)),
      where: n.kind == "note" and is_nil(n.deleted_at) and not is_nil(n.basename_hmac),
      select: %{
        id: n.id,
        user_id: n.user_id,
        vault_id: n.vault_id,
        dek_version: n.dek_version,
        hmac: n.basename_hmac,
        path: {n.path_ciphertext, n.path_nonce},
        title: {n.title_ciphertext, n.title_nonce}
      }
    )
    |> stale_only(which, :basename_hmac)
    |> repo.all()
  end

  defp stale_rows(Folder, repo, ids, which) do
    from(f in Folder,
      where: f.id in ^ids and is_nil(f.deleted_at),
      select: %{
        id: f.id,
        user_id: f.user_id,
        vault_id: f.vault_id,
        dek_version: f.dek_version,
        hmac: f.name_hmac,
        name: {f.name_ciphertext, f.name_nonce}
      }
    )
    |> stale_only(which, :name_hmac)
    |> repo.all()
  end

  defp stale_only(query, :all, _col), do: query

  defp stale_only(query, :stale, col) do
    where(
      query,
      [r],
      fragment("? IS DISTINCT FROM ('\\x01'::bytea || ?)", r.name_terms_stamp, field(r, ^col)) and
        fragment("? IS DISTINCT FROM ('\\x00'::bytea || ?)", r.name_terms_stamp, field(r, ^col))
    )
  end

  defp user_keys(repo, user_id) do
    with %{} = user <- repo.get(Engram.Accounts.User, user_id),
         {:ok, dek} <- Crypto.get_dek(user) do
      {:ok, dek, Crypto.dek_filter_key_from_bytes(dek)}
    else
      {:error, :no_dek} -> :no_dek
      nil -> :no_dek
      _ -> :error
    end
  end

  # Decrypt, then write the readable refs and stamp the unreadable ones out
  # of the stale index. Returns the refs handled.
  defp rewrite(_repo, _schema, _user_id, _dek, _fk, []), do: 0

  defp rewrite(repo, schema, user_id, dek, fk, rows) do
    {readable, unreadable} =
      rows
      |> Enum.map(&{&1, texts(schema, dek, &1)})
      |> Enum.split_with(fn {_row, texts} -> texts != :error end)

    kind = if schema == Note, do: @note, else: @folder

    refs =
      for {row, texts} <- readable do
        case texts do
          {path, title} ->
            {row.id, row.vault_id, dims(note_texts(path, title), fk), hmac(fk, path)}

          [segment] ->
            {row.id, row.vault_id, dims([segment], fk), name_hmac(fk, segment)}
        end
      end

    put(repo, user_id, kind, refs)
    stamp!(repo, schema, for({row, _} <- unreadable, do: {row.id, unreadable_stamp(row.hmac)}))

    for(
      {row, _} <- unreadable,
      do:
        Logger.warning(
          "name_terms: name did not decrypt",
          Metadata.with_category(:warning, :search, user_id: user_id, row_id: row.id)
        )
    )

    length(rows)
  end

  # Note: {path, title}; folder: [segment].
  defp texts(Note, dek, row) do
    with {:ok, path} <- field(dek, :path, row),
         {:ok, title} <- title(dek, row) do
      {path, title}
    else
      _ -> :error
    end
  end

  defp texts(Folder, dek, %{name: {ct, nonce}} = row) do
    case Rows.decrypt_name(dek, row.id, row.dek_version, ct, nonce) do
      {:ok, segment} -> [segment]
      _ -> :error
    end
  end

  defp title(_dek, %{title: {nil, _}}), do: {:ok, nil}
  defp title(dek, row), do: field(dek, :title, row)

  defp field(dek, column, row) do
    {ct, nonce} = Map.fetch!(row, column)
    Rows.decrypt_field(dek, :notes, column, Ecto.UUID.dump!(row.id), row.dek_version, ct, nonce)
  end

  # ---- search -----------------------------------------------------------------

  @doc """
  Search's legs (`legs`, a function of the search opts returning
  `{:ok, candidates}`), with this leg fused in for a text query in keyword or
  hybrid mode (`:vector` is meaning only, so it never gets the leg). `scope`
  is `Search`'s vault scope; `keep` narrows a list of note ids to the ones
  the search's filters allow, so an out-of-scope name hit never takes a
  page slot from an in-scope Qdrant hit.
  """
  @spec leg(function(), map(), term(), atom(), term(), ([Ecto.UUID.t()] -> [Ecto.UUID.t()])) ::
          function()
  def leg(legs, user, scope, mode, query, keep)
      when mode in [:keyword, :hybrid] and is_binary(query) do
    names = if on?(), do: recall(user, scope, query, keep), else: []

    if names == [] do
      legs
    else
      fn opts ->
        with {:ok, candidates} <- legs.(opts),
             do: {:ok, fuse(candidates, names, Keyword.fetch!(opts, :limit))}
      end
    end
  end

  def leg(legs, _user, _scope, _mode, _query, _keep), do: legs

  @doc """
  On unless the `name_terms_search` override is false. Not gated on the
  backfill: a ref without terms yet is simply not found by this leg (search
  as before), and a renamed note must be findable from its first rename.
  """
  def on?, do: Engram.ServiceConfig.get(:name_terms_search, true) == true

  defp fuse(candidates, names, limit) do
    [Enum.map(candidates, &Map.put(&1, :id, &1.qdrant_id)), names]
    |> Fusion.rrf(@rrf_k)
    |> Enum.take(limit)
    |> Enum.map(&Map.delete(&1, :id))
  end

  @doc """
  The leg's ranked candidates, best first, at most #{3 * 50}: `%{id:
  point_id, qdrant_id: point_id, score: 0.0}` of each matched live note's
  first chunk, after `keep`. [] on no DEK, no query term or a database error
  (logged).
  """
  @spec recall(map(), term(), String.t(), ([Ecto.UUID.t()] -> [Ecto.UUID.t()])) :: [map()]
  def recall(user, scope, query, keep \\ & &1) do
    with {:ok, fk} <- Crypto.dek_filter_key(user),
         [_ | _] = dims <- dims([query], fk, @max_query_terms),
         [_ | _] = vault_ids <- vault_ids(user, scope),
         {:ok, [_ | _] = order} <-
           Repo.with_tenant(user.id, fn -> ranked(vault_ids, dims, fk, query) end),
         [_ | _] = kept <- keep.(order),
         {:ok, points} <- Repo.with_tenant(user.id, fn -> first_points(kept) end) do
      for id <- kept, p = points[id], do: %{id: p, qdrant_id: p, score: 0.0}
    else
      _ -> []
    end
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning(
        "name_terms leg failed; searching without it",
        Metadata.with_category(:warning, :search, reason: Metadata.safe_reason(e))
      )

      []
  end

  defp vault_ids(_user, {:vault, vault}), do: [vault.id]
  defp vault_ids(_user, {:ids, ids}), do: ids
  defp vault_ids(user, :all), do: user |> Engram.Vaults.list_vaults() |> Enum.map(& &1.id)

  # Live note ids, best first: exact filename, then by matched title terms,
  # then the notes under matching folders.
  defp ranked(vault_ids, dims, fk, query) do
    exact =
      Repo.all(
        from(n in Note,
          where:
            n.vault_id in ^vault_ids and n.basename_hmac == ^hmac(fk, query) and
              n.kind == "note" and is_nil(n.deleted_at),
          limit: ^@k,
          select: n.id
        )
      )

    titled = for {id, _n} <- hits(vault_ids, dims, @note), do: id
    folders = for {id, _n} <- hits(vault_ids, dims, @folder), do: id

    Enum.uniq(exact ++ titled ++ under_folders(vault_ids, folders))
  end

  @doc """
  The top #{50} live refs of `kind` (0 notes, 1 folders) for `dims` in
  `vault_ids`, `{ref_id, matched terms}` best first. Per dim at most #{2_000}
  postings of that kind are SCANNED (index order), each probed for liveness
  by its ref's primary key, and at most #{500} live ones count: notes and
  folders have separate budgets, and dead rows can never fill the live
  budget. A dim whose scan hits #{2_000} before #{500} live postings is
  counted in `[:engram, :search, :name_terms, :scan_capped]`: past that
  many dead rows a live ref may be missed until the delete hooks or the
  drain's orphan sweep remove them. Runs in the caller's tenant.
  """
  @spec hits([Ecto.UUID.t()], [integer()], 0 | 1) :: [{Ecto.UUID.t(), pos_integer()}]
  def hits(vault_ids, dims, kind) do
    per_dim = vault_ids |> hits_query(dims, kind) |> Repo.all()

    capped =
      Enum.count(per_dim, fn {scanned, live} ->
        scanned == @scan_cap and length(live) < @postings
      end)

    if capped > 0,
      do:
        :telemetry.execute([:engram, :search, :name_terms, :scan_capped], %{count: capped}, %{
          kind: kind
        })

    per_dim
    |> Enum.flat_map(fn {_scanned, live} -> Enum.take(live, @postings) end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {id, n} -> {-n, id} end)
    |> Enum.take(@k)
  end

  @doc false
  # Per dim: `{postings scanned, live ref ids}` (the query `hits/3` runs;
  # its plan test reads it).
  def hits_query(vault_ids, dims, kind) do
    {schema, on} =
      if kind == @note,
        do:
          {Note,
           dynamic([x: x, n: n], n.id == x.ref_id and n.kind == "note" and is_nil(n.deleted_at))},
        else: {Folder, dynamic([x: x, n: n], n.id == x.ref_id and is_nil(n.deleted_at))}

    from(q in fragment("SELECT unnest(?::int4[]) AS dim", ^dims),
      as: :q,
      inner_lateral_join: x in subquery(scan(vault_ids, kind)),
      as: :x,
      on: true,
      left_join: n in ^schema,
      as: :n,
      on: ^on,
      group_by: field(q, :dim),
      select:
        {count(x.ref_id),
         type(
           fragment(
             "coalesce((array_agg(?) FILTER (WHERE ? IS NOT NULL))[1:?], '{}')",
             x.ref_id,
             n.id,
             ^@postings
           ),
           {:array, Ecto.UUID}
         )}
    )
  end

  defp scan(vault_ids, kind) do
    from(r in Row,
      where:
        r.vault_id in ^vault_ids and r.ref_kind == ^kind and
          r.dim == field(parent_as(:q), :dim),
      limit: ^@scan_cap,
      select: %{ref_id: r.ref_id}
    )
  end

  @doc """
  The live notes anywhere under `folders` (best first), at most #{50},
  newest first (UUIDv7 ids: `id DESC` is creation order; not `updated_at`,
  which every save writes, so it is not indexed). Bounded on both sides: at most #{200} folders,
  walked breadth first over `folders_parent` (one query per level, at most
  #{32} levels), then at most #{50} notes per folder off
  `notes_folder_ref_live_id`, merged and cut to #{50}. Never reads more than
  #{200} x #{50} index entries, however many notes a folder holds.
  """
  @spec under_folders([Ecto.UUID.t()], [Ecto.UUID.t()]) :: [Ecto.UUID.t()]
  def under_folders(_vault_ids, []), do: []

  def under_folders(vault_ids, folders) do
    tree = descendants(vault_ids, folders)

    from(
      f in fragment(
        "SELECT * FROM unnest(?::uuid[], ?::uuid[]) AS t(id, vault_id)",
        type(^Enum.map(tree, &elem(&1, 0)), {:array, Ecto.UUID}),
        type(^Enum.map(tree, &elem(&1, 1)), {:array, Ecto.UUID})
      ),
      as: :f,
      inner_lateral_join: n in subquery(newest_in_folder()),
      on: true,
      order_by: [desc: n.id],
      limit: ^@k,
      select: n.id
    )
    |> Repo.all()
  end

  defp newest_in_folder do
    from(n in Note,
      where:
        n.vault_id == field(parent_as(:f), :vault_id) and
          n.folder_ref_id == field(parent_as(:f), :id) and n.kind == "note" and
          is_nil(n.deleted_at),
      order_by: [desc: n.id],
      limit: ^@k,
      select: %{id: n.id}
    )
  end

  # `{id, vault_id}` of the live roots and their descendants, at most
  # `@max_folders`, shallowest first.
  defp descendants(vault_ids, roots) do
    level =
      Repo.all(
        from(f in Folder,
          where: f.id in ^roots and f.vault_id in ^vault_ids and is_nil(f.deleted_at),
          select: {f.id, f.vault_id}
        )
      )

    walk(vault_ids, level, level, @max_depth)
  end

  defp walk(_vault_ids, acc, [], _depth), do: acc
  defp walk(_vault_ids, acc, _frontier, 0), do: acc

  defp walk(vault_ids, acc, frontier, depth) do
    case @max_folders - length(acc) do
      left when left <= 0 ->
        Enum.take(acc, @max_folders)

      left ->
        parents = Enum.map(frontier, &elem(&1, 0))

        kids =
          Repo.all(
            from(f in Folder,
              where:
                f.vault_id in ^vault_ids and f.parent_id in ^parents and is_nil(f.deleted_at),
              limit: ^left,
              select: {f.id, f.vault_id}
            )
          )

        walk(vault_ids, acc ++ kids, kids, depth - 1)
    end
  end

  # %{note_id => point id of its first chunk}: one `chunks_note_id_position`
  # probe per note (LIMIT 1), never the note's other chunks.
  defp first_points(note_ids) do
    first =
      from(c in Chunk,
        where: c.note_id == field(parent_as(:n), :id) and not is_nil(c.qdrant_point_id),
        order_by: c.position,
        limit: 1,
        select: %{point: c.qdrant_point_id}
      )

    from(n in fragment("SELECT unnest(?::uuid[]) AS id", type(^note_ids, {:array, Ecto.UUID})),
      as: :n,
      inner_lateral_join: c in subquery(first),
      on: true,
      select: {type(field(n, :id), Ecto.UUID), c.point}
    )
    |> Repo.all()
    |> Map.new(fn {n, p} -> {n, to_string(p)} end)
  end
end
