defmodule Engram.FactoryTest do
  @moduledoc """
  Guards the test factory contract: factory-inserted users MUST match
  prod registration shape so encrypted-column tests don't accidentally
  exercise the `:no_dek` error path (which spams `vault decrypt_failed`
  logs and masks real decryption bugs).

  Tests that intentionally exercise the no-DEK path keep using raw
  `insert(:user)` or override `encrypted_dek: nil` explicitly.
  """
  use Engram.DataCase, async: true

  import Engram.Factory

  describe "insert_user/1" do
    test "returns a user with a wrapped DEK persisted" do
      user = insert_user()
      assert is_binary(user.encrypted_dek)
      assert byte_size(user.encrypted_dek) > 0

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      assert reloaded.encrypted_dek == user.encrypted_dek
    end

    test "accepts attribute overrides" do
      user = insert_user(email: "specific@test.com")
      assert user.email == "specific@test.com"
      assert is_binary(user.encrypted_dek)
    end
  end

  describe "raw insert(:user)" do
    test "still produces a user with no DEK (no-DEK opt-out path)" do
      user = insert(:user)
      assert is_nil(user.encrypted_dek)
    end
  end
end
