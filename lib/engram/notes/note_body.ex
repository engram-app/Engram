defmodule Engram.Notes.NoteBody do
  @moduledoc """
  A note's body, 1:1 with `notes` (migration 20261021110100): materialized
  content, CRDT state and manifest head.

  Every app writer of a body field calls `put!/2` after its `notes` write,
  in the same transaction, with the values it wrote: the body is never a
  copy of the `notes` columns. R8 (stop storing every body twice) runs in
  releases: N added `sync!/3` (a copy from `notes`) beside the
  `notes_sync_body` trigger, N+1 dropped the trigger (20261104000000), R8(b1)
  (release A) moved every writer to `put!/2`, R8(b2) stopped writing
  `notes.content_ciphertext` / `crdt_state_ciphertext` (those `Note` fields
  are virtual, a raw write drops them, `notes_row/1`;
  `Engram.DataMigrations.NoteBodyColumnsNull` nulls the older rows), and
  R8(c) (this release) stops reading them: migration 20261107120000 gives
  every note its body row before boot, so nothing here falls back to the
  `notes` ciphertexts or copies from them. R8(d) drops the two columns. The
  nonces and `crdt_head` are still written on `notes` (the fences below).
  Rollback floor: 0.76 (the first release that reads bodies from here).

  Wave 3 migrate-data (`docs/context/notes-chunks-hyperopt.md` 6.1 step 2):
  every READ of a body column goes through `select_note/2` (or `join/1` +
  `fields/1` where a caller builds its own select), so the body comes from
  this table.

  Accepted risk (R8(b1) review): every in-step test here (`sync!/3`,
  `put!/2`'s rewrite skip, `drift_ids/2`, the `Canary` sample) compares a
  ciphertext by its 13-byte nonce field, not its bytes. Every encryption
  takes a fresh nonce, so only a write that changes a ciphertext but keeps
  its nonce (no app writer does; a restore or a hand edit could) goes
  unseen. Reading the bytes would de-TOAST every body on every check. The
  null batch alone also compares length and tag before it drops a copy.

  `content_ct` / `crdt_ct` hold `nonce || ciphertext`
  (`Engram.Crypto.Envelope.split_merged/1`). The read splits them back in
  SQL, so a loaded `%Note{}` carries the same `{ciphertext, nonce}` pair the
  `notes` columns hold, byte for byte: fences that compare
  `crdt_state_nonce` against the `notes` row still match, and every decrypt
  path is unchanged. `crdt_head` comes back as the 43-char url-safe base64
  `notes.crdt_head` stores.

  Every note has a body row: every writer inserts it with the note, and
  migration 20261107120000 inserted it, before boot, for a note written
  before the trigger (a self-hoster who skipped releases). A note without
  one would read with a NULL body; `Engram.Bookkeeping.Canary` samples for
  that (`NoteSplit.unfixed_ids/2`). `NoteSplit` REPORTS a body row that
  disagrees with its notes row (`drift/0`) and never repairs it: the body
  is the newer side.

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
    # True when either envelope is format 0 (the content one only on an
    # AAD-bound row), set by the same trigger; NULL until `NoteSizes` fills
    # it. `ReencodeEnvelopes` selects on it, `Bookkeeping.Drain` probes it.
    field :envelope_legacy, :boolean
  end

  @body [
    :content_ciphertext,
    :content_nonce,
    :crdt_state_ciphertext,
    :crdt_state_nonce,
    :crdt_head
  ]

  key_version = "CASE WHEN n.dek_version BETWEEN 0 AND 32767 THEN n.dek_version ELSE 0 END"

  head =
    "CASE WHEN n.crdt_head ~ '^[A-Za-z0-9_-]{43}$' " <>
      "THEN decode(translate(n.crdt_head, '-_', '+/') || '=', 'base64') END"

  head_differs = "b.crdt_head IS DISTINCT FROM #{head}"

  # True when body column `body` does not hold the envelope under the
  # `notes` nonce: NULL-ness and the 13-byte nonce field. Every encryption
  # takes a fresh nonce, so a matching nonce names the same envelope, and it
  # is the column the write fences compare. A row with no nonce (a pre-nonce
  # envelope, merged in its ciphertext) has nothing on `notes` to compare
  # since R8(b2), and is never drift.
  differs = fn body, nonce ->
    prefix =
      "CASE WHEN length(n.#{nonce}) = 13 THEN n.#{nonce} ELSE '\\x00'::bytea || n.#{nonce} END"

    """
    (n.#{nonce} IS NOT NULL AND (b.#{body} IS NULL
      OR substring(b.#{body} FROM 1 FOR 13) <> substring((#{prefix}) FROM 1 FOR 13)))
    """
  end

  # The head-and-owner step (`sync!/3`): update the body rows of $1 whose
  # owner, key version or (when `head?`) head differ from their `notes` row.
  # A note with no body row is not touched: since R8(c) every note has one
  # (migration 20261107120000).
  @sync_sql (for head? <- [false, true], into: %{} do
               {set, diff} =
                 if head?, do: {",\n      crdt_head = #{head}", " OR #{head_differs}"}, else: {"", ""}

               {head?,
                """
                WITH upd AS (
                  UPDATE note_bodies b SET
                    user_id = n.user_id,
                    key_version = #{key_version}#{set}
                  FROM notes n
                  WHERE b.note_id = n.id AND n.id = ANY($1) AND n.kind = 'note'
                    AND (b.user_id <> n.user_id OR b.key_version <> #{key_version}#{diff})
                  RETURNING 1
                )
                SELECT count(*)::int FROM upd
                """}
             end)

  sized = fn source, inserted_only ->
    """
    sized AS (
      UPDATE note_index_state s SET
        content_bytes = i.content_bytes,
        state_bytes = i.state_bytes,
        has_state = i.state_bytes IS NOT NULL
      FROM #{source} i
      WHERE s.note_id = i.note_id#{inserted_only}
    )
    """
  end

  put_from =
    "unnest($1::uuid[], $2::bytea[], $3::bytea[], $4::bytea[]) " <>
      "AS v(id, content_ct, crdt_ct, crdt_head) JOIN notes n ON n.id = v.id AND n.kind = 'note'"

  # One statement per set of body fields a writer provides (`put!/2`): upsert
  # each note's body row with the values the writer just wrote ($2..$4, one
  # array element per note), the owner and key version from its `notes` row
  # (they live there for good). An existing row gets only the provided
  # fields, and is not rewritten when it already holds them (owner, key
  # version, the 13-byte nonce field of each given envelope, the head). A
  # new row (a new note) takes NULL for a ciphertext not given and the
  # `notes.crdt_head` for a head not given, and seeds the note's narrow
  # sizes (`note_index_state`, whose row the notes INSERT trigger made
  # before the body existed) from the values the `note_bodies_sizes` BEFORE
  # trigger computed (RETURNING sees them); later edits reach them through
  # `CrdtBloatSweep`.
  @put_sql (for content? <- [false, true],
                crdt? <- [false, true],
                head? <- [false, true],
                into: %{} do
              given = for {f, true} <- [content: content?, crdt: crdt?, head: head?], do: f
              col = %{content: "content_ct", crdt: "crdt_ct", head: "crdt_head"}
              fallback = %{content: "NULL", crdt: "NULL", head: head}

              value = fn f ->
                if f in given, do: "v.#{col[f]}", else: fallback[f]
              end

              set = Enum.map_join(given, "", &",\n      #{col[&1]} = EXCLUDED.#{col[&1]}")

              # What an in-step row already holds: a 13-byte slice of an
              # envelope (a fresh nonce per encryption names it, and nothing
              # is de-TOASTed), the head whole.
              held = fn
                :head, t -> "#{t}.crdt_head"
                f, t -> "substring(#{t}.#{col[f]} FROM 1 FOR 13)"
              end

              compared = fn t ->
                Enum.map_join(given, "", &", #{held.(&1, t)}")
              end

              {given,
               """
               WITH up AS (
                 INSERT INTO note_bodies (note_id, user_id, key_version, content_ct, crdt_ct, crdt_head)
                   SELECT n.id, n.user_id, #{key_version}, #{value.(:content)}, #{value.(:crdt)}, #{value.(:head)}
                   FROM #{put_from}
                 ON CONFLICT (note_id) DO UPDATE SET
                   user_id = EXCLUDED.user_id,
                   key_version = EXCLUDED.key_version#{set}
                 WHERE (note_bodies.user_id, note_bodies.key_version#{compared.("note_bodies")})
                   IS DISTINCT FROM (EXCLUDED.user_id, EXCLUDED.key_version#{compared.("EXCLUDED")})
                 RETURNING note_id, content_bytes, state_bytes, xmax = 0 AS inserted
               ), #{sized.("up", " AND i.inserted")}
               SELECT count(*)::int FROM up
               """}
            end)

  # The ids among $1 whose body row exists and disagrees with its notes row
  # (`drift_ids/2`): owner, key version, either envelope's nonce, the head.
  @drift_sql """
  SELECT n.id::text FROM notes n JOIN note_bodies b ON b.note_id = n.id
  WHERE n.id = ANY($1) AND n.kind = 'note'
    AND (b.user_id <> n.user_id OR b.key_version <> #{key_version}
      OR #{differs.("content_ct", "content_nonce")}
      OR #{differs.("crdt_ct", "crdt_state_nonce")}
      OR #{head_differs})
  """

  # Virtual on `Note` since R8(b2): stored only here.
  @virtual_body [:content_ciphertext, :crdt_state_ciphertext]

  @doc """
  Every field a full note read selects: the `Note` columns plus the two
  ciphertexts that live only in `note_bodies` (virtual on `Note`). The
  default of `select_note/2` and `get/2`.
  """
  @spec note_fields() :: [atom()]
  def note_fields, do: Note.__schema__(:fields) ++ @virtual_body

  @doc """
  `values` (a keyword list or map of `Note` fields) without the two
  ciphertexts that live only in `note_bodies`: what a raw `notes` write
  (`update_all` `set:`, `insert_all` rows) may name. The writer hands the
  full `values` to `put!/2`.
  """
  @spec notes_row(keyword()) :: keyword()
  @spec notes_row(map()) :: map()
  def notes_row(values) when is_list(values), do: Keyword.drop(values, @virtual_body)
  def notes_row(values) when is_map(values), do: Map.drop(values, @virtual_body)

  @doc """
  Every `Note` field except the CRDT state, about half of a note's stored
  bytes: for reads that need the content but never the doc.
  """
  @spec without_crdt() :: [atom()]
  def without_crdt, do: note_fields() -- [:crdt_state_ciphertext, :crdt_state_nonce]

  @doc "The `Note` fields that live in `note_bodies`."
  def body_fields, do: @body

  @doc """
  `query` (its first binding a `Note`) selecting `fields` (default: every
  field) as a `%Note{}`, the body fields read from `note_bodies`. A field
  list with no body field adds no join.
  """
  @spec select_note(Ecto.Queryable.t(), [atom()]) :: Ecto.Query.t()
  def select_note(query, fields \\ note_fields()) do
    # A struct select needs one field of its own: a body-only list keeps the id.
    core = with [] <- fields -- @body, do: [:id]
    query = from(n in query, select: struct(n, ^core))

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
  def get(id, fields \\ note_fields()) do
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
  Brings the existing `note_bodies` rows of the notes `ids` in step with
  their `notes` row's owner, key version (`dek_version`) and, when
  `written` names `:crdt_head`, head, and returns how many rows it wrote.
  For the head self-heal (`CrdtTransport.store_head_if_unchanged/4`),
  inside a transaction that holds the `notes` rows (`notes` before
  `note_bodies`). It never reads or writes a ciphertext: a body write goes
  through `put!/2`, and `written` naming a ciphertext or nonce column
  raises. A note with no body row is left alone: since R8(c) every note has
  one (migration 20261107120000), and the `notes` ciphertext columns it
  would have been copied from are going away (R8(d)).

  `written` is a list, or the keyword list / changes map the write set. A
  row already in step is not touched. Emits `[:engram, :note_body,
  :sync_wrote]` (`%{count: rows}`) when it wrote anything
  (`engram_prom_ex_notes_body_sync_wrote_rows_total`): the body write rate.

  Options: `:repo` (default `Engram.Repo`); the rest go to the query
  (`mode: :savepoint`, `skip_tenant_check:` is ignored by raw SQL and
  harmless).
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

  @doc """
  Writes the body values a writer just wrote to `notes` into `note_bodies`,
  and returns how many rows it wrote: the body is what the writer wrote,
  never a copy of the `notes` columns. Every app writer of a body field
  calls this after its `notes` write, in the same transaction (so the
  `notes` rows are already locked: `notes` before `note_bodies`).

  `entries` is `{id, values}` or a list of them; `values` (a keyword list,
  map or changes map) may hold any `Note` fields, of which only the body
  fields (`body_fields/0`) are written: `content_*` and `crdt_state_*` as
  (ciphertext, nonce) pairs, `crdt_head` as `notes.crdt_head` holds it (a
  ciphertext given without its nonce is stored bare, as the copy stores
  it). A CRDT state given without a
  head resets the head, as the `notes_crdt_head_invalidate` trigger does on
  `notes`. Fields not given are left as they are; a missing body row is
  inserted whole, its other fields from the `notes` columns. The owner and
  key version always follow the `notes` row.

  One statement per set of given fields; same telemetry and options as
  `sync!/3`.
  """
  @spec put!({Ecto.UUID.t(), Enumerable.t()} | [{Ecto.UUID.t(), Enumerable.t()}], keyword()) ::
          non_neg_integer()
  def put!(entries, opts \\ [])
  def put!({_id, _values} = entry, opts), do: put!([entry], opts)

  def put!(entries, opts) when is_list(entries) do
    {repo, opts} = Keyword.pop(opts, :repo, Repo)

    entries
    |> Enum.map(fn {id, values} -> {id, body_values(Map.new(values))} end)
    |> Enum.group_by(fn {_id, vals} -> Map.keys(vals) |> Enum.sort() end)
    |> Enum.reduce(0, fn {given, rows}, acc ->
      cols = for f <- [:content, :crdt, :head], do: Enum.map(rows, &elem(&1, 1)[f])
      params = [Enum.map(rows, &Ecto.UUID.dump!(elem(&1, 0))) | cols]
      %{rows: [[n]]} = repo.query!(Map.fetch!(@put_sql, given), params, opts)
      acc + n
    end)
    |> tap(fn n ->
      if n > 0, do: :telemetry.execute([:engram, :note_body, :sync_wrote], %{count: n}, %{})
    end)
  end

  # The given body fields of `values` in the `note_bodies` layout, keyed
  # `:content` / `:crdt` / `:head`.
  defp body_values(values) do
    crdt? = Map.has_key?(values, :crdt_state_ciphertext)

    %{}
    |> put_pair(:content, values, :content_ciphertext, :content_nonce)
    |> put_pair(:crdt, values, :crdt_state_ciphertext, :crdt_state_nonce)
    |> then(fn acc ->
      cond do
        Map.has_key?(values, :crdt_head) -> Map.put(acc, :head, head_bytes(values.crdt_head))
        crdt? -> Map.put(acc, :head, nil)
        true -> acc
      end
    end)
  end

  defp put_pair(acc, key, values, ct, nonce) do
    case values do
      %{^ct => nil} -> Map.put(acc, key, nil)
      %{^ct => c, ^nonce => n} -> Map.put(acc, key, merge(c, n))
      %{^ct => c} -> Map.put(acc, key, c)
      _ -> acc
    end
  end

  # The merged layout (`nonce || ciphertext`), via `Envelope.merge/2`.
  defp merge(ct, nil), do: ct
  defp merge(ct, nonce), do: Engram.Crypto.Envelope.merge(nonce, ct)

  # `notes.crdt_head` (43-char url-safe base64) as the 32 bytes the body
  # holds; anything else is NULL, as the copy maps it.
  defp head_bytes(<<_::binary-43>> = head) do
    case Base.url_decode64(head, padding: false) do
      {:ok, bytes} -> bytes
      :error -> nil
    end
  end

  defp head_bytes(_), do: nil

  @ciphertext_cols [:content_ciphertext, :content_nonce, :crdt_state_ciphertext, :crdt_state_nonce]

  # True when `written` names the head; a ciphertext column raises.
  defp synced_fields(written) when is_map(written), do: synced_fields(Map.keys(written))

  defp synced_fields(written) when is_list(written) do
    cols =
      Enum.map(written, fn
        {col, _} -> col
        col -> col
      end)

    if Enum.any?(@ciphertext_cols, &(&1 in cols)),
      do: raise(ArgumentError, "NoteBody.sync!/3 copies no ciphertext; write it with put!/2")

    :crdt_head in cols
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

  # The 32-byte body digest as the url-safe, unpadded base64
  # `notes.crdt_head` holds (a 32-byte base64 is 44 chars, one `=`, no line
  # break).
  defmacrop url_b64(digest) do
    quote do
      fragment("rtrim(translate(encode(?, 'base64'), '+/', '-_'), '=')", unquote(digest))
    end
  end

  @doc """
  True when the note's CRDT state is NULL as every read sees it: from its
  body row, else (no body row, or one owned by another user, as `join/1`
  treats it) from `notes.crdt_state_nonce`, which every release writes and
  clears with the state. For a predicate on a query whose first binding
  is a `Note`. The body row is read by a per-row primary-key subquery, not
  a join. NULL-ness only: nothing is de-TOASTed. Not for a write fence in a
  `notes` UPDATE: after a row-lock wait the subquery still sees the
  pre-wait body (see the moduledoc).
  """
  @spec null?(:crdt_state_ciphertext) :: Ecto.Query.dynamic_expr()
  def null?(:crdt_state_ciphertext) do
    dynamic(
      [n],
      fragment(
        "coalesce((SELECT b.crdt_ct IS NULL FROM note_bodies AS b WHERE b.note_id = ? AND b.user_id = ?), ? IS NULL)",
        n.id,
        n.user_id,
        n.crdt_state_nonce
      )
    )
  end

  @doc """
  True when a note's head needs warming: either copy (`notes.crdt_head`,
  the body row's) is NULL, there is no body row, or the two disagree. With
  the copy trigger gone nothing else heals a split, so warming must find
  every shape of one (`CrdtTransport.store_head_if_unchanged/4` copies the
  notes head over when its compare-and-set loses). A per-row primary-key
  probe of `note_bodies` (index-only on `note_bodies_user_note_head`), not
  a join, so a query that reads its notes by key (`IdWindows.by_id/2`)
  keeps that plan (#2403). The note binding must be named `:note`.
  """
  @spec head_cold() :: Ecto.Query.dynamic_expr()
  def head_cold do
    in_step =
      from(b in __MODULE__,
        where:
          b.note_id == parent_as(:note).id and b.user_id == parent_as(:note).user_id and
            url_b64(b.crdt_head) == parent_as(:note).crdt_head,
        select: 1
      )

    dynamic(not exists(in_step))
  end

  # The ciphertext starts at byte 14 in both merged formats: a format 1
  # nonce field is 13 bytes (leading 1), a format 0 nonce (12 bytes) sits
  # behind a 0 byte. `substring ... FOR n` reads a slice of an EXTERNAL
  # value, so the nonce costs a 13-byte fetch; the ciphertext (`FROM 14`,
  # no length) is the full value. Read from the body row only: since R8(c)
  # every note has one (migration 20261107120000).
  defp field_expr(:content_ciphertext), do: ct_expr(:content_ct)
  defp field_expr(:content_nonce), do: nonce_expr(:content_ct, :content_nonce)
  defp field_expr(:crdt_state_ciphertext), do: ct_expr(:crdt_ct)
  defp field_expr(:crdt_state_nonce), do: nonce_expr(:crdt_ct, :crdt_state_nonce)

  defp field_expr(:crdt_head), do: head_expr(dynamic([n], n.crdt_head))

  # The body's head as `url_b64/1`; `fallback` (the notes-side head) for a
  # note with no body row.
  defp head_expr(fallback) do
    dynamic(
      [n, note_body: b],
      type(
        fragment(
          "CASE WHEN ? IS NULL THEN ? ELSE ? END",
          b.note_id,
          ^fallback,
          url_b64(b.crdt_head)
        ),
        :string
      )
    )
  end

  defp ct_expr(body),
    do: dynamic([note_body: b], type(fragment("substring(? FROM 14)", field(b, ^body)), :binary))

  # The nonce falls back to the `notes` column (kept: the write fences
  # compare it) for a row read before its body row is written in the same
  # transaction (a create's own re-read, `Notes.do_bare_insert`).
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
  ciphertext, from its body row (less the merged nonce field), 0 when it
  has none. `octet_length` reads the varlena header, so nothing is
  de-TOASTed. For byte budgets and size metrics on a query through `join/1`.
  """
  @spec byte_length(:content | :crdt) :: Ecto.Query.dynamic_expr()
  def byte_length(:content), do: length_expr(:content_ct)
  def byte_length(:crdt), do: length_expr(:crdt_ct)

  defp length_expr(body),
    do: dynamic([note_body: b], fragment("coalesce(octet_length(?) - 13, 0)", field(b, ^body)))

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
