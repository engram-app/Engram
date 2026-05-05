defmodule Engram.Auth.Providers.LocalTest do
  use Engram.DataCase, async: true

  import Ecto.Query
  alias Engram.Auth.Providers.Local

  describe "register_user/3" do
    test "creates a user with hashed password" do
      assert {:ok, %{external_id: ext_id, email: "new@local.test"}} =
               Local.register_user("new@local.test", "StrongPass123!", %{})

      assert is_binary(ext_id)
    end

    test "first user gets admin role" do
      {:ok, %{external_id: ext_id}} =
        Local.register_user("admin@local.test", "StrongPass123!", %{})

      user = Engram.Repo.one!(from u in Engram.Accounts.User, where: u.external_id == ^ext_id)
      assert user.role == "admin"
    end

    test "second user gets member role" do
      {:ok, _} = Local.register_user("first@local.test", "StrongPass123!", %{})

      {:ok, %{external_id: ext_id}} =
        Local.register_user("second@local.test", "StrongPass123!", %{})

      user = Engram.Repo.one!(from u in Engram.Accounts.User, where: u.external_id == ^ext_id)
      assert user.role == "member"
    end

    test "rejects duplicate email" do
      {:ok, _} = Local.register_user("dup@local.test", "StrongPass123!", %{})
      assert {:error, _} = Local.register_user("dup@local.test", "StrongPass123!", %{})
    end

    test "rejects password shorter than 8 characters" do
      assert {:error, :password_too_short} = Local.register_user("short@local.test", "abc", %{})
    end

    test "rejects password longer than 72 bytes (bcrypt limit)" do
      long_pass = String.duplicate("a", 73)
      assert {:error, :password_too_long} = Local.register_user("long@local.test", long_pass, %{})
    end

    test "stores password as bcrypt hash, never plaintext" do
      password = "StrongPass123!"
      {:ok, %{external_id: ext_id}} = Local.register_user("hash@local.test", password, %{})

      user = Engram.Repo.one!(from u in Engram.Accounts.User, where: u.external_id == ^ext_id)
      assert String.starts_with?(user.password_hash, "$2b$")
      refute user.password_hash == password
    end

    test "normalizes email to lowercase" do
      {:ok, %{email: email}} = Local.register_user("UPPER@Local.Test", "StrongPass123!", %{})
      assert email == "upper@local.test"
    end
  end

  describe "authenticate_credentials/2" do
    test "returns external_id and email for valid credentials" do
      {:ok, %{external_id: ext_id}} =
        Local.register_user("auth@local.test", "StrongPass123!", %{})

      assert {:ok, %{external_id: ^ext_id, email: "auth@local.test"}} =
               Local.authenticate_credentials("auth@local.test", "StrongPass123!")
    end

    test "rejects wrong password" do
      {:ok, _} = Local.register_user("wrong@local.test", "StrongPass123!", %{})

      assert {:error, :invalid_credentials} =
               Local.authenticate_credentials("wrong@local.test", "WrongPass!")
    end

    test "rejects nonexistent user (constant-time)" do
      assert {:error, :invalid_credentials} =
               Local.authenticate_credentials("noone@local.test", "Whatever123!")
    end

    test "login works with different email casing" do
      {:ok, _} = Local.register_user("case@local.test", "StrongPass123!", %{})

      assert {:ok, %{email: "case@local.test"}} =
               Local.authenticate_credentials("CASE@Local.Test", "StrongPass123!")
    end

    test "rejects Clerk user (nil password_hash) attempting local login" do
      # Simulate a Clerk-provisioned user with no password
      Engram.Repo.insert!(
        %Engram.Accounts.User{
          external_id: "clerk_ext_123",
          email: "clerk_user@test.com",
          password_hash: nil,
          role: "member"
        },
        skip_tenant_check: true
      )

      assert {:error, :invalid_credentials} =
               Local.authenticate_credentials("clerk_user@test.com", "AnyPassword!")
    end
  end

  describe "verify_token/1" do
    test "verifies a self-issued JWT" do
      {:ok, %{external_id: ext_id}} = Local.register_user("jwt@local.test", "StrongPass123!", %{})
      {:ok, token} = Local.issue_access_token(ext_id, "jwt@local.test")

      assert {:ok, %{external_id: ^ext_id, email: "jwt@local.test"}} = Local.verify_token(token)
    end

    test "rejects expired token" do
      claims = %{
        "sub" => "fake_id",
        "email" => "exp@test.com",
        "exp" => :os.system_time(:second) - 60,
        "iss" => "engram",
        "aud" => "engram"
      }

      {:ok, token, _} = Engram.Token.generate_and_sign(claims)
      assert {:error, _} = Local.verify_token(token)
    end

    test "rejects garbage" do
      assert {:error, _} = Local.verify_token("not.a.jwt")
    end

    test "access token expires in ~15 minutes" do
      {:ok, %{external_id: ext_id}} = Local.register_user("ttl@local.test", "StrongPass123!", %{})
      {:ok, token} = Local.issue_access_token(ext_id, "ttl@local.test")
      {:ok, claims} = Engram.Token.verify_and_validate(token)

      now = :os.system_time(:second)
      ttl = claims["exp"] - now
      # Should be between 14 and 16 minutes (allow clock drift)
      assert ttl >= 14 * 60 and ttl <= 16 * 60
    end
  end

  describe "supports_credentials?/0" do
    test "returns true" do
      assert Local.supports_credentials?() == true
    end
  end
end
