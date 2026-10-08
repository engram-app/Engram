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
    test "maps each compressed column prefix to its mode" do
      for {aad, mode} <- [
            {"notes:content:1", :zstd},
            {"notes:crdt_state:1", :zstd},
            {"vault_index_states:state:1", :zstd},
            {"vault_index_update_log:update:1", :zstd},
            {"note_revisions:content:1", :zstd},
            {"attachments:content:1", :auto}
          ] do
        assert Envelope.compression_policy(aad) == mode, aad
      end
    end

    test "real NUL-separated row AADs from aad_for_row/3 match too" do
      id = Ecto.UUID.generate()
      assert Envelope.compression_policy(Crypto.aad_for_row(:notes, :content, id)) == :zstd
      assert Envelope.compression_policy(Crypto.aad_for_row(:notes, :crdt_state, id)) == :zstd
      assert Envelope.compression_policy(Crypto.aad_for_row(:notes, :title, id)) == :none
      assert Envelope.compression_policy(Crypto.aad_for_row(:attachments, :content, id)) == :auto
      assert Envelope.compression_policy(Crypto.aad_for_row(:attachments, :path, id)) == :none
    end

    test "everything else is :none" do
      for aad <- ["", "dek:v1:1", "qdrant:x", "notes:title:1", "attachments:path:1"] do
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

  describe "KeyProvider.Local" do
    test "wrap blob size is unchanged by the policy" do
      {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
      dek = :crypto.strong_rand_bytes(32)

      {:ok, on} = Local.wrap_dek(dek, %{user_id: user.id})
      Application.put_env(:engram, :envelope_compression, false)
      {:ok, off} = Local.wrap_dek(dek, %{user_id: user.id})

      assert byte_size(on) == byte_size(off)
      assert {:ok, ^dek} = Local.unwrap_dek(on, %{user_id: user.id})
    end
  end
end
