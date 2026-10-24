defmodule Engram.Notes.NoteBody do
  @moduledoc """
  A note's body, 1:1 with `notes` (migration 20261021110100): materialized
  content, CRDT state and manifest head. Written only by the
  `notes_sync_body` trigger, which every writer of the `notes` body columns
  fires (this release, the previous one, raw SQL, backfills).

  Wave 3 migrate-data (`docs/context/notes-chunks-hyperopt.md` 6.1 step 2):
  every READ of a body column goes through `select/2` (or `join/1` +
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
  never de-TOASTs the `notes` copy.
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
  @spec body_fields() :: [atom()]
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

  @doc "Left-joins `note_bodies` as the `:note_body` binding (once)."
  @spec join(Ecto.Queryable.t()) :: Ecto.Query.t()
  def join(query) do
    if has_named_binding?(query, :note_body),
      do: query,
      else: from(n in query, left_join: b in __MODULE__, as: :note_body, on: b.note_id == n.id)
  end

  @doc """
  `%{field => expression}` for body `fields`, for a `select_merge` on a
  query that went through `join/1`.
  """
  @spec fields([atom()]) :: %{atom() => Ecto.Query.dynamic_expr()}
  def fields(fields), do: Map.new(fields, &{&1, field_expr(&1)})

  # The ciphertext starts at byte 14 in both merged formats: a format 1
  # nonce field is 13 bytes (leading 1), a format 0 nonce (12 bytes) sits
  # behind a 0 byte. `substring` reads a slice of an EXTERNAL value, so the
  # nonce costs a 13-byte fetch, not a de-TOAST.
  defp field_expr(:content_ciphertext) do
    dynamic(
      [n, note_body: b],
      type(
        fragment(
          "CASE WHEN ? IS NULL THEN ? ELSE substring(? FROM 14) END",
          b.note_id,
          n.content_ciphertext,
          b.content_ct
        ),
        :binary
      )
    )
  end

  defp field_expr(:content_nonce) do
    dynamic(
      [n, note_body: b],
      type(
        fragment(
          "CASE WHEN ? IS NULL THEN ? WHEN substring(? FROM 1 FOR 1) = '\\x01'::bytea THEN substring(? FROM 1 FOR 13) ELSE substring(? FROM 2 FOR 12) END",
          b.note_id,
          n.content_nonce,
          b.content_ct,
          b.content_ct,
          b.content_ct
        ),
        :binary
      )
    )
  end

  defp field_expr(:crdt_state_ciphertext) do
    dynamic(
      [n, note_body: b],
      type(
        fragment(
          "CASE WHEN ? IS NULL THEN ? ELSE substring(? FROM 14) END",
          b.note_id,
          n.crdt_state_ciphertext,
          b.crdt_ct
        ),
        :binary
      )
    )
  end

  defp field_expr(:crdt_state_nonce) do
    dynamic(
      [n, note_body: b],
      type(
        fragment(
          "CASE WHEN ? IS NULL THEN ? WHEN substring(? FROM 1 FOR 1) = '\\x01'::bytea THEN substring(? FROM 1 FOR 13) ELSE substring(? FROM 2 FOR 12) END",
          b.note_id,
          n.crdt_state_nonce,
          b.crdt_ct,
          b.crdt_ct,
          b.crdt_ct
        ),
        :binary
      )
    )
  end

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

  @doc """
  The byte length of a note's content (`:content`) or CRDT state (`:crdt`)
  ciphertext, from its body row (less the merged nonce field), else from
  `notes`. `octet_length` reads the varlena header, so nothing is
  de-TOASTed. For byte budgets and size metrics on a query through `join/1`.
  """
  @spec byte_length(:content | :crdt) :: Ecto.Query.dynamic_expr()
  def byte_length(:content) do
    dynamic(
      [n, note_body: b],
      fragment(
        "coalesce(CASE WHEN ? IS NULL THEN octet_length(?) ELSE octet_length(?) - 13 END, 0)",
        b.note_id,
        n.content_ciphertext,
        b.content_ct
      )
    )
  end

  def byte_length(:crdt) do
    dynamic(
      [n, note_body: b],
      fragment(
        "coalesce(CASE WHEN ? IS NULL THEN octet_length(?) ELSE octet_length(?) - 13 END, 0)",
        b.note_id,
        n.crdt_state_ciphertext,
        b.crdt_ct
      )
    )
  end
end
