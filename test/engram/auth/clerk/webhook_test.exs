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

  # The external_id lookup in `handle_user_created` and the email lookup in
  # `apply_user_created` are not atomic. A user's first authenticated request
  # JIT-creates their row (same Clerk id) in between, so the email lookup finds
  # the user's OWN row. These tests pin the state at email-lookup time (#2292).
  describe "user.created: email match at dup-check time" do
    test "row already bound to the incoming Clerk id is ours: no rejection, no Clerk delete" do
      user =
        insert(:user,
          email: "racer@gmail.com",
          normalized_email: "racer@gmail.com",
          external_id: "user_race_self"
        )

      # Mox (verify_on_exit!) fails the test if delete_user is called.
      assert :ok = Webhook.apply_user_created("user_race_self", user.email, "racer@gmail.com")

      assert Repo.get(User, user.id, skip_tenant_check: true)
      assert :error = Engram.Auth.SignupRejections.fetch("user_race_self")
    end

    test "row bound to a different Clerk id is a real duplicate: rejected and revoked" do
      _existing =
        insert(:user,
          email: "taken.dup@gmail.com",
          normalized_email: "takendup@gmail.com",
          external_id: "user_original"
        )

      expect(Engram.Auth.Clerk.ApiMock, :delete_user, fn "user_second" -> :ok end)

      assert :ok =
               Webhook.apply_user_created(
                 "user_second",
                 "Taken.Dup@gmail.com",
                 "takendup@gmail.com"
               )

      assert {:ok, :duplicate_identity} = Engram.Auth.SignupRejections.fetch("user_second")
    end

    test "row with no Clerk id (legacy/local account) is still a duplicate: rejected and revoked" do
      _existing =
        insert(:user,
          email: "legacy.dup@gmail.com",
          normalized_email: "legacydup@gmail.com",
          external_id: nil
        )

      expect(Engram.Auth.Clerk.ApiMock, :delete_user, fn "user_vs_legacy" -> :ok end)

      assert :ok =
               Webhook.apply_user_created(
                 "user_vs_legacy",
                 "legacy.dup@gmail.com",
                 "legacydup@gmail.com"
               )

      assert {:ok, :duplicate_identity} = Engram.Auth.SignupRejections.fetch("user_vs_legacy")
    end
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

    test "last-admin protection: returns :ok, logs telemetry, leaves user soft-deleted" do
      admin =
        insert(:user, role: "admin", external_id: "clerk_user_last_admin")

      admin_id = admin.id

      # soft_delete still runs (email goes out).
      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, _html, _opts -> :ok end)

      # hard_delete returns {:error, :last_admin} before Clerk.delete_user
      # is hit; Mox verifies it's NOT called.

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:engram, :auth, :clerk_user_deleted_last_admin_protected]
        ])

      assert :ok =
               Webhook.handle(%{
                 "type" => "user.deleted",
                 "data" => %{"id" => admin.external_id}
               })

      # User row is still present (soft-deleted but not purged).
      assert reloaded = Repo.get(User, admin_id, skip_tenant_check: true)
      assert %DateTime{} = reloaded.deleted_at

      assert_receive {[:engram, :auth, :clerk_user_deleted_last_admin_protected], ^ref, _, _}
    end
  end
end
