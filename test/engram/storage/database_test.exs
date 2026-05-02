defmodule Engram.Storage.DatabaseTest do
  use Engram.DataCase, async: true

  alias Engram.Storage
  alias Engram.Storage.Database

  @binary <<137, 80, 78, 71, 13, 10, 26, 10>>
  @path "photos/test.png"

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)
    key = Storage.key(user.id, vault.id, @path)
    %{user: user, vault: vault, key: key}
  end

  describe "put/3" do
    test "stores content in the database", %{key: key} do
      assert :ok = Database.put(key, @binary, content_type: "image/png")
    end

    test "upserts on duplicate path", %{key: key} do
      assert :ok = Database.put(key, @binary, content_type: "image/png")

      updated = "updated content"
      assert :ok = Database.put(key, updated, content_type: "image/png")

      assert {:ok, ^updated} = Database.get(key)
    end

    test "undeletes a soft-deleted attachment", %{key: key} do
      assert :ok = Database.put(key, @binary)
      assert :ok = Database.delete(key)
      assert {:error, :not_found} = Database.get(key)

      assert :ok = Database.put(key, @binary)
      assert {:ok, @binary} = Database.get(key)
    end
  end

  describe "get/1" do
    test "returns content binary", %{key: key} do
      Database.put(key, @binary)
      assert {:ok, @binary} = Database.get(key)
    end

    test "returns :not_found for nonexistent key", %{user: user, vault: vault} do
      key = Storage.key(user.id, vault.id, "nonexistent.png")
      assert {:error, :not_found} = Database.get(key)
    end

    test "returns :not_found for soft-deleted attachment", %{key: key} do
      Database.put(key, @binary)
      Database.delete(key)
      assert {:error, :not_found} = Database.get(key)
    end
  end

  describe "delete/1" do
    test "soft-deletes an attachment", %{key: key} do
      Database.put(key, @binary)
      assert :ok = Database.delete(key)
      assert {:error, :not_found} = Database.get(key)
    end

    test "is idempotent", %{key: key} do
      Database.put(key, @binary)
      assert :ok = Database.delete(key)
      assert :ok = Database.delete(key)
    end

    test "returns :ok for nonexistent key", %{user: user, vault: vault} do
      key = Storage.key(user.id, vault.id, "ghost.png")
      assert :ok = Database.delete(key)
    end
  end

  describe "exists?/1" do
    test "returns true for existing attachment", %{key: key} do
      Database.put(key, @binary)
      assert Database.exists?(key) == true
    end

    test "returns false for nonexistent attachment", %{user: user, vault: vault} do
      key = Storage.key(user.id, vault.id, "nope.png")
      assert Database.exists?(key) == false
    end

    test "returns false for soft-deleted attachment", %{key: key} do
      Database.put(key, @binary)
      Database.delete(key)
      assert Database.exists?(key) == false
    end
  end

  describe "parse_key error handling" do
    test "raises ArgumentError for key without two slashes" do
      assert_raise ArgumentError, ~r/invalid storage key format/, fn ->
        Database.get("noslash")
      end
    end

    test "raises ArgumentError for key with only one slash" do
      assert_raise ArgumentError, ~r/invalid storage key format/, fn ->
        Database.get("1/path")
      end
    end

    test "raises ArgumentError for empty string key" do
      assert_raise ArgumentError, ~r/invalid storage key format/, fn ->
        Database.get("")
      end
    end

    test "raises ArgumentError for non-numeric user_id" do
      assert_raise ArgumentError, fn ->
        Database.get("abc/1/path")
      end
    end
  end

  describe "multi-tenant isolation" do
    test "user B cannot read user A's content", %{key: key_a, vault: vault} do
      Database.put(key_a, @binary)

      user_b = insert(:user)
      key_b = Storage.key(user_b.id, vault.id, @path)

      assert {:error, :not_found} = Database.get(key_b)
    end
  end
end
