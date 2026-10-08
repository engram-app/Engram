defmodule Engram.Crypto.EnvelopePolicyTest do
  # async: false: flips the global :envelope_compression flag.
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.Crypto
  alias Engram.Crypto.{Envelope, KeyProvider.Local, UserDekRotation}
  alias Engram.Notes.{CrdtBridge, Note}
  alias Engram.Repo

  @body String.duplicate("compressible body line\n", 200)

  setup do
    prev = Application.get_env(:engram, :envelope_compression)
    Application.put_env(:engram, :envelope_compression, true)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :envelope_compression),
        else: Application.put_env(:engram, :envelope_compression, prev)
    end)

    :ok
  end

  describe "compression_policy/1" do
    test "maps all six policy entries, built from real aad_for_row/3 AADs" do
      id = Ecto.UUID.generate()

      for {table, column, mode} <- [
            {:notes, :content, :zstd},
            {:notes, :crdt_state, :zstd},
            {:vault_index_states, :state, :zstd},
            {:vault_index_update_log, :update, :zstd},
            {:note_revisions, :content, :zstd},
            {:attachments, :content, :auto}
          ] do
        assert Envelope.compression_policy(Crypto.aad_for_row(table, column, id)) == mode,
               "#{table}.#{column}"
      end
    end

    test "non-policy columns and non-row AADs are :none" do
      id = Ecto.UUID.generate()

      for {table, column} <- [
            {:notes, :title},
            {:notes, :path},
            {:notes, :tags},
            {:attachments, :path},
            {:vaults, :name}
          ] do
        assert Envelope.compression_policy(Crypto.aad_for_row(table, column, id)) == :none,
               "#{table}.#{column}"
      end
    end

    test "everything else is :none" do
      for aad <- ["", "dek:v1:1", "qdrant:x", "notes:content:1"] do
        assert Envelope.compression_policy(aad) == :none, aad
      end
    end
  end

  describe "through the real write path and DEK rotation" do
    setup do
      # Rotation sweeps Qdrant; stub an empty scroll (same as user_dek_rotation_test).
      bypass = Bypass.open()
      Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"result" => %{"points" => [], "next_page_offset" => nil}})
        )
      end)

      {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
      {:ok, vault, _} = Engram.Vaults.register_vault(user, "PolicyVault", Ecto.UUID.generate())
      %{user: user, vault: vault}
    end

    defp raw_note(id), do: Repo.one!(from(n in Note, where: n.id == ^id), skip_tenant_check: true)

    defp reload(user),
      do:
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id),
          skip_tenant_check: true
        )

    test "content and crdt_state are format 1, title stays format 0, across rotation", %{
      user: user,
      vault: vault
    } do
      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{"path" => "pol/a.md", "content" => @body},
          actor: "api"
        )

      # Persist crdt_state the only way the app encrypts it (AAD bound to the row id).
      {:ok, doc} = CrdtBridge.doc_from_state(nil)
      :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), @body)
      {:ok, state} = Yex.encode_state_as_update(doc)
      {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(state, user, note.id)

      Repo.update_all(
        from(n in Note, where: n.id == ^note.id),
        [set: [crdt_state_ciphertext: ct, crdt_state_nonce: nonce]],
        skip_tenant_check: true
      )

      before = raw_note(note.id)
      assert byte_size(before.content_nonce) == 13
      assert byte_size(before.crdt_state_nonce) == 13
      assert byte_size(before.title_nonce) == 12

      assert :ok = UserDekRotation.rotate_user(user.id)

      after_rot = raw_note(note.id)
      assert byte_size(after_rot.content_nonce) == 13
      assert byte_size(after_rot.crdt_state_nonce) == 13
      assert byte_size(after_rot.title_nonce) == 12
      assert after_rot.content_ciphertext != before.content_ciphertext

      assert {:ok, ^state} = Crypto.decrypt_crdt_state(after_rot, reload(user))

      assert {:ok, %{content: @body}} =
               Crypto.decrypt_note_fields_unscrubbed(after_rot, reload(user))
    end
  end

  describe "AadRebind with the policy on" do
    test "a rebound legacy note ends up format 1 and decrypts" do
      {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
      {:ok, vault, _} = Engram.Vaults.register_vault(user, "RebindPolicy", Ecto.UUID.generate())
      {:ok, dek} = Crypto.get_dek(user)
      {:ok, filter_key} = Crypto.dek_filter_key(user)

      # Legacy row: every column sealed with empty AAD, dek_version 1.
      enc = fn plain ->
        {ct, n} = Envelope.encrypt(plain, dek)
        {ct, n}
      end

      {content_ct, content_n} = enc.(@body)
      {title_ct, title_n} = enc.("t")
      {path_ct, path_n} = enc.("legacy/p.md")
      {folder_ct, folder_n} = enc.("legacy")
      {tags_ct, tags_n} = enc.(:erlang.term_to_binary([]))

      legacy =
        Repo.insert!(
          %Note{
            content_hash: "h",
            seq: 1,
            mtime: 0.0,
            user_id: user.id,
            vault_id: vault.id,
            content_ciphertext: content_ct,
            content_nonce: content_n,
            title_ciphertext: title_ct,
            title_nonce: title_n,
            path_ciphertext: path_ct,
            path_nonce: path_n,
            path_hmac: Crypto.hmac_field(filter_key, "legacy/p.md"),
            folder_ciphertext: folder_ct,
            folder_nonce: folder_n,
            folder_hmac: Crypto.hmac_field(filter_key, "legacy"),
            tags_ciphertext: tags_ct,
            tags_nonce: tags_n,
            tags_hmac: [],
            dek_version: 1
          },
          skip_tenant_check: true
        )

      assert byte_size(legacy.content_nonce) == 12
      assert :ok = Engram.Crypto.AadRebind.rebind_user(user.id)

      row = raw_note(legacy.id)
      assert byte_size(row.content_nonce) == 13
      assert byte_size(row.title_nonce) == 12

      assert {:ok, @body} =
               Envelope.decrypt(
                 row.content_ciphertext,
                 row.content_nonce,
                 dek,
                 Crypto.aad_for_row(:notes, :content, row.id)
               )
    end
  end

  describe "KeyProvider.Local" do
    test "wrap blob size is unchanged by the policy" do
      {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
      dek = :crypto.strong_rand_bytes(32)

      {:ok, on} = Local.wrap_dek(dek, %{user_id: user.id})
      Application.put_env(:engram, :envelope_compression, false)
      {:ok, off} = Local.wrap_dek(dek, %{user_id: user.id})

      assert byte_size(on) == 62
      assert byte_size(on) == byte_size(off)
      assert {:ok, ^dek} = Local.unwrap_dek(on, %{user_id: user.id})
    end
  end
end
