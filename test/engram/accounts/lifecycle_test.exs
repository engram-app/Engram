defmodule Engram.Accounts.LifecycleTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Accounts.Lifecycle
  alias Engram.Accounts.User
  alias Engram.Auth.RefreshToken
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

  defp attach_refresh_token!(user) do
    %RefreshToken{}
    |> RefreshToken.changeset(%{
      user_id: user.id,
      token_hash: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      family_id: Ecto.UUID.generate(),
      expires_at:
        DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second)
    })
    |> Repo.insert!(skip_tenant_check: true)
  end

  defp revoked_token_count(user) do
    from(rt in RefreshToken,
      where: rt.user_id == ^user.id and not is_nil(rt.revoked_at)
    )
    |> Repo.aggregate(:count)
  end

  defp soft_delete!(user) do
    user
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update!(skip_tenant_check: true)
  end

  describe "soft_delete/2" do
    test "sets users.deleted_at, revokes refresh tokens, emits telemetry" do
      user = insert(:user)
      attach_refresh_token!(user)

      expect(Engram.Email.ProviderMock, :send, fn to, subject, _html, _opts ->
        assert to == user.email
        assert subject =~ "auto-deleted"
        :ok
      end)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:engram, :account, :soft_deleted]
        ])

      assert :ok = Lifecycle.soft_delete(user, :user)

      reloaded = Repo.reload!(user)
      assert %DateTime{} = reloaded.deleted_at
      assert revoked_token_count(user) > 0

      assert_receive {[:engram, :account, :soft_deleted], ^ref, %{count: 1},
                      %{user_id_hmac: hmac, reason: :user}}

      assert is_binary(hmac)
      assert String.length(hmac) == 64
    end

    test "telemetry carries the passed-in reason atom" do
      user = insert(:user)

      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, _html, _opts -> :ok end)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:engram, :account, :soft_deleted]
        ])

      assert :ok = Lifecycle.soft_delete(user, :clerk)
      assert_receive {[:engram, :account, :soft_deleted], ^ref, _, %{reason: :clerk}}
    end

    test "no-op on already soft-deleted user" do
      user = insert(:user) |> soft_delete!()

      # No `expect` — Mox verifies in setup that send/4 is NOT called.
      assert :ok = Lifecycle.soft_delete(user, :user)
    end
  end

  describe "hard_delete/2" do
    test "no-op when user already deleted (re-entry guard)" do
      user = insert(:user)
      Repo.delete!(user, skip_tenant_check: true)

      # No Paddle / Clerk / Storage expectations — guard should short-circuit
      # since Repo.get by stale id returns nil.
      assert :ok = Lifecycle.hard_delete(user, :user)
    end

    test "user with no paddle sub + no external_id: skips Paddle + Clerk + wipes user" do
      user = insert(:user, external_id: nil)
      vault = insert(:vault, user: user)
      _note = insert(:note, vault: vault, user: user)
      InMemory.put("#{user.id}/vault1/file.png", "binary")
      InMemory.put("exports/#{user.id}/export-1.zip.enc", "binary")

      user_id = user.id

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:engram, :account, :deleted]
        ])

      # NO Paddle.ClientMock expectation — no sub means we skip.
      # NO Clerk.ApiMock expectation — nil external_id means we skip.
      # Mox verifies on exit that neither was called.

      assert :ok = Lifecycle.hard_delete(user, :user)

      refute Repo.get(User, user_id, skip_tenant_check: true)
      refute InMemory.exists?("#{user.id}/vault1/file.png")
      refute InMemory.exists?("exports/#{user.id}/export-1.zip.enc")

      assert_receive {[:engram, :account, :deleted], ^ref, %{count: 1},
                      %{user_id_hmac: hmac, reason: :user, had_sub: false}}

      assert is_binary(hmac)
      assert String.length(hmac) == 64
    end

    test "with paddle sub + external_id: cancels Paddle + deletes Clerk + emits had_sub:true" do
      user = insert(:user, external_id: "user_clerk_xyz")
      sub = insert(:subscription, user: user, paddle_subscription_id: "sub_test_abc")

      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn sub_id, effective_from, opts ->
        assert sub_id == "sub_test_abc"
        assert effective_from == :immediately
        assert Keyword.get(opts, :idempotency_key) == "hard-delete-#{user.id}"
        {:ok, %{}}
      end)

      expect(Engram.Auth.Clerk.ApiMock, :delete_user, fn clerk_id ->
        assert clerk_id == "user_clerk_xyz"
        :ok
      end)

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:engram, :account, :deleted]])

      user_id = user.id
      assert :ok = Lifecycle.hard_delete(user, :user)

      refute Repo.get(User, user_id, skip_tenant_check: true)
      # Subscription FK cascade
      refute Repo.get(Engram.Billing.Subscription, sub.id, skip_tenant_check: true)

      assert_receive {[:engram, :account, :deleted], ^ref, _,
                      %{reason: :user, had_sub: true}}
    end

    test "Paddle cancel failure does not abort the cascade" do
      user = insert(:user, external_id: nil)
      insert(:subscription, user: user, paddle_subscription_id: "sub_fail")

      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn _, _, _ ->
        {:error, :paddle_unavailable}
      end)

      user_id = user.id
      assert :ok = Lifecycle.hard_delete(user, :user)
      refute Repo.get(User, user_id, skip_tenant_check: true)
    end

    test "Clerk delete failure does not abort (commit point already passed)" do
      user = insert(:user, external_id: "user_clerk_fail")

      expect(Engram.Auth.Clerk.ApiMock, :delete_user, fn _ ->
        {:error, :clerk_unavailable}
      end)

      user_id = user.id
      assert :ok = Lifecycle.hard_delete(user, :user)
      refute Repo.get(User, user_id, skip_tenant_check: true)
    end

    test "S3 prefix delete retries once on first failure, continues on second" do
      user = insert(:user, external_id: nil)
      user_id = user.id

      # Swap default InMemory for MockStorage so we can assert call counts
      # without leaking a module into the global VM namespace.
      Application.put_env(:engram, :storage, Engram.MockStorage)

      # Two prefixes ("#{user_id}/" + "exports/#{user_id}/") × 2 calls each
      # (initial + retry) = 4 total delete_prefix invocations, all failing.
      expect(Engram.MockStorage, :delete_prefix, 4, fn _prefix ->
        {:error, :s3_down}
      end)

      assert :ok = Lifecycle.hard_delete(user, :user)
      refute Repo.get(User, user_id, skip_tenant_check: true)
    end

    test "S3 prefix delete succeeds on retry after first failure" do
      user = insert(:user, external_id: nil)
      user_id = user.id

      Application.put_env(:engram, :storage, Engram.MockStorage)

      # First call fails, retry succeeds — per prefix. Two prefixes = 4 calls,
      # alternating fail/ok.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      expect(Engram.MockStorage, :delete_prefix, 4, fn _prefix ->
        n = Agent.get_and_update(counter, fn s -> {s + 1, s + 1} end)
        if rem(n, 2) == 1, do: {:error, :s3_down}, else: {:ok, 0}
      end)

      assert :ok = Lifecycle.hard_delete(user, :user)
      refute Repo.get(User, user_id, skip_tenant_check: true)
    end

    test "idempotent: second call after Repo.delete is :ok and no-op" do
      user = insert(:user, external_id: nil)

      assert :ok = Lifecycle.hard_delete(user, :user)

      # Stale struct: second call sees no DB row, exits at re-entry guard.
      # No Paddle/Clerk expects — guard must prevent any side-effect.
      assert :ok = Lifecycle.hard_delete(user, :user)
    end

    test "passes :clerk reason through to telemetry" do
      user = insert(:user, external_id: nil)

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:engram, :account, :deleted]])

      assert :ok = Lifecycle.hard_delete(user, :clerk)

      assert_receive {[:engram, :account, :deleted], ^ref, _,
                      %{reason: :clerk, had_sub: false}}
    end

    test "passes :inactivity reason through to telemetry" do
      user = insert(:user, external_id: nil)

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:engram, :account, :deleted]])

      assert :ok = Lifecycle.hard_delete(user, :inactivity)

      assert_receive {[:engram, :account, :deleted], ^ref, _, %{reason: :inactivity}}
    end
  end
end
