defmodule Engram.Fixtures do
  @moduledoc "Convenience helpers for inserting common test fixtures."

  import Ecto.Query

  alias Engram.Repo

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
          from(u in Engram.Accounts.User, where: u.id == ^user_with_dek.id),
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
    {path_ct, path_n} = Engram.Crypto.Envelope.encrypt(path, dek)
    {folder_ct, folder_n} = Engram.Crypto.Envelope.encrypt(folder, dek)
    {tags_ct, tags_n} = Engram.Crypto.Envelope.encrypt(:erlang.term_to_binary(tags), dek)
    {content_ct, content_n} = Engram.Crypto.Envelope.encrypt(content, dek)
    {title_ct, title_n} = Engram.Crypto.Envelope.encrypt(title, dek)

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
      tags_hmac: Enum.map(tags, &Engram.Crypto.hmac_field(filter_key, &1))
    }

    # Pull through any caller-specified overrides for non-Phase-B fields so
    # tests can set embed_hash, version, deleted_at, etc.
    extras =
      attrs
      |> Map.drop(["path", "folder", "tags", "content", "title", "mtime", "content_hash"])
      |> Enum.into(%{}, fn {k, v} -> {String.to_existing_atom(k), v} end)

    note_attrs = Map.merge(base_attrs, extras)

    {:ok, inserted} =
      Repo.with_tenant(user.id, fn ->
        %Engram.Notes.Note{}
        |> Engram.Notes.Note.changeset(note_attrs)
        |> Repo.insert!()
      end)

    # Splice virtual fields so callers can read note.path / .folder / .tags
    # without re-fetching + decrypting.
    %{inserted | path: path, folder: folder, tags: tags, created_at: now, updated_at: now}
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
    vault_id = Engram.Crypto.next_row_id(:vaults)

    # Legacy encrypt: empty AAD (dek_version 1 — pre-AAD-bind)
    {ct, nonce} = Engram.Crypto.Envelope.encrypt(name, dek, <<>>)

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
      struct(Engram.Vaults.Vault, attrs),
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
    user = Engram.Repo.get!(Engram.Accounts.User, user.id)
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    hmac = Engram.Crypto.hmac_field(filter_key, path)

    {:ok, note} =
      Repo.with_tenant(user.id, fn ->
        Repo.one!(
          from(n in Engram.Notes.Note,
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
    user = Engram.Repo.get!(Engram.Accounts.User, user.id)
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
    path = Map.get(attrs, "path", "test/att-#{System.unique_integer([:positive, :monotonic])}.bin")
    content = Map.get(attrs, "content", <<0, 1, 2, 3>>)
    mime_type = Map.get(attrs, "mime_type", "application/octet-stream")
    mtime = Map.get(attrs, "mtime", 0.0)

    {:ok, dek} = Engram.Crypto.get_dek(user)
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    {:ok, content_key} = Engram.Crypto.dek_content_hash_key(user)

    att_id = Engram.Crypto.next_row_id(:attachments)
    storage_key = Engram.Storage.key(user.id, vault.id, path)

    # Legacy v1 encrypt: empty AAD
    {content_ct, content_nonce} = Engram.Crypto.Envelope.encrypt(content, dek, <<>>)
    {path_ct, path_nonce} = Engram.Crypto.Envelope.encrypt(path, dek, <<>>)

    # Write ciphertext blob to storage
    :ok = Engram.Storage.adapter().put(storage_key, content_ct, content_type: mime_type)

    attrs = %{
      id: att_id,
      user_id: user.id,
      vault_id: vault.id,
      path_ciphertext: path_ct,
      path_nonce: path_nonce,
      path_hmac: Engram.Crypto.hmac_field(filter_key, path),
      content_hash: Engram.Crypto.hmac_content_hash(content_key, content),
      content_nonce: content_nonce,
      storage_key: storage_key,
      mime_type: mime_type,
      size_bytes: byte_size(content),
      mtime: mtime,
      encryption_version: 1,
      dek_version: 1
    }

    inserted =
      Repo.insert!(
        struct(Engram.Attachments.Attachment, attrs),
        skip_tenant_check: true
      )

    # Splice virtual path so callers can read att.path
    %{inserted | path: path}
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
      stripe_customer_id: "cus_#{System.unique_integer([:positive])}",
      stripe_subscription_id: "sub_#{System.unique_integer([:positive])}"
    }

    Repo.insert!(
      struct(Engram.Billing.Subscription, Map.merge(defaults, attrs)),
      skip_tenant_check: true
    )
  end
end
