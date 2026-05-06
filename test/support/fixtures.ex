defmodule Engram.Fixtures do
  @moduledoc "Convenience helpers for inserting common test fixtures."

  import Ecto.Query

  alias Engram.Repo

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
