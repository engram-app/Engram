defmodule Engram.Vector.QdrantNoteScopeFilterTest do
  @moduledoc """
  The note-id reader (immutable chunk index R1, Engram#2263): Postgres
  resolves a search's filters to note ids, and the Qdrant filter is the
  tenant (`u`, `v`) plus the note ids on `n`, in `match.any` blocks of
  `Qdrant.max_ids/0` (the strict `condition_max_size` bound).
  """
  use ExUnit.Case, async: true

  alias Engram.Vector.FilterId
  alias Engram.Vector.Qdrant

  @user "11111111-1111-1111-1111-111111111111"
  @vault "22222222-2222-2222-2222-222222222222"
  @base [user_id: @user, vault_id: @vault]

  defp ids(n), do: for(_ <- 1..n//1, do: Ecto.UUID.generate())

  defp filter(scope), do: Qdrant.build_tenant_filter(@base ++ [note_scope: scope])

  # The `n` blocks of an `{:ids, _}` filter: the one nested `should` in `must`.
  defp should_blocks(%{must: must}) do
    [%{should: blocks}] = for %{should: [%{key: "n"} | _]} = c <- must, do: c
    blocks
  end

  defp block_sizes(blocks), do: Enum.map(blocks, &length(&1.match.any))

  describe "{:ids, ids}" do
    test "the tenant conditions plus ONE nested should of n blocks" do
      ids = ids(5_000)
      filter = filter({:ids, ids})
      tenant = Qdrant.build_tenant_filter(@base)

      assert filter.must -- tenant.must == [%{should: should_blocks(filter)}]
      refute Map.has_key?(filter, :must_not)

      blocks = should_blocks(filter)
      assert block_sizes(blocks) == [2048, 2048, 904]
      assert Enum.all?(blocks, &(&1.key == "n"))
      assert Enum.flat_map(blocks, & &1.match.any) == Enum.map(ids, &FilterId.uuid/1)
    end

    test "exactly max_ids is one block, one more is two" do
      assert filter({:ids, ids(2048)}) |> should_blocks() |> block_sizes() == [2048]
      assert filter({:ids, ids(2049)}) |> should_blocks() |> block_sizes() == [2048, 1]
    end

    test "max_note_ids (5 blocks) is accepted, one more is refused" do
      assert Qdrant.max_note_ids() == 5 * Qdrant.max_ids()

      assert filter({:ids, ids(Qdrant.max_note_ids())}) |> should_blocks() |> length() == 5

      assert_raise ArgumentError, fn -> filter({:ids, ids(Qdrant.max_note_ids() + 1)}) end
    end

    test "an empty id list matches nothing (fail closed, never an empty should)" do
      assert should_blocks(filter({:ids, []})) == [%{key: "n", match: %{any: []}}]
    end
  end

  describe "{:exclude, ids}" do
    test "the tenant must, and the n blocks under must_not" do
      ids = ids(2049)
      filter = filter({:exclude, ids})

      assert filter.must == Qdrant.build_tenant_filter(@base).must
      assert block_sizes(filter.must_not) == [2048, 1]
      assert Enum.all?(filter.must_not, &(&1.key == "n"))
    end

    test "an empty complement (every note matches) is the tenant filter alone" do
      assert filter({:exclude, []}) == Qdrant.build_tenant_filter(@base)
    end

    test "over max_note_ids is refused" do
      assert_raise ArgumentError, fn -> filter({:exclude, ids(Qdrant.max_note_ids() + 1)}) end
    end
  end

  test "recommend keeps the note scope's must_not beside its own source points" do
    note = Ecto.UUID.generate()
    source = Ecto.UUID.generate()
    body = Qdrant.recommend_body([source], @base ++ [note_scope: {:exclude, [note]}])

    assert body.filter.must_not == [
             %{key: "n", match: %{any: [FilterId.uuid(note)]}},
             %{has_id: [source]}
           ]
  end

  test "no :note_scope leaves the filter exactly as before" do
    opts = @base ++ [folder_hmac: Base.encode64(:crypto.strong_rand_bytes(32))]
    refute inspect(Qdrant.build_tenant_filter(opts)) =~ ~s(key: "n")
  end
end
