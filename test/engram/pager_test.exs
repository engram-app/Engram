defmodule Engram.PagerTest do
  use ExUnit.Case, async: true

  alias Engram.{Batch, Pager}

  @a %{id: "11111111-1111-1111-1111-111111111111"}
  @v %{id: "22222222-2222-2222-2222-222222222222"}

  describe "limit/1" do
    test "defaults, clamps to the one hard max, and tolerates junk" do
      assert Pager.limit(nil) == Batch.page_default()
      assert Pager.limit(nil, Batch.rest_page_default()) == 500
      assert Pager.limit("abc", 500) == 500
      assert Pager.limit("0") == 1
      assert Pager.limit("-1") == 1
      assert Pager.limit("abc") == Batch.page_default()
      assert Pager.limit("7") == 7
      assert Pager.limit(0) == 1
      assert Pager.limit(-5) == 1
      assert Pager.limit(1_000_000) == Batch.page_max()
      assert Pager.limit("1000000") == Batch.page_max()
    end
  end

  test "opts/1 reads cursor and limit from request params" do
    assert Pager.opts(%{"cursor" => "c", "limit" => "5", "x" => 1}) == [cursor: "c", limit: 5]
    assert Pager.opts(%{}) == [cursor: nil, limit: 200]
    assert Pager.rest_opts(%{}) == [cursor: nil, limit: 500]
    assert Pager.rest_opts(%{"limit" => "900"}) == [cursor: nil, limit: 900]
    assert Pager.page_meta("c") == %{next_cursor: "c", truncated: true}
    assert Pager.page_meta(nil) == %{next_cursor: nil, truncated: false}
  end

  describe "cursor" do
    test "round-trips, and is a url-safe token" do
      scope = Pager.scope(:folder_notes, @a, @v)
      cursor = Pager.encode(scope, "3f2a0000-0000-0000-0000-000000000001")

      assert {:ok, "3f2a0000-0000-0000-0000-000000000001"} = Pager.decode(scope, cursor)
      assert cursor =~ ~r/\A[A-Za-z0-9_.\-]+\z/
    end

    test "nil and empty mean the first page" do
      scope = Pager.scope(:folder_notes, @a, @v)
      assert {:ok, nil} = Pager.decode(scope, nil)
      assert {:ok, nil} = Pager.decode(scope, "")
    end

    test "a tampered, truncated, oversized or non-string cursor is refused" do
      scope = Pager.scope(:folder_notes, @a, @v)
      cursor = Pager.encode(scope, "k")

      flipped = binary_part(cursor, 0, byte_size(cursor) - 2) <> "xx"
      assert {:error, :invalid_cursor} = Pager.decode(scope, flipped)
      assert {:error, :invalid_cursor} = Pager.decode(scope, binary_part(cursor, 0, 10))
      assert {:error, :invalid_cursor} = Pager.decode(scope, String.duplicate("a", 600))
      assert {:error, :invalid_cursor} = Pager.decode(scope, 12)
    end

    test "a cursor minted for another user, vault or list is refused" do
      cursor = Pager.encode(Pager.scope(:folder_notes, @a, @v), "k")

      assert {:error, :invalid_cursor} =
               Pager.decode(Pager.scope(:folder_notes, %{id: "other"}, @v), cursor)

      assert {:error, :invalid_cursor} =
               Pager.decode(Pager.scope(:folder_notes, @a, %{id: "other"}), cursor)

      assert {:error, :invalid_cursor} = Pager.decode(Pager.scope(:attachments, @a, @v), cursor)
    end
  end

  describe "paginate/4" do
    test "an extra row means more: the page is trimmed and the cursor is its last key" do
      scope = Pager.scope(:t, @a, @v)
      {page, cursor} = Pager.paginate([1, 2, 3], 2, scope, & &1)

      assert page == [1, 2]
      assert {:ok, 2} = Pager.decode(scope, cursor)
    end

    test "no extra row means the last page" do
      assert {[1, 2], nil} = Pager.paginate([1, 2], 2, Pager.scope(:t, @a, @v), & &1)
      assert {[], nil} = Pager.paginate([], 2, Pager.scope(:t, @a, @v), & &1)
    end
  end
end
