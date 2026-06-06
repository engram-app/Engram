defmodule Engram.Auth.Clerk.WebhookTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Accounts.User
  alias Engram.Auth.Clerk.Webhook
  alias Engram.Repo
  alias Engram.Storage.InMemory

  setup :verify_on_exit!

  setup do
    InMemory.ensure_table()

    prev_provider = Application.get_env(:engram, :email_provider)
    prev_storage = Application.get_env(:engram, :storage)
    prev_clerk_api = Application.get_env(:engram, :clerk_api)
    prev_paddle_client = Application.get_env(:engram, :paddle_client)

    Application.put_env(:engram, :email_provider, Engram.Email.ProviderMock)
    Application.put_env(:engram, :storage, InMemory)

    on_exit(fn ->
      if is_nil(prev_provider),
        do: Application.delete_env(:engram, :email_provider),
        else: Application.put_env(:engram, :email_provider, prev_provider)

      if is_nil(prev_storage),
        do: Application.delete_env(:engram, :storage),
        else: Application.put_env(:engram, :storage, prev_storage)

      if is_nil(prev_clerk_api),
        do: Application.delete_env(:engram, :clerk_api),
        else: Application.put_env(:engram, :clerk_api, prev_clerk_api)

      if is_nil(prev_paddle_client),
        do: Application.delete_env(:engram, :paddle_client),
        else: Application.put_env(:engram, :paddle_client, prev_paddle_client)
    end)

    :ok
  end

  describe "user.deleted" do
    test "drives Lifecycle.soft_delete + hard_delete with :clerk reason, removing the local user" do
      user = insert(:user, external_id: "clerk_user_kick_1")
      user_id = user.id

      topic = "user_socket:#{user.id}"
      EngramWeb.Endpoint.subscribe(topic)

      # soft_delete sends the account-deleted notice.
      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, _html, _opts -> :ok end)

      # hard_delete fires Clerk.delete_user (external_id is set).
      expect(Engram.Auth.Clerk.ApiMock, :delete_user, fn clerk_id ->
        assert clerk_id == "clerk_user_kick_1"
        :ok
      end)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:engram, :account, :deleted]
        ])

      assert :ok =
               Webhook.handle(%{
                 "type" => "user.deleted",
                 "data" => %{"id" => user.external_id}
               })

      # Row is gone — hard_delete cascade ran.
      refute Repo.get(User, user_id, skip_tenant_check: true)

      # Telemetry carries :clerk reason.
      assert_receive {[:engram, :account, :deleted], ^ref, %{count: 1}, %{reason: :clerk}}

      # Step 0 of hard_delete kicks live sockets.
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    test "no-op when local user does not exist (e.g. duplicate-signup path)" do
      # No Email / Clerk / Paddle expectations — Mox verifies none are called.
      assert :ok =
               Webhook.handle(%{
                 "type" => "user.deleted",
                 "data" => %{"id" => "clerk_user_never_existed"}
               })
    end

    test "no-op when payload missing id" do
      assert :ok = Webhook.handle(%{"type" => "user.deleted", "data" => %{}})
    end
  end
end
