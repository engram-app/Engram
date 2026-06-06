defmodule Engram.Accounts.LifecycleTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Accounts.Lifecycle
  alias Engram.Auth.RefreshToken
  alias Engram.Repo

  setup :verify_on_exit!

  setup do
    prev_provider = Application.get_env(:engram, :email_provider)
    Application.put_env(:engram, :email_provider, Engram.Email.ProviderMock)

    on_exit(fn ->
      if is_nil(prev_provider),
        do: Application.delete_env(:engram, :email_provider),
        else: Application.put_env(:engram, :email_provider, prev_provider)
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
end
