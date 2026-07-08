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
  end
end
