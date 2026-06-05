defmodule Engram.Auth.Clerk.WebhookTest do
  use Engram.DataCase, async: false

  alias Engram.Accounts
  alias Engram.Auth.Clerk.Webhook

  describe "user.deleted" do
    test "soft-deletes local user and force-disconnects live sockets" do
      # Need another admin so soft_delete_user does not refuse this as last admin.
      _other = insert(:user, role: "admin")
      user = insert(:user, role: "member", external_id: "clerk_user_kick_1")

      topic = "user_socket:#{user.id}"
      EngramWeb.Endpoint.subscribe(topic)

      assert :ok =
               Webhook.handle(%{"type" => "user.deleted", "data" => %{"id" => user.external_id}})

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      refute is_nil(reloaded.deleted_at)

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    test "no-op when local user does not exist (e.g. duplicate-signup path)" do
      assert :ok =
               Webhook.handle(%{
                 "type" => "user.deleted",
                 "data" => %{"id" => "clerk_user_never_existed"}
               })
    end

    test "no-op when payload missing id" do
      assert :ok = Webhook.handle(%{"type" => "user.deleted", "data" => %{}})
    end

    test "refuses to soft-delete the last active admin" do
      admin = insert(:user, role: "admin", external_id: "clerk_user_solo_admin")

      assert :ok =
               Webhook.handle(%{"type" => "user.deleted", "data" => %{"id" => admin.external_id}})

      reloaded = Engram.Repo.get!(Engram.Accounts.User, admin.id, skip_tenant_check: true)
      assert is_nil(reloaded.deleted_at)

      assert {:ok, _} = Accounts.find_by_external_id(admin.external_id)
    end
  end
end
