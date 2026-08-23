defmodule Engram.AttachmentsBroadcastTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Attachments

  setup :verify_on_exit!

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  describe "note_changed upsert broadcast on attachment create/upload (Engram#942)" do
    test "upsert_attachment/3 broadcasts a note_changed upsert event", %{
      user: user,
      vault: vault
    } do
      Mox.stub(Engram.MockStorage, :put, fn _key, _bin, _opts -> :ok end)

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      assert {:ok, _att} =
               Attachments.upsert_attachment(user, vault, %{
                 "path" => "photos/live.png",
                 "content_base64" => Base.encode64("live delivery content")
               })

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{
          "event_type" => "upsert",
          "kind" => "attachment",
          "path" => "photos/live.png"
        }
      }
    end

    test "the upsert payload carries content_hash so peers can skip the blob fetch", %{
      user: user,
      vault: vault
    } do
      # Engram#961 (1): without the hash, a peer that ALREADY holds these exact
      # bytes must GET the whole attachment — possibly many MB — only to
      # byte-compare and discover nothing changed. The hash is in hand at every
      # emit site; it just was not being sent.
      Mox.stub(Engram.MockStorage, :put, fn _key, _bin, _opts -> :ok end)
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      assert {:ok, att} =
               Attachments.upsert_attachment(user, vault, %{
                 "path" => "photos/live.png",
                 "content_base64" => Base.encode64("live delivery content")
               })

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "upsert", "content_hash" => hash}
      }

      assert is_binary(hash)
      # Must be the SAME value the REST endpoints serve, or a peer comparing
      # the two would never match and the fetch-skip could never fire.
      assert hash == att.content_hash
    end

    test "the move legs carry content_hash on both delete and upsert", %{
      user: user,
      vault: vault
    } do
      # A move fires delete(old) + upsert(new) through the same helper, so
      # parity is structural — pin it so a future split cannot drop one leg.
      Mox.stub(Engram.MockStorage, :put, fn _key, _bin, _opts -> :ok end)

      {:ok, att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "old/pic.png",
          "content_base64" => Base.encode64("bytes")
        })

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      {:ok, _} = Attachments.move_attachment(user, vault, "old/pic.png", "new/pic.png")

      assert_receive %Phoenix.Socket.Broadcast{
        payload: %{"event_type" => "delete", "content_hash" => del_hash}
      }

      assert_receive %Phoenix.Socket.Broadcast{
        payload: %{"event_type" => "upsert", "content_hash" => up_hash}
      }

      assert del_hash == att.content_hash
      assert up_hash == att.content_hash
    end
  end

  describe "note_changed delete broadcast attribution (#970)" do
    test "delete_attachment/4 stamps origin device_id into the broadcast", %{
      user: user,
      vault: vault
    } do
      Mox.stub(Engram.MockStorage, :put, fn _key, _bin, _opts -> :ok end)
      Mox.stub(Engram.MockStorage, :delete, fn _key -> :ok end)

      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "photos/gone.png",
          "content_base64" => Base.encode64("bye")
        })

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      device_id = Ecto.UUID.generate()

      assert :ok =
               Attachments.delete_attachment(user, vault, "photos/gone.png",
                 origin_device_id: device_id
               )

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "delete", "path" => "photos/gone.png"} = payload
      }

      assert payload["device_id"] == device_id
    end

    test "delete_attachment/3 omits device_id when no origin given", %{
      user: user,
      vault: vault
    } do
      Mox.stub(Engram.MockStorage, :put, fn _key, _bin, _opts -> :ok end)
      Mox.stub(Engram.MockStorage, :delete, fn _key -> :ok end)

      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "photos/plain.png",
          "content_base64" => Base.encode64("bye")
        })

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      assert :ok = Attachments.delete_attachment(user, vault, "photos/plain.png")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "delete", "path" => "photos/plain.png"} = payload
      }

      refute Map.has_key?(payload, "device_id")
    end
  end
end
