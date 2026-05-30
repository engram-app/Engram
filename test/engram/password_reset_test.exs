defmodule Engram.PasswordResetTest do
  use Engram.DataCase, async: false
  alias Engram.Accounts.PasswordReset

  defp seeded_member do
    {:ok, _} =
      Engram.Accounts.create_user_with_password(
        "admin#{System.unique_integer([:positive])}@x.com",
        "longpassword1"
      )

    {:ok, u} =
      Engram.Accounts.create_user_with_password(
        "u#{System.unique_integer([:positive])}@x.com",
        "oldpassword1"
      )

    u
  end

  test "issue/2 returns a raw token, stores a hash" do
    user = seeded_member()
    admin = insert(:user, role: "admin")
    {:ok, {raw, tok}} = PasswordReset.issue(user, admin)
    assert is_binary(raw)
    assert tok.token_hash == :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    assert is_nil(tok.used_at)
  end

  test "redeem/2 sets a new password and consumes the token" do
    user = seeded_member()
    admin = insert(:user, role: "admin")
    {:ok, {raw, _}} = PasswordReset.issue(user, admin)
    assert {:ok, _} = PasswordReset.redeem(raw, "newpassword2")
    assert {:error, :invalid} = PasswordReset.redeem(raw, "another3")
    assert {:ok, _} = Engram.Accounts.verify_password(user.email, "newpassword2")
  end

  test "redeem/2 rejects an expired token" do
    user = seeded_member()
    admin = insert(:user, role: "admin")
    {:ok, {raw, _}} = PasswordReset.issue(user, admin)

    Engram.Repo.update_all(Engram.Accounts.PasswordReset.Token,
      set: [expires_at: ~U[2000-01-01 00:00:00Z]]
    )

    assert {:error, :invalid} = PasswordReset.redeem(raw, "newpassword2")
  end

  # Spec §8/§10 — a reset kills all existing sessions.
  test "redeem/2 revokes the user's existing refresh tokens" do
    user = seeded_member()
    admin = insert(:user, role: "admin")
    {:ok, raw_refresh, _} = Engram.Accounts.create_refresh_token(user)
    {:ok, {raw, _}} = PasswordReset.issue(user, admin)
    assert {:ok, _} = PasswordReset.redeem(raw, "newpassword2")
    assert {:error, _} = Engram.Accounts.consume_refresh_token(raw_refresh)
  end
end
