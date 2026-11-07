defmodule Engram.Fixtures do
  @moduledoc "Convenience helpers for inserting common test fixtures."

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Crypto.Envelope
  alias Engram.Notes.Note
  alias Engram.Notes.NoteBody
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @doc """
  Inserts a user with a provisioned DEK. Accepts optional `dek_version` to
  stamp an explicit version on the row (useful for rotation tests that need
  a specific starting version).
  """
  def user_with_dek_fixture(opts \\ []) do
    user = Engram.Factory.insert(:user)
    {:ok, user_with_dek} = Engram.Crypto.ensure_user_dek(user)

    case Keyword.get(opts, :dek_version) do
      nil ->
        {:ok, user_with_dek}

      v when is_integer(v) ->
        Repo.update_all(
          from(u in User, where: u.id == ^user_with_dek.id),
          [set: [dek_version: v]],
          skip_tenant_check: true
        )

        {:ok, %{user_with_dek | dek_version: v}}
    end
  end

  @doc """
  Inserts a Note row directly with valid Phase B ciphertext + HMAC fields,
  skipping the side effects of `Notes.upsert_note/3` (Oban enqueue,
  broadcast, embed worker). Use this in test setups that previously relied
  on the raw `insert(:note, ...)` factory shortcut and assert specifically
  on enqueued job counts.

  Accepts `path`, `folder`, `tags`, `content`, `title` (and any other Note
  attrs) as keyword/string-keyed map overrides.
  """
  def insert_note!(user, vault, attrs \\ %{}) do
    user = with_dek(user)
    {note_attrs, path, folder, tags} = note_attrs(user, vault, attrs)
    now = DateTime.utc_now()

    {:ok, inserted} =
      Repo.with_tenant(user.id, fn ->
        # DB-enforced NOT NULL (NULL-seq rows vanish from the sync feed) —
        # stamp a real per-vault seq inside the tenant txn (next_seq!'s
        # row-lock contract) unless the caller overrode it.
        note_attrs = Map.put_new(note_attrs, :seq, Engram.Vaults.next_seq!(vault.id))

        note =
          %Note{}
          |> Note.changeset(note_attrs)
          |> Repo.insert!()

        # As every app writer: the body row in the same transaction, from
        # the values written (the `notes` ciphertext columns are not, R8(b2)).
        _ = NoteBody.put!({note.id, note_attrs})
        note
      end)

    # Splice virtual fields so callers can read note.path / .folder / .tags
    # without re-fetching + decrypting.
    %{inserted | path: path, folder: folder, tags: tags, created_at: now, updated_at: now}
  end

  @doc """
  Many notes of one vault in a few statements, for a test that needs a
  table of thousands: one seq block, one INSERT per 1,000 rows and one
  `NoteBody.put!/2` for all, instead of four or five round trips a note
  (a 1,205-note seed ran past the 60 s test timeout on CI). Each entry is
  either attrs, written as `insert_note!/3` writes them (real ciphertext
  and HMACs), or a built `%Note{}` (`build(:note, ...)`), written as is in
  this vault. Returns the ids, in order.
  """
  def insert_notes!(user, vault, entries) do
    user = with_dek(user)
    now = DateTime.utc_now()
    fields = NoteBody.note_fields()

    rows =
      for entry <- entries do
        note =
          case entry do
            # The factory's seq is a placeholder: the allocator's block
            # below stamps it, as it does an attrs entry without `seq`.
            %Note{} = note ->
              %{note | seq: nil}

            attrs ->
              {note_attrs, _, _, _} = note_attrs(user, vault, attrs)
              %Note{} |> Note.changeset(note_attrs) |> Ecto.Changeset.apply_changes()
          end

        note
        |> Map.take(fields)
        |> Map.merge(%{user_id: user.id, vault_id: vault.id, created_at: now, updated_at: now})
        |> Map.update!(:id, &(&1 || Engram.Notes.mint_id()))
        # Nil fields left out, as `Repo.insert!/2` leaves out a nil
        # read-after-write column: the column default fills them.
        |> Map.reject(fn {_, v} -> is_nil(v) end)
      end

    Repo.with_tenant!(user.id, fn ->
      last = Engram.Vaults.next_seq_block!(vault.id, length(rows))

      rows =
        rows
        |> Enum.with_index(last - length(rows) + 1)
        |> Enum.map(fn {row, seq} -> Map.put_new(row, :seq, seq) end)

      for chunk <- Enum.chunk_every(rows, 1000),
          do: Repo.insert_all(Note, Enum.map(chunk, &NoteBody.notes_row/1))

      _ = NoteBody.put!(Enum.map(rows, &{&1.id, &1}))
      Enum.map(rows, & &1.id)
    end)
  end

  defp with_dek(%{encrypted_dek: nil} = user) do
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    user
  end

  defp with_dek(user), do: user

  # The `notes` columns of a note `insert_note!/3` writes, and its path,
  # folder and tags (virtual on the schema).
  defp note_attrs(user, vault, attrs) do
    attrs = Enum.into(attrs, %{}, fn {k, v} -> {to_string(k), v} end)
    seq = System.unique_integer([:positive, :monotonic])
    path = Map.get(attrs, "path", "test/note-#{seq}.md")
    content = Map.get(attrs, "content", "# Test note content")
    title = Map.get(attrs, "title", "Test note #{seq}")

    folder =
      Map.get(
        attrs,
        "folder",
        path
        |> Path.dirname()
        |> case do
          "." -> ""
          d -> d
        end
      )

    tags = Map.get(attrs, "tags", [])
    mtime = Map.get(attrs, "mtime", 1_000.0)

    {:ok, dek} = Engram.Crypto.get_dek(user)
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    {:ok, content_key} = Engram.Crypto.dek_content_hash_key(user)
    {path_ct, path_n} = Envelope.encrypt(path, dek)
    {folder_ct, folder_n} = Envelope.encrypt(folder, dek)
    {tags_ct, tags_n} = Envelope.encrypt(:erlang.term_to_binary(tags), dek)
    {content_ct, content_n} = Envelope.encrypt(content, dek)
    {title_ct, title_n} = Envelope.encrypt(title, dek)

    base_attrs = %{
      content_hash:
        Map.get(
          attrs,
          "content_hash",
          Engram.Crypto.hmac_content_hash(content_key, content)
        ),
      mtime: mtime,
      user_id: user.id,
      vault_id: vault.id,
      content_ciphertext: content_ct,
      content_nonce: content_n,
      title_ciphertext: title_ct,
      title_nonce: title_n,
      path_ciphertext: path_ct,
      path_nonce: path_n,
      path_hmac: Engram.Crypto.hmac_field(filter_key, path),
      folder_ciphertext: folder_ct,
      folder_nonce: folder_n,
      folder_hmac: Engram.Crypto.hmac_field(filter_key, folder),
      tags_ciphertext: tags_ct,
      tags_nonce: tags_n,
      tags_hmac: Enum.map(tags, &Engram.Crypto.hmac_field(filter_key, &1)),
      # Links foundation — mirrors what production writers (Task 4) will
      # stamp, so link-resolution tests don't depend on a separate backfill.
      basename_hmac: Engram.Crypto.hmac_field(filter_key, Engram.Links.basename_key(path))
    }

    base_attrs = Map.merge(base_attrs, Map.new(Engram.Links.path_keys(filter_key, path, path_n)))

    # Pull through any caller-specified overrides for non-Phase-B fields so
    # tests can set embed_hash, version, deleted_at, etc.
    extras =
      attrs
      |> Map.drop(["path", "folder", "tags", "content", "title", "mtime", "content_hash"])
      |> Enum.into(%{}, fn {k, v} -> {String.to_existing_atom(k), v} end)

    {Map.merge(base_attrs, extras), path, folder, tags}
  end

  @doc """
  Inserts the `chunks` row search keys a Qdrant hit on: `point_id` must be
  the hit's point id (a UUID); a hit with no row is dropped. The vault and
  the display fields come from `note`.

  Without `:text` the row has no `chunk_points` text, so search takes the
  hit's text from the payload fallback retrieve (answer it with
  `Engram.QdrantStub.stub_retrieve/2`). With `:text` (and `:heading`) the
  text is in Postgres, encrypted under the user's DEK, and no retrieve runs.
  `:position` defaults to 0 and is unique per note.
  """
  def insert_chunk!(user, note, point_id, opts \\ []) do
    pos = Keyword.get(opts, :position, 0)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        %Engram.Notes.Chunk{}
        |> Engram.Notes.Chunk.changeset(%{
          note_id: note.id,
          user_id: user.id,
          vault_id: note.vault_id,
          position: pos,
          char_start: 0,
          char_end: 1,
          qdrant_point_id: point_id
        })
        |> Repo.insert!()

        if opts[:text] do
          {:ok, dek} = Engram.Crypto.get_dek(user)

          %{display_ct: ct} =
            Engram.Crypto.encrypt_chunk_text(opts[:text], opts[:heading], dek, point_id)

          Repo.insert!(%Engram.Notes.ChunkPoint{
            point_id: point_id,
            note_id: note.id,
            user_id: user.id,
            position: pos,
            display_ct: ct
          })
        end
      end)

    point_id
  end

  @doc """
  Inserts a Vault row directly with valid phase-B ciphertext, bypassing
  billing checks and Oban side effects. The name is encrypted with empty
  AAD (legacy dek_version: 1) so rotation tests start with a row that
  actually needs to be re-encrypted.
  """
  def insert_vault!(user, name) do
    user =
      case user.encrypted_dek do
        nil ->
          {:ok, u} = Engram.Crypto.ensure_user_dek(user)
          u

        _ ->
          user
      end

    {:ok, dek} = Engram.Crypto.get_dek(user)
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    vault_id = Ecto.UUID.generate()

    # Legacy encrypt: empty AAD (dek_version 1 — pre-AAD-bind)
    {ct, nonce} = Envelope.encrypt(name, dek, <<>>)

    seq = System.unique_integer([:positive, :monotonic])

    attrs = %{
      id: vault_id,
      user_id: user.id,
      slug: "vault-fixture-#{seq}",
      is_default: false,
      name_ciphertext: ct,
      name_nonce: nonce,
      name_hmac: Engram.Crypto.hmac_field(filter_key, name),
      dek_version: 1
    }

    Repo.insert!(
      struct(Vault, attrs),
      skip_tenant_check: true
    )
  end

  @doc """
  Phase B.3 helper — fetches the raw (un-decrypted) Note row by plaintext
  path. Tests that previously called `Repo.get_by!(Note, path: ..., user_id:
  ...)` no longer work because `path` is virtual. This translates the
  plaintext path into a `path_hmac` lookup using the user's filter key.
  """
  def raw_note_by_path!(user, path) do
    user = Engram.Repo.get!(User, user.id)
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    hmac = Engram.Crypto.hmac_field(filter_key, path)

    {:ok, note} =
      Repo.with_tenant(user.id, fn ->
        from(n in Note, where: n.user_id == ^user.id and n.path_hmac == ^hmac)
        |> NoteBody.select_note()
        |> Repo.one!()
      end)

    note
  end

  @doc """
  Phase B.3 helper — fetches the raw Attachment row by plaintext path.
  Mirror of `raw_note_by_path!/2` for attachments.
  """
  def raw_attachment_by_path!(user, path) do
    user = Engram.Repo.get!(User, user.id)
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    hmac = Engram.Crypto.hmac_field(filter_key, path)

    {:ok, att} =
      Repo.with_tenant(user.id, fn ->
        Repo.one!(
          from(a in Engram.Attachments.Attachment,
            where: a.user_id == ^user.id and a.path_hmac == ^hmac
          )
        )
      end)

    att
  end

  @doc """
  Inserts an Attachment row with legacy v1 encryption (empty AAD), mirroring
  what `insert_note!/3` does for notes. Content is written to the S3 adapter
  so rotation tests can round-trip the blob.

  Accepts `path`, `content` (plaintext binary), `mime_type`, `mtime`.
  Returns the inserted struct with `dek_version: 1`.
  """
  def insert_attachment!(user, vault, attrs \\ %{}) do
    user =
      case user.encrypted_dek do
        nil ->
          {:ok, u} = Engram.Crypto.ensure_user_dek(user)
          u

        _ ->
          user
      end

    attrs = Enum.into(attrs, %{}, fn {k, v} -> {to_string(k), v} end)

    path =
      Map.get(attrs, "path", "test/att-#{System.unique_integer([:positive, :monotonic])}.bin")

    content = Map.get(attrs, "content", <<0, 1, 2, 3>>)
    mime_type = Map.get(attrs, "mime_type", "application/octet-stream")
    mtime = Map.get(attrs, "mtime", 0.0)

    {:ok, dek} = Engram.Crypto.get_dek(user)
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    {:ok, content_key} = Engram.Crypto.dek_content_hash_key(user)

    att_id = Ecto.UUID.generate()
    storage_key = Engram.Storage.object_key(user.id, vault.id, att_id)

    # DB-enforced NOT NULL on seq (NULL rows vanish from the sync feed).
    {:ok, seq} = Repo.with_tenant(user.id, fn -> Engram.Vaults.next_seq!(vault.id) end)

    # Legacy v1 encrypt: empty AAD
    {content_ct, content_nonce} = Envelope.encrypt(content, dek, <<>>)
    {path_ct, path_nonce} = Envelope.encrypt(path, dek, <<>>)

    # Write ciphertext blob to storage
    :ok = Engram.Storage.adapter().put(storage_key, content_ct, content_type: mime_type)

    attrs = %{
      id: att_id,
      user_id: user.id,
      vault_id: vault.id,
      path_ciphertext: path_ct,
      path_nonce: path_nonce,
      path_hmac: Engram.Crypto.hmac_field(filter_key, path),
      basename_hmac: Engram.Crypto.hmac_field(filter_key, Engram.Links.basename_key(path)),
      content_hash: Engram.Crypto.hmac_content_hash(content_key, content),
      content_nonce: content_nonce,
      storage_key: storage_key,
      mime_type: mime_type,
      size_bytes: byte_size(content),
      mtime: mtime,
      seq: seq,
      encryption_version: 1,
      dek_version: 1
    }

    attrs = Map.merge(attrs, Map.new(Engram.Links.path_keys(filter_key, path, path_nonce)))

    inserted =
      Repo.insert!(
        struct(Engram.Attachments.Attachment, attrs),
        skip_tenant_check: true
      )

    # Splice virtual path so callers can read att.path
    %{inserted | path: path}
  end

  @doc """
  Raw (encrypted, un-decrypted) note row straight from the DB — for tests
  asserting persisted column state (seq, ciphertext bytes, deleted_at).
  """
  def raw_note_row!(user, id) do
    {:ok, row} =
      Engram.Repo.with_tenant(user.id, fn ->
        Note |> where([n], n.id == ^id) |> NoteBody.select_note() |> Repo.one()
      end)

    row
  end

  @doc """
  Every `kind = 'note'` row of `user_id` whose `note_bodies` row is missing
  or disagrees with its `notes` body columns, as `{id, [column]}`, compared
  in full against the dropped `notes_sync_body` trigger's mapping (20261021110200)
  while the `notes` ciphertext is set, by nonce once it is NULL (R8(b2)),
  restated here independently of `Engram.Notes.NoteBody`. Ids and column
  names only, never content. `[]` means in step.
  """
  def note_body_divergence(user_id) do
    merged = fn ct, nonce ->
      """
      CASE WHEN n.#{ct} IS NULL THEN NULL
        WHEN n.#{nonce} IS NULL THEN n.#{ct}
        WHEN length(n.#{nonce}) = 13 THEN n.#{nonce} || n.#{ct}
        ELSE '\\x00'::bytea || n.#{nonce} || n.#{ct} END
      """
    end

    # While the notes ciphertext is set, the body must equal it whole. Once
    # it is NULL (R8(b2): writers write only the body, the null batch clears
    # older rows) the nonce is the notes side of the pair: the body holds an
    # envelope under that nonce, or nothing when the nonce is NULL.
    differs = fn body, ct, nonce ->
      prefix =
        "CASE WHEN length(n.#{nonce}) = 13 THEN n.#{nonce} ELSE '\\x00'::bytea || n.#{nonce} END"

      """
      CASE WHEN n.#{ct} IS NOT NULL THEN b.#{body} IS DISTINCT FROM (#{merged.(ct, nonce)})
        WHEN n.#{nonce} IS NULL THEN b.#{body} IS NOT NULL
        ELSE b.#{body} IS NULL OR substring(b.#{body} FROM 1 FOR 13) <> substring((#{prefix}) FROM 1 FOR 13) END
      """
    end

    %{rows: rows} =
      Engram.Repo.query!(
        """
        SELECT n.id::text,
          b.note_id IS NULL,
          b.user_id IS DISTINCT FROM n.user_id,
          b.key_version IS DISTINCT FROM
            (CASE WHEN n.dek_version BETWEEN 0 AND 32767 THEN n.dek_version ELSE 0 END),
          #{differs.("content_ct", "content_ciphertext", "content_nonce")},
          #{differs.("crdt_ct", "crdt_state_ciphertext", "crdt_state_nonce")},
          b.crdt_head IS DISTINCT FROM (CASE WHEN n.crdt_head ~ '^[A-Za-z0-9_-]{43}$'
            THEN decode(translate(n.crdt_head, '-_', '+/') || '=', 'base64') END)
        FROM notes n LEFT JOIN note_bodies b ON b.note_id = n.id
        WHERE n.user_id = $1 AND n.kind = 'note'
        """,
        [Ecto.UUID.dump!(user_id)]
      )

    names = [:missing, :user_id, :key_version, :content, :crdt, :head]

    for [id | flags] <- rows, Enum.any?(flags) do
      {id, for({name, true} <- Enum.zip(names, flags), do: name)}
    end
  end

  @doc """
  The stored note row `id` as every read loads it: the `notes` columns plus
  the body ciphertexts from `note_bodies` (`NoteBody.select_note/2`; the
  two ciphertexts are virtual on `Note` since R8(b2), so `Repo.get!/3` or
  `Repo.reload!/2` leaves them nil). No tenant scope.
  """
  def raw_note!(%{id: id}), do: raw_note!(id)
  def raw_note!(id), do: raw_note(id) || raise(Ecto.NoResultsError, queryable: Note)

  @doc "As `raw_note!/1`, nil when there is no such row."
  def raw_note(id) do
    Note
    |> where([n], n.id == ^id)
    |> NoteBody.select_note()
    |> Repo.one(skip_tenant_check: true)
  end

  @doc """
  Writes `values` (a keyword list of `Note` fields, e.g. a tampered or
  legacy ciphertext) onto note `id` behind the writers' back: the `notes`
  columns with a raw `update_all`, the body ciphertexts into `note_bodies`
  (where every read takes them; virtual on `Note` since R8(b2)). A body
  pair given half (only the ciphertext, or only the nonce) keeps the other
  half the note holds, so the stored envelope is exactly what the test set.
  """
  def write_note_body!(id, values) do
    values = Map.new(values)
    notes = values |> NoteBody.notes_row() |> Map.to_list()

    if notes != [],
      do:
        Repo.update_all(from(n in Note, where: n.id == ^id), [set: notes],
          skip_tenant_check: true
        )

    current = raw_note!(id)

    pairs =
      for pair <- [
            [:content_ciphertext, :content_nonce],
            [:crdt_state_ciphertext, :crdt_state_nonce]
          ],
          Enum.any?(pair, &Map.has_key?(values, &1)),
          f <- pair,
          into: %{},
          do: {f, Map.get(values, f, Map.get(current, f))}

    # Raw, not `put!/2`: `put!/2` skips a rewrite under an unchanged nonce
    # (the accepted nonce-only check), and a tampered envelope keeps it.
    merged = fn ct, nonce -> if ct, do: if(nonce, do: Envelope.merge(nonce, ct), else: ct) end
    sets = []

    sets =
      if Map.has_key?(pairs, :content_ciphertext),
        do: [{"content_ct", merged.(pairs.content_ciphertext, pairs.content_nonce)} | sets],
        else: sets

    sets =
      if Map.has_key?(pairs, :crdt_state_ciphertext),
        do: [
          {"crdt_ct", merged.(pairs.crdt_state_ciphertext, pairs.crdt_state_nonce)},
          {"crdt_head", nil} | sets
        ],
        else: sets

    if sets != [] do
      assigns =
        sets |> Enum.with_index(2) |> Enum.map_join(", ", fn {{c, _}, i} -> "#{c} = $#{i}" end)

      %{num_rows: n} =
        Repo.query!(
          "UPDATE note_bodies SET #{assigns} WHERE note_id = $1",
          [Ecto.UUID.dump!(id) | Enum.map(sets, &elem(&1, 1))]
        )

      if n == 0, do: NoteBody.put!({id, pairs})
    end

    :ok
  end

  @doc """
  Inserts a hand-built note row (a `%Note{}` or changeset, e.g. a legacy
  envelope a test builds) and its body row, as an app writer does: the
  body ciphertexts are virtual on `Note` (R8(b2)), so `Repo.insert!/2`
  alone would drop them. Returns the note with them set.
  """
  def insert_note_row!(note_or_changeset, opts \\ [skip_tenant_check: true]) do
    note = Repo.insert!(note_or_changeset, opts)

    values =
      case note_or_changeset do
        %Ecto.Changeset{} = cs -> Ecto.Changeset.apply_changes(cs)
        %Note{} = n -> n
      end
      |> Map.take(NoteBody.body_fields())

    _ = NoteBody.put!({note.id, values})
    struct(note, values)
  end

  @doc """
  Sets a note's `notes` content and CRDT state ciphertexts to the envelopes
  its body row holds: the row a release before R8(b2) (which still wrote
  those columns) leaves. For the null batch (`NoteBodyColumnsNull`) and the
  pre-split copy (`NoteSplit`). R8(c) drops the columns and this with them.
  """
  def old_release_notes_copy!(note_id) do
    Engram.Repo.query!(
      """
      UPDATE notes AS n SET content_ciphertext = substring(b.content_ct FROM 14),
        crdt_state_ciphertext = substring(b.crdt_ct FROM 14)
      FROM note_bodies AS b WHERE b.note_id = n.id AND n.id = $1
      """,
      [Ecto.UUID.dump!(note_id)]
    )

    :ok
  end

  @doc """
  Runs migration 20261107120000 (R8(c): every note gets its body row before
  boot) on the test's sandbox connection, as an upgrade runs it.
  """
  def complete_split! do
    Code.require_file(
      "priv/repo/migrations/20261107120000_note_bodies_complete_split_migrate.exs"
    )

    # By name at runtime: migrations are not compiled with the app.
    mod = String.to_existing_atom("Elixir.Engram.Repo.Migrations.NoteBodiesCompleteSplitMigrate")
    mod.complete_split(Engram.Repo)
  end

  @doc """
  Copies a note's `notes` body columns into its `note_bodies` row whole
  (the trigger's mapping; a missing row is inserted). Readers take the body
  from `note_bodies`, and nothing copies a raw `notes` write there, so a
  test that writes `notes` body columns directly (a tampered ciphertext, a
  legacy shape) calls this to put the bytes where they are read.
  """
  def mirror_body!(note_id) do
    # Each body pair rebuilt from the `notes` row: its nonce, its ciphertext,
    # or (not written there since R8(b2)) the ciphertext the body holds. The
    # `notes` row is not touched, so no trigger fires.
    merged = fn ct, nonce, body ->
      ct = if body, do: "COALESCE(n.#{ct}, substring(b.#{body} FROM 14))", else: "n.#{ct}"

      """
      CASE WHEN #{ct} IS NULL THEN NULL
        WHEN n.#{nonce} IS NULL THEN #{ct}
        WHEN length(n.#{nonce}) = 13 THEN n.#{nonce} || #{ct}
        ELSE '\\x00'::bytea || n.#{nonce} || #{ct} END
      """
    end

    %{num_rows: n} =
      Engram.Repo.query!(
        """
        UPDATE note_bodies AS b SET
          user_id = n.user_id,
          key_version = CASE WHEN n.dek_version BETWEEN 0 AND 32767 THEN n.dek_version ELSE 0 END,
          content_ct = #{merged.("content_ciphertext", "content_nonce", "content_ct")},
          crdt_ct = #{merged.("crdt_state_ciphertext", "crdt_state_nonce", "crdt_ct")},
          crdt_head = CASE WHEN n.crdt_head ~ '^[A-Za-z0-9_-]{43}$'
            THEN decode(translate(n.crdt_head, '-_', '+/') || '=', 'base64') END
        FROM notes AS n WHERE n.id = b.note_id AND n.id = $1
        """,
        [Ecto.UUID.dump!(note_id)]
      )

    # With no body row, insert it whole from the notes columns (the R8(c)
    # split migration's insert).
    if n == 0 do
      Engram.Repo.query!(
        """
        INSERT INTO note_bodies (note_id, user_id, key_version, content_ct, crdt_ct, crdt_head)
        SELECT n.id, n.user_id,
          CASE WHEN n.dek_version BETWEEN 0 AND 32767 THEN n.dek_version ELSE 0 END,
          #{merged.("content_ciphertext", "content_nonce", nil)},
          #{merged.("crdt_state_ciphertext", "crdt_state_nonce", nil)},
          CASE WHEN n.crdt_head ~ '^[A-Za-z0-9_-]{43}$'
            THEN decode(translate(n.crdt_head, '-_', '+/') || '=', 'base64') END
        FROM notes AS n WHERE n.id = $1 AND n.kind = 'note'
        """,
        [Ecto.UUID.dump!(note_id)]
      )
    end

    :ok
  end

  @doc """
  Inserts an active subscription for a user.

  Accepts optional attribute overrides (status, tier, etc.).
  """
  def subscription_fixture(user, attrs \\ %{}) do
    defaults = %{
      user_id: user.id,
      status: "active",
      tier: "starter",
      paddle_customer_id: "ctm_#{System.unique_integer([:positive])}",
      paddle_subscription_id: "sub_#{System.unique_integer([:positive])}"
    }

    Repo.insert!(
      struct(Engram.Billing.Subscription, Map.merge(defaults, attrs)),
      skip_tenant_check: true
    )
  end

  @doc """
  A Paddle transaction as `GET /transactions` returns it: completed and
  nonzero by default, so it has an invoice. Override `status` or
  `grand_total` for the invoice-less shapes ($0 trial start, draft, ...).
  """
  def paddle_transaction(id, attrs \\ %{}) do
    %{
      "id" => id,
      "status" => Map.get(attrs, :status, "completed"),
      "details" => %{
        "totals" => %{
          "grand_total" => Map.get(attrs, :grand_total, "2000"),
          "currency_code" => "USD"
        }
      },
      "payments" => []
    }
  end
end
