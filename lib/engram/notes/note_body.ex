defmodule Engram.Notes.NoteBody do
  @moduledoc """
  A note's body, 1:1 with `notes` (migration 20261021110100): materialized
  content, CRDT state and manifest head. Written only by the
  `notes_sync_body` trigger, which every writer of the `notes` body columns
  fires (this release, the previous one, raw SQL, backfills).

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
  its ledger runs, and a re-verify that finds a missed row costs nothing.
  The fallback is a `CASE` branch, so when the body row exists Postgres
  never de-TOASTs the `notes` copy. `NoteSplit` REPORTS a body row that
  disagrees with its notes row (`drift/0`) and never repairs it: from the
  next release on, the body is the newer side.

  Two rules the contract release (stop writing the notes body columns, drop
  them) must change in the same release:

    * Row-locked reads (`Notes.lock_for_write/2`, DEK rotation) read the
      body from the `notes` columns, not from here: a read that waits on the
      notes row lock re-fetches only the locked relation (EvalPlanQual), so
      a joined body row would be the pre-wait version. Contract must lock in
      one statement and read the body in a fresh one (LockedReadBodyTest).
    * Write fences (`snapshot_fence`, `rename_fence`, `snapshot_fenced`)
      compare the `notes.crdt_state_nonce` column against the nonce a read
      split from here. That holds while `notes` keeps its own nonce column,
      which every release up to contract writes. `notes` never gets the
      merged layout: the release that stops writing it moves the fences to
      a `note_bodies` comparison at the same time.
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
  end

  @body [
    :content_ciphertext,
    :content_nonce,
    :crdt_state_ciphertext,
    :crdt_state_nonce,
    :crdt_head
  ]

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
  Left-joins `note_bodies` as the `:note_body` binding (once).

  Matches `user_id` as well as `note_id`: a caller's `n.user_id == ^id`
  then reaches `note_bodies` as an index condition (`note_bodies_user_note`),
  so a vault-wide join reads the owner's bodies, not every tenant's (R5).
  The trigger writes the note's own `user_id`, so no row changes sides.
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

  # The ciphertext starts at byte 14 in both merged formats: a format 1
  # nonce field is 13 bytes (leading 1), a format 0 nonce (12 bytes) sits
  # behind a 0 byte. `substring ... FOR n` reads a slice of an EXTERNAL
  # value, so the nonce costs a 13-byte fetch; the ciphertext (`FROM 14`,
  # no length) is the full value.
  defp field_expr(:content_ciphertext), do: ct_expr(:content_ct, :content_ciphertext)
  defp field_expr(:content_nonce), do: nonce_expr(:content_ct, :content_nonce)
  defp field_expr(:crdt_state_ciphertext), do: ct_expr(:crdt_ct, :crdt_state_ciphertext)
  defp field_expr(:crdt_state_nonce), do: nonce_expr(:crdt_ct, :crdt_state_nonce)

  # The 32-byte digest as the url-safe, unpadded base64 `notes.crdt_head`
  # holds (a 32-byte base64 is 44 chars, one `=`, no line break).
  defp field_expr(:crdt_head) do
    dynamic(
      [n, note_body: b],
      type(
        fragment(
          "CASE WHEN ? IS NULL THEN ? ELSE rtrim(translate(encode(?, 'base64'), '+/', '-_'), '=') END",
          b.note_id,
          n.crdt_head,
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
  True when a note's body row disagrees with its `notes` row, for a query
  through `join/1` restricted to rows that HAVE a body: the nonce each side
  carries (the read's own split, `nonce_expr/2`), the AEAD tag (the last 16
  bytes, which differ for any other ciphertext under the same nonce), and
  the head. Slices and varlena headers only, nothing is de-TOASTed. For
  `Engram.DataMigrations.NoteSplit`'s drift report.
  """
  @spec drift() :: Ecto.Query.dynamic_expr()
  def drift do
    content = differs(:content_ct, :content_nonce, :content_ciphertext)
    crdt = differs(:crdt_ct, :crdt_state_nonce, :crdt_state_ciphertext)
    head = field_expr(:crdt_head)

    dynamic(
      [n],
      ^content or ^crdt or fragment("? IS DISTINCT FROM ?", ^head, n.crdt_head)
    )
  end

  defp differs(body, notes_nonce, notes_ct) do
    nonce = nonce_expr(body, notes_nonce)

    dynamic(
      [n, note_body: b],
      fragment("? IS DISTINCT FROM ?", ^nonce, field(n, ^notes_nonce)) or
        fragment(
          "substring(? FROM greatest(octet_length(?) - 15, 1)) IS DISTINCT FROM substring(? FROM greatest(octet_length(?) - 15, 1))",
          field(b, ^body),
          field(b, ^body),
          field(n, ^notes_ct),
          field(n, ^notes_ct)
        )
    )
  end
end
