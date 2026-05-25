defmodule Engram.Storage.DatabaseTest do
  use Engram.DataCase, async: true

  alias Engram.Storage.Database

  @binary <<137, 80, 78, 71, 13, 10, 26, 10>>

  describe "put/3 and get/1" do
    test "stores and retrieves a binary" do
      assert :ok = Database.put("1/2/a.png", @binary)
      assert {:ok, @binary} = Database.get("1/2/a.png")
    end

    test "get returns :not_found for a missing key" do
      assert {:error, :not_found} = Database.get("nope/missing")
    end

    test "put overwrites an existing key (upsert)" do
      assert :ok = Database.put("1/2/a.png", @binary)
      assert :ok = Database.put("1/2/a.png", <<0, 1, 2>>)
      assert {:ok, <<0, 1, 2>>} = Database.get("1/2/a.png")
    end

    test "ignores content_type opt" do
      assert :ok = Database.put("1/2/a.png", @binary, content_type: "image/png")
      assert {:ok, @binary} = Database.get("1/2/a.png")
    end
  end

  describe "exists?/1" do
    test "true when present, false when absent" do
      assert :ok = Database.put("1/2/a.png", @binary)
      assert Database.exists?("1/2/a.png") == true
      assert Database.exists?("1/2/missing.png") == false
    end
  end

  describe "delete/1" do
    test "removes a stored key" do
      assert :ok = Database.put("1/2/a.png", @binary)
      assert :ok = Database.delete("1/2/a.png")
      assert {:error, :not_found} = Database.get("1/2/a.png")
    end

    test "is a no-op (:ok) for a missing key" do
      assert :ok = Database.delete("1/2/missing.png")
    end
  end

  describe "delete_prefix/1" do
    test "deletes only keys under the prefix and returns the count" do
      assert :ok = Database.put("1/2/a.png", @binary)
      assert :ok = Database.put("1/2/b.png", @binary)
      assert :ok = Database.put("2/2/c.png", @binary)

      assert {:ok, 2} = Database.delete_prefix("1/")

      assert {:error, :not_found} = Database.get("1/2/a.png")
      assert {:error, :not_found} = Database.get("1/2/b.png")
      assert {:ok, @binary} = Database.get("2/2/c.png")
    end

    test "treats LIKE metacharacters in the prefix literally" do
      assert :ok = Database.put("1_0/x.png", @binary)
      assert :ok = Database.put("100/x.png", @binary)

      # "1_" must not match "10" — the underscore is escaped.
      assert {:ok, 1} = Database.delete_prefix("1_0/")

      assert {:error, :not_found} = Database.get("1_0/x.png")
      assert {:ok, @binary} = Database.get("100/x.png")
    end
  end

  describe "list_user_prefixes/0" do
    test "returns distinct integer first segments" do
      assert :ok = Database.put("1/2/a.png", @binary)
      assert :ok = Database.put("1/3/b.png", @binary)
      assert :ok = Database.put("2/2/c.png", @binary)
      assert :ok = Database.put("notanint/d.png", @binary)

      assert {:ok, ids} = Database.list_user_prefixes()
      assert Enum.sort(ids) == [1, 2]
    end
  end
end
