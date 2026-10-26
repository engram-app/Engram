defmodule Engram.Fixtures do
  @moduledoc "Convenience helpers for inserting common test fixtures."

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Crypto.Envelope
  alias Engram.Notes.Note
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
    user =
      case user.encrypted_dek do
        nil ->
          {:ok, u} = Engram.Crypto.ensure_user_dek(user)
          u

        _ ->
          user
      end

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
    now = DateTime.utc_now()

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

    note_attrs = Map.merge(base_attrs, extras)

    {:ok, inserted} =
      Repo.with_tenant(user.id, fn ->
        # DB-enforced NOT NULL (NULL-seq rows vanish from the sync feed) —
        # stamp a real per-vault seq inside the tenant txn (next_seq!'s
        # row-lock contract) unless the caller overrode it.
        note_attrs = Map.put_new(note_attrs, :seq, Engram.Vaults.next_seq!(vault.id))

        %Note{}
        |> Note.changeset(note_attrs)
        |> Repo.insert!()
      end)

    # Splice virtual fields so callers can read note.path / .folder / .tags
    # without re-fetching + decrypting.
    %{inserted | path: path, folder: folder, tags: tags, created_at: now, updated_at: now}
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
        Repo.one!(
          from(n in Note,
            where: n.user_id == ^user.id and n.path_hmac == ^hmac
          )
        )
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
        Engram.Repo.get(Engram.Notes.Note, id)
      end)

    row
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
