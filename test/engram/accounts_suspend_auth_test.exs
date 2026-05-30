defmodule Engram.AccountsSuspendAuthTest do
  use Engram.DataCase, async: false

  # First created user becomes admin; seed a throwaway first so the subject is a member.
  defp member_with_password do
    {:ok, _} =
      Engram.Accounts.create_user_with_password(
        "admin#{System.unique_integer([:positive])}@x.com",
        "longpassword1"
      )

    {:ok, u} =
      Engram.Accounts.create_user_with_password(
        "u#{System.unique_integer([:positive])}@x.com",
        "longpassword1"
      )

    u
  end

  test "verify_password/2 rejects a suspended user even with the right password" do
    user = member_with_password()
    assert {:ok, _} = Engram.Accounts.verify_password(user.email, "longpassword1")
    {:ok, _} = Engram.Accounts.suspend(user)
    assert {:error, :suspended} = Engram.Accounts.verify_password(user.email, "longpassword1")
  end

  test "verify_password/2 rejects a soft-deleted user" do
    user = member_with_password()
    {:ok, _} = Engram.Accounts.soft_delete_user(user)
    assert {:error, :deleted} = Engram.Accounts.verify_password(user.email, "longpassword1")
  end

  # Spec §10 — blocked at the refresh chokepoint, not just login.
  test "consume_refresh_token/1 rejects a suspended user" do
    user = member_with_password()
    {:ok, raw, _} = Engram.Accounts.create_refresh_token(user)
    {:ok, _} = Engram.Accounts.suspend(user)
    assert {:error, :suspended} = Engram.Accounts.consume_refresh_token(raw)
  end

  test "consume_refresh_token/1 rejects a soft-deleted user" do
    user = member_with_password()
    {:ok, raw, _} = Engram.Accounts.create_refresh_token(user)
    {:ok, _} = Engram.Accounts.soft_delete_user(user)
    assert {:error, :deleted} = Engram.Accounts.consume_refresh_token(raw)
  end
end
