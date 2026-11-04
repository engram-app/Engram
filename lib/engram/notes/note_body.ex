defmodule Engram.Notes.NoteBody do
  @moduledoc """
  A note's body, 1:1 with `notes` (migration 20261021110100): materialized
  content, CRDT state and manifest head.

  Written by one function, `sync!/3`, which every app writer of the `notes`
  body columns calls after its `notes` write, in the same transaction. R8
  (stop storing every body twice) runs in three releases: N added `sync!/3`
  beside the `notes_sync_body` trigger, N+1 dropped the trigger
  (20261104000000), so a raw `notes` write that skips `sync!/3` no longer
  reaches this table; N+2 stops writing the `notes` body columns. Order
  matters: nulling the `notes` columns under a live trigger would copy the
  NULLs here, so N+2 must refuse to run while the trigger exists.

  Wave 3 migrate-data (`docs/context/notes-chunks-hyperopt.md` 6.1 step 2):
  every READ of a body column goes through `select_note/2` (or `join/1` +
  `fields/1` where a caller builds its own select), so the body comes from
  this table. The `notes` columns are still written (the previous release
  reads them: `docs/context/migrate-data-rollback-trap.md`); a later
  contract release stops writing and drops them.

  `content_ct` / `crdt_ct` hold `nonce || ciphertext`
  (`Engram.Crypto.Envelope.split_merged/1`). The read splits them back in
  SQL, so a loaded `%Note{}` carries the same `{ciphertext, nonce}` pair the
  `notes` columns hold, byte for byte: fences that compare
  `crdt_state_nonce` against the `notes` row still match, and every decrypt
  path is unchanged. `crdt_head` comes back as the 43-char url-safe base64
  `notes.crdt_head` stores.

  A note with no body row (written before the trigger, before the
  `NoteSplit` ledger reaches it) reads its `notes` columns instead, per row.
  So no ledger gate is needed: a skip-release self-host reads right while
  its ledger runs, and a reopened ledger that finds a missed row costs nothing.
  The fallback is a `CASE` branch, so when the body row exists Postgres
  never de-TOASTs the `notes` copy. `NoteSplit` REPORTS a body row that
  disagrees with its notes row (`drift/0`) and never repairs it: from the
  next release on, the body is the newer side.

  Row-locked reads (`Notes.lock_for_write/2`, DEK rotation) lock the notes
  row in one statement and read the body from here in a fresh one
  (`locked_bodies/2`): a single statement that waits on the row lock
  re-fetches only the locked relation (EvalPlanQual), so a joined body row
  would be the pre-wait version (LockedReadBodyTest). No lock is needed on
  this table: every writer of a body row holds that note's `notes` row lock
  (`sync!/3` runs after a `notes` write in the same transaction; the
  cascade runs inside the `notes` DELETE), so once the reader holds it, the
  fresh statement sees the last committed body and nothing can change it
  until the reader commits.

  Write fences (`snapshot_fence`, `rename_fence`, `snapshot_fenced`) compare
  the `notes.crdt_state_nonce` column (inline, never TOASTed) against the
  nonce a read split from here. They must stay on a `notes` column: a fence
  that reads `note_bodies` inside the `notes` UPDATE sees the pre-wait body
  after a lock wait (the same EvalPlanQual rule), so it would pass against a
  checkpoint that committed meanwhile. The release that stops writing the
  `notes` body columns must keep writing the two nonce columns (or another
  per-write stamp on `notes`) for them.
  """
  use Ecto.Schema

  import Ecto.Query

  alias Engram.Notes.Note
  alias Engram.Repo

  @primary_key {:note_id, :binary_id, autogenerate: false}
  schema "note_bodies" do
    field :user_id, :binary_id
    field :key_version, :integer
    field :content_ct, :binary
    field :crdt_ct, :binary
    field :crdt_head, :binary
    # Stored payload bytes, set by the `note_bodies_sizes` BEFORE trigger
    # (migration 20261103130000); `state_bytes` NULL without CRDT state.
    field :content_bytes, :integer
    field :state_bytes, :integer
  end

  @body [
    :content_ciphertext,
    :content_nonce,
    :crdt_state_ciphertext,
    :crdt_state_nonce,
    :crdt_head
  ]

  # The `notes` columns each body field is copied from.
  @sources [
    content: [:content_ciphertext, :content_nonce],
    crdt: [:crdt_state_ciphertext, :crdt_state_nonce],
    head: [:crdt_head]
  ]

  # The trigger's merged layout of one `notes` (ciphertext, nonce) pair.
  merged = fn ct, nonce ->
    """
    CASE WHEN n.#{ct} IS NULL THEN NULL
      WHEN n.#{nonce} IS NULL THEN n.#{ct}
      WHEN length(n.#{nonce}) = 13 THEN n.#{nonce} || n.#{ct}
      ELSE '\\x00'::bytea || n.#{nonce} || n.#{ct} END
    """
  end

  # True when body column `body` does not hold `merged` of (ct, nonce):
  # NULL-ness, length, nonce field (first 13 bytes) and tag (last 16).
  differs = fn body, ct, nonce ->
    prefix =
      "CASE WHEN n.#{nonce} IS NULL THEN ''::bytea WHEN length(n.#{nonce}) = 13 " <>
        "THEN n.#{nonce} ELSE '\\x00'::bytea || n.#{nonce} END"

    """
    ((b.#{body} IS NULL) <> (n.#{ct} IS NULL) OR (n.#{ct} IS NOT NULL AND (
      octet_length(b.#{body}) <> octet_length(n.#{ct}) + octet_length(#{prefix})
      OR substring(b.#{body} FROM 1 FOR 13)
        <> substring((#{prefix}) || substring(n.#{ct} FROM 1 FOR 13) FROM 1 FOR 13)
      OR substring(b.#{body} FROM greatest(octet_length(b.#{body}) - 15, 1))
        <> substring(n.#{ct} FROM greatest(octet_length(n.#{ct}) - 15, 1)))))
    """
  end

  key_version = "CASE WHEN n.dek_version BETWEEN 0 AND 32767 THEN n.dek_version ELSE 0 END"

  head =
    "CASE WHEN n.crdt_head ~ '^[A-Za-z0-9_-]{43}$' " <>
      "THEN decode(translate(n.crdt_head, '-_', '+/') || '=', 'base64') END"

  content = merged.("content_ciphertext", "content_nonce")
  crdt = merged.("crdt_state_ciphertext", "crdt_state_nonce")

  # Per body field: its SET clause and its "differs" test.
  copy = %{
    content:
      {"content_ct = #{content}", differs.("content_ct", "content_ciphertext", "content_nonce")},
    crdt: {"crdt_ct = #{crdt}", differs.("crdt_ct", "crdt_state_ciphertext", "crdt_state_nonce")},
    head: {"crdt_head = #{head}", "b.crdt_head IS DISTINCT FROM #{head}"}
  }

  # One statement per set of fields a write touched (`sync!/3`): update the
  # body rows that exist and differ in those fields (plus the owner and key
  # version, which live on `notes` for good), insert the missing ones whole.
  # Both CTEs read the statement's snapshot, so a row is in exactly one of
  # them. Built at compile time for every subset (eight).
  @sync_sql (for content? <- [false, true],
                 crdt? <- [false, true],
                 head? <- [false, true],
                 into: %{} do
               fields =
                 for {f, true} <- [content: content?, crdt: crdt?, head: head?], do: f

               set =
                 Enum.map_join(fields, "", fn f -> ",\n      " <> elem(copy[f], 0) end)

               diff = Enum.map_join(fields, "", fn f -> " OR " <> elem(copy[f], 1) end)

               {fields,
                """
                WITH upd AS (
                  UPDATE note_bodies b SET
                    user_id = n.user_id,
                    key_version = #{key_version}#{set}
                  FROM notes n
                  WHERE b.note_id = n.id AND n.id = ANY($1) AND n.kind = 'note'
                    AND (b.user_id <> n.user_id OR b.key_version <> #{key_version}#{diff})
                  RETURNING 1
                ), ins AS (
                  INSERT INTO note_bodies (note_id, user_id, key_version, content_ct, crdt_ct, crdt_head)
                  SELECT n.id, n.user_id, #{key_version}, #{content}, #{crdt}, #{head}
                  FROM notes n
                  WHERE n.id = ANY($1) AND n.kind = 'note'
                    AND NOT EXISTS (SELECT 1 FROM note_bodies x WHERE x.note_id = n.id)
                  ON CONFLICT (note_id) DO NOTHING
                  RETURNING 1
                )
                SELECT ((SELECT count(*) FROM upd) + (SELECT count(*) FROM ins))::int
                """}
             end)

  # The ids among $1 whose body row exists and disagrees with its notes row
  # in any copied column: the same per-field tests `sync!/3` writes on, all
  # fields at once (`drift_ids/2`).
  all_differ = Enum.map_join([:content, :crdt, :head], " OR ", &elem(copy[&1], 1))

  @drift_sql """
  SELECT n.id::text FROM notes n JOIN note_bodies b ON b.note_id = n.id
  WHERE n.id = ANY($1) AND n.kind = 'note'
    AND (b.user_id <> n.user_id OR b.key_version <> #{key_version} OR #{all_differ})
  """

  @doc """
  Every `Note` field except the CRDT state, about half of a note's stored
  bytes: for reads that need the content but never the doc.
  """
  @spec without_crdt() :: [atom()]
  def without_crdt, do: Note.__schema__(:fields) -- [:crdt_state_ciphertext, :crdt_state_nonce]

  @doc "The `Note` fields that live in `note_bodies`."
  def body_fields, do: @body

  @doc """
  `query` (its first binding a `Note`) selecting `fields` (default: every
  field) as a `%Note{}`, the body fields read from `note_bodies`. A field
  list with no body field adds no join.
  """
  @spec select_note(Ecto.Queryable.t(), [atom()]) :: Ecto.Query.t()
  def select_note(query, fields \\ Note.__schema__(:fields)) do
    query = from(n in query, select: struct(n, ^(fields -- @body)))

    case Enum.filter(@body, &(&1 in fields)) do
      [] -> query
      body -> query |> join() |> select_merge(^fields(body))
    end
  end

  @doc """
  As `select_note/2`, but selecting a map that also carries `extra`
  (`%{key => dynamic}`) evaluated in the same statement (a tail read, a
  stored size). `to_note/2` turns a row back into `{%Note{}, extras}`.
  """
  @spec select_map(Ecto.Queryable.t(), [atom()], %{atom() => Ecto.Query.dynamic_expr()}) ::
          Ecto.Query.t()
  def select_map(query, fields, extra) do
    core = Map.new(fields -- @body, fn f -> {f, dynamic([n], field(n, ^f))} end)
    selected = core |> Map.merge(fields(Enum.filter(@body, &(&1 in fields)))) |> Map.merge(extra)
    query |> join() |> select(^selected)
  end

  @doc "A `select_map/3` row as `{%Note{}, %{extra_key => value}}`."
  @spec to_note(map(), [atom()]) :: {Note.t(), map()}
  def to_note(row, extra_keys) do
    {extras, fields} = Map.split(row, extra_keys)
    {Note |> struct(fields) |> Ecto.put_meta(state: :loaded), extras}
  end

  @doc "The note row with primary key `id` (any kind), body from `note_bodies`."
  @spec get(Ecto.UUID.t(), [atom()]) :: Note.t() | nil
  def get(id, fields \\ Note.__schema__(:fields)) do
    Note |> where([n], n.id == ^id) |> select_note(fields) |> Repo.one()
  end

  @doc """
  The body fields of the notes `ids`, from here, as `%{id => %{field =>
  value}}`, for a caller that already holds those notes rows' lock (see the
  moduledoc). Notes only: a folder row has no body and no entry.
  `repo_opts` go to the read (`skip_tenant_check:`).
  """
  @spec locked_bodies([Ecto.UUID.t()], keyword()) :: %{Ecto.UUID.t() => map()}
  def locked_bodies([], _repo_opts), do: %{}

  def locked_bodies(ids, repo_opts) do
    from(n in Note, where: n.id in ^ids and n.kind == "note")
    |> select_map([:id | @body], %{})
    |> Repo.all(repo_opts)
    |> Map.new(fn row -> {row.id, Map.take(row, @body)} end)
  end

  @doc """
  Brings the `note_bodies` rows of the notes `ids` in step with the `notes`
  body columns a write just set, with the mapping the dropped
  `notes_sync_body` trigger defined (20261021110200), and returns how many
  rows it wrote. The one function every app writer of a `notes` body column
  (content, CRDT state, head, `dek_version`) calls after that write, in the
  same transaction, so the `notes` rows are already locked (`notes` before
  `note_bodies`).

  `written` names the `notes` columns the write set (a list, or the
  keyword list / changes map it wrote), and only the body fields copied
  from those are compared and copied, as the trigger copied only the
  columns whose nonce changed. That is load-bearing for the release that
  stops writing the `notes` body columns: an older node beside it must not
  copy a stale `notes` column it did not write over a newer body. A CRDT
  state write also copies the head (the `notes_crdt_head_invalidate`
  trigger NULLs it). The owner and key version (`dek_version`, which stays
  on `notes`) are always kept in step. A missing body row (written before
  the body table) is inserted whole.

  Compared cheaply: per body column its NULL-ness, its length, the 13-byte
  nonce field and the 16-byte AEAD tag (slices of an EXTERNAL value, so
  nothing is de-TOASTed; every encryption takes a fresh nonce, so a new
  nonce names a new ciphertext). A row already in step is not touched.

  Emits `[:engram, :note_body, :sync_wrote]` (`%{count: rows}`) when it
  wrote anything (`engram_prom_ex_notes_body_sync_wrote_rows_total`): the
  body write rate.

  Options: `:repo` (default `Engram.Repo`, or the maintenance repo a ledger
  runs on); the rest go to the query (`mode: :savepoint`,
  `skip_tenant_check:` is ignored by raw SQL and harmless).
  """
  @spec sync!(Ecto.UUID.t() | [Ecto.UUID.t()], [atom()] | keyword() | map(), keyword()) ::
          non_neg_integer()
  def sync!(ids, written, opts \\ [])
  def sync!(id, written, opts) when is_binary(id), do: sync!([id], written, opts)
  def sync!([], _written, _opts), do: 0

  def sync!(ids, written, opts) when is_list(ids) do
    {repo, opts} = Keyword.pop(opts, :repo, Repo)
    sql = Map.fetch!(@sync_sql, synced_fields(written))
    %{rows: [[n]]} = repo.query!(sql, [Enum.map(ids, &Ecto.UUID.dump!/1)], opts)
    if n > 0, do: :telemetry.execute([:engram, :note_body, :sync_wrote], %{count: n}, %{})
    n
  end

  defp synced_fields(written) when is_map(written), do: synced_fields(Map.keys(written))

  defp synced_fields(written) when is_list(written) do
    cols =
      Enum.map(written, fn
        {col, _} -> col
        col -> col
      end)

    # A CRDT state write also resets the head (`notes_crdt_head_invalidate`).
    cols = if Enum.any?(@sources[:crdt], &(&1 in cols)), do: [:crdt_head | cols], else: cols
    for {field, srcs} <- @sources, Enum.any?(srcs, &(&1 in cols)), do: field
  end

  @doc """
  Left-joins `note_bodies` as the `:note_body` binding (once).

  Matches `user_id` as well as `note_id`: a caller's `n.user_id == ^id`
  then reaches `note_bodies` as an index condition (`note_bodies_user_note_head`),
  so a vault-wide join reads the owner's bodies, not every tenant's (R5).
  `sync!/3` writes the note's own `user_id`, so no row changes sides.
  """
  @spec join(Ecto.Queryable.t()) :: Ecto.Query.t()
  def join(query) do
    if has_named_binding?(query, :note_body),
      do: query,
      else:
        from(n in query,
          left_join: b in __MODULE__,
          as: :note_body,
          on: b.note_id == n.id and b.user_id == n.user_id
        )
  end

  @doc """
  `%{field => expression}` for body `fields`, for a `select_merge` on a
  query that went through `join/1`.
  """
  @spec fields([atom()]) :: %{atom() => Ecto.Query.dynamic_expr()}
  def fields(fields), do: Map.new(fields, &{&1, field_expr(&1)})

  @doc """
  `crdt_head` as `fields([:crdt_head])` reads it, for a whole-vault read
  whose `notes` side must stay an index-only scan (the sync manifest on
  `notes_manifest`, which does not carry the head: head stores would lose
  HOT on `notes`). The no-body fallback reads `notes.crdt_head` by a per-row
  primary-key subquery that only a row without a body runs, instead of as a
  column of the outer scan. EngramWeb.SyncManifestPlanTest.
  """
  @spec head_off_notes_scan() :: Ecto.Query.dynamic_expr()
  def head_off_notes_scan,
    do:
      head_expr(
        dynamic([n], fragment("(SELECT h.crdt_head FROM notes AS h WHERE h.id = ?)", n.id))
      )

  # The ciphertext starts at byte 14 in both merged formats: a format 1
  # nonce field is 13 bytes (leading 1), a format 0 nonce (12 bytes) sits
  # behind a 0 byte. `substring ... FOR n` reads a slice of an EXTERNAL
  # value, so the nonce costs a 13-byte fetch; the ciphertext (`FROM 14`,
  # no length) is the full value.
  defp field_expr(:content_ciphertext), do: ct_expr(:content_ct, :content_ciphertext)
  defp field_expr(:content_nonce), do: nonce_expr(:content_ct, :content_nonce)
  defp field_expr(:crdt_state_ciphertext), do: ct_expr(:crdt_ct, :crdt_state_ciphertext)
  defp field_expr(:crdt_state_nonce), do: nonce_expr(:crdt_ct, :crdt_state_nonce)

  defp field_expr(:crdt_head), do: head_expr(dynamic([n], n.crdt_head))

  # The body's 32-byte digest as the url-safe, unpadded base64
  # `notes.crdt_head` holds (a 32-byte base64 is 44 chars, one `=`, no line
  # break); `fallback` (the notes-side head) for a note with no body row.
  defp head_expr(fallback) do
    dynamic(
      [n, note_body: b],
      type(
        fragment(
          "CASE WHEN ? IS NULL THEN ? ELSE rtrim(translate(encode(?, 'base64'), '+/', '-_'), '=') END",
          b.note_id,
          ^fallback,
          b.crdt_head
        ),
        :string
      )
    )
  end

  defp ct_expr(body, notes) do
    dynamic(
      [n, note_body: b],
      type(
        fragment(
          "CASE WHEN ? IS NULL THEN ? ELSE substring(? FROM 14) END",
          b.note_id,
          field(n, ^notes),
          field(b, ^body)
        ),
        :binary
      )
    )
  end

  defp nonce_expr(body, notes) do
    dynamic(
      [n, note_body: b],
      type(
        fragment(
          "CASE WHEN ? IS NULL THEN ? WHEN substring(? FROM 1 FOR 1) = '\\x01'::bytea THEN substring(? FROM 1 FOR 13) ELSE substring(? FROM 2 FOR 12) END",
          b.note_id,
          field(n, ^notes),
          field(b, ^body),
          field(b, ^body),
          field(b, ^body)
        ),
        :binary
      )
    )
  end

  @doc """
  The byte length of a note's content (`:content`) or CRDT state (`:crdt`)
  ciphertext, from its body row (less the merged nonce field), else from
  `notes`. `octet_length` reads the varlena header, so nothing is
  de-TOASTed. For byte budgets and size metrics on a query through `join/1`.
  """
  @spec byte_length(:content | :crdt) :: Ecto.Query.dynamic_expr()
  def byte_length(:content), do: length_expr(:content_ct, :content_ciphertext)
  def byte_length(:crdt), do: length_expr(:crdt_ct, :crdt_state_ciphertext)

  defp length_expr(body, notes) do
    dynamic(
      [n, note_body: b],
      fragment(
        "coalesce(CASE WHEN ? IS NULL THEN octet_length(?) ELSE octet_length(?) - 13 END, 0)",
        b.note_id,
        field(n, ^notes),
        field(b, ^body)
      )
    )
  end

  @doc """
  The notes among `ids` whose body row exists and disagrees with its `notes`
  row in any column `sync!/3` copies (the owner too: a body row owned by
  another user is invisible to every read, which joins on the owner). The
  same comparison `sync!/3` writes on, so the two cannot disagree: slices
  and varlena headers only, nothing is de-TOASTed. For
  `Engram.DataMigrations.NoteSplit`'s drift report; `repo` is the pool the
  caller walks with.
  """
  @spec drift_ids(module(), [Ecto.UUID.t()]) :: [Ecto.UUID.t()]
  def drift_ids(_repo, []), do: []

  def drift_ids(repo, ids) do
    %{rows: rows} = repo.query!(@drift_sql, [Enum.map(ids, &Ecto.UUID.dump!/1)])
    Enum.map(rows, fn [id] -> id end)
  end
end
