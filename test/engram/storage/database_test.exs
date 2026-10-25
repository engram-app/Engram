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

  describe "get_range/3" do
    test "reads the bytes in range, and what exists past the end" do
      assert :ok = Database.put("1/2/a.png", "abcdef")
      assert {:ok, "bcd"} = Database.get_range("1/2/a.png", 1, 3)
      assert {:ok, "ef"} = Database.get_range("1/2/a.png", 4, 9)
      assert {:error, :not_found} = Database.get_range("1/2/missing.png", 0, 1)
    end
  end

  # Storage.presence/1 on the self-host adapter: same three answers as S3.
  describe "Storage.presence/1 on Database" do
    test "present, a 0-byte object present, absent missing" do
      assert :ok = Database.put("1/2/a.png", @binary)
      assert :ok = Database.put("1/2/empty.png", "")
      assert Engram.Storage.presence("1/2/a.png", Database) == :present
      assert Engram.Storage.presence("1/2/empty.png", Database) == :present
      assert Engram.Storage.presence("1/2/missing.png", Database) == :missing
    end

    # A read error (here: the connection's transaction is aborted) is
    # unknown, never missing.
    test "a read error is {:error, _}, not :missing" do
      assert :ok = Database.put("1/2/a.png", @binary)

      Engram.Repo.transaction(fn ->
        {:error, _} = Engram.Repo.query("SELECT 1/0")
        assert {:error, _} = Engram.Storage.presence("1/2/a.png", Database)
        Engram.Repo.rollback(:done)
      end)
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

  describe "delete_prefix/1 plan" do
    # storage_objects holds attachment bytes. Under a non-C collation the
    # default btree cannot serve a prefix match, so `LIKE 'x%'` read every
    # row. A text_pattern_ops index serves a byte-wise range, and the range
    # bounds are bind parameters, so even a generic plan can use it.
    test "the prefix delete is an index range scan" do
      {_, queries} = Engram.QueryRecorder.record(fn -> Database.delete_prefix("1/") end)
      me = self()
      [sql] = for %{sql: sql, pid: ^me} <- queries, sql =~ "DELETE FROM storage_objects", do: sql
      plan = Engram.QueryPlan.generic_plan(sql, analyze: ["storage_objects"])
      assert plan =~ "storage_objects_storage_key_pattern_index", plan
    end

    test "a prefix ending in a non-ASCII character still deletes exactly its keys" do
      assert :ok = Database.put("é/x.png", @binary)
      assert :ok = Database.put("éa/x.png", @binary)
      assert :ok = Database.put("ê/x.png", @binary)

      assert {:ok, 2} = Database.delete_prefix("é")
      assert {:ok, @binary} = Database.get("ê/x.png")
    end
  end

  describe "list_user_prefixes/0" do
    test "returns distinct uuid first segments" do
      u1 = "00000000-0000-0000-0000-000000000001"
      u2 = "00000000-0000-0000-0000-000000000002"
      assert :ok = Database.put("#{u1}/2/a.png", @binary)
      assert :ok = Database.put("#{u1}/3/b.png", @binary)
      assert :ok = Database.put("#{u2}/2/c.png", @binary)
      assert :ok = Database.put("notauuid/d.png", @binary)

      assert {:ok, ids} = Database.list_user_prefixes()
      assert Enum.sort(ids) == [u1, u2]
    end
  end
end
