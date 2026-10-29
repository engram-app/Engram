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

  defp user_created(clerk_id, email) do
    Webhook.handle(%{
      "type" => "user.created",
      "data" => %{
        "id" => clerk_id,
        "primary_email_address_id" => "idn_1",
        "email_addresses" => [%{"id" => "idn_1", "email_address" => email}]
      }
    })
  end

  # Clerk's "Block email subaddresses" refuses aliases before a Clerk user
  # exists, so the webhook no longer polices duplicates. It must never call
  # Clerk delete: in prod every one of those deletes hit a real user (#2292).
  # Mox (verify_on_exit!) fails these tests on any delete_user call.
  describe "user.created never deletes a Clerk user" do
    test "alias of an existing user: no Clerk delete, existing row intact, no new row" do
      existing =
        insert(:user,
          email: "taken.dup@gmail.com",
          normalized_email: "takendup@gmail.com",
          external_id: "user_original"
        )

      assert :ok = user_created("user_second", "Taken.Dup+x@gmail.com")

      assert Repo.reload!(existing, skip_tenant_check: true).external_id == "user_original"
      assert {:error, :user_not_found} = Engram.Accounts.find_by_external_id("user_second")
    end

    test "orphan row with the same email (re-signup after delete): no Clerk delete" do
      orphan =
        insert(:user,
          email: "back.again@gmail.com",
          normalized_email: "backagain@gmail.com",
          external_id: "user_old_id"
        )

      assert :ok = user_created("user_new_id", "back.again@gmail.com")

      assert Repo.reload!(orphan, skip_tenant_check: true).external_id == "user_old_id"
    end

    # The prod race: X's first request JIT-creates X's row, then Clerk delivers
    # user.created for an alias Y and, after the old code deleted Y in Clerk,
    # user.deleted for Y. X's row must survive and Clerk is never called.
    test "race: JIT row for X survives user.created + user.deleted for alias Y" do
      {:ok, x} =
        Engram.Accounts.find_or_create_by_external_id("user_x", %{email: "racer@gmail.com"})

      assert :ok = user_created("user_y", "r.acer@gmail.com")
      assert :ok = Webhook.handle(%{"type" => "user.deleted", "data" => %{"id" => "user_y"}})

      assert Repo.get(User, x.id, skip_tenant_check: true)
    end

    test "new email creates the row through the JIT path" do
      assert :ok = user_created("user_fresh", "fresh.signup@gmail.com")

      assert {:ok, user} = Engram.Accounts.find_by_external_id("user_fresh")
      assert user.normalized_email == "freshsignup@gmail.com"
    end

    test "replay for an existing row is a no-op" do
      {:ok, x} =
        Engram.Accounts.find_or_create_by_external_id("user_replay", %{email: "replay@gmail.com"})

      assert :ok = user_created("user_replay", "replay@gmail.com")
      assert Repo.get(User, x.id, skip_tenant_check: true)
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
