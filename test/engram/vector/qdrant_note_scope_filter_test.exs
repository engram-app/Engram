defmodule Engram.Vector.QdrantNoteScopeFilterTest do
  @moduledoc """
  The note-id reader (immutable chunk index, Engram#2263): Postgres resolves
  a search's filters to note ids, and the Qdrant filter is the tenant (`u`,
  `v`) plus the note ids on `n`, in `match.any` blocks of `Qdrant.max_ids/0`.
  R3a: no payload condition rides along. A point without `n` (not yet
  backfilled) is let through by `is_empty(n)` and post-filtered in Postgres
  (`Engram.Search`), so it stays findable at every moment of the backfill.
  """
  use ExUnit.Case, async: true

  alias Engram.Vector.FilterId
  alias Engram.Vector.Qdrant

  @user "11111111-1111-1111-1111-111111111111"
  @vault "22222222-2222-2222-2222-222222222222"
  @base [user_id: @user, vault_id: @vault]

  defp ids(n), do: for(_ <- 1..n//1, do: Ecto.UUID.generate())

  defp filter(scope), do: Qdrant.build_tenant_filter(@base ++ [note_scope: scope])

  @empty_n %{is_empty: %{key: "n"}}

  # The one clause beside the tenant.
  defp scope_clause(%{must: must} = filter) do
    refute Map.has_key?(filter, :must_not)
    assert [clause] = must -- Qdrant.build_tenant_filter(@base).must
    clause
  end

  defp block_sizes(blocks), do: Enum.map(blocks, &length(&1.match.any))

  # Every key the filter tree names.
  defp keys(%{} = m), do: Enum.flat_map(m, fn {k, v} -> key(k, v) ++ keys(v) end)
  defp keys(l) when is_list(l), do: Enum.flat_map(l, &keys/1)
  defp keys(_), do: []
  defp key(:key, v), do: [v]
  defp key(_, _), do: []

  describe "{:ids, ids}" do
    test "the tenant, then ONE should: the n blocks or no n" do
      ids = ids(5_000)
      %{should: should} = scope_clause(filter({:ids, ids}))

      assert {blocks, [@empty_n]} = Enum.split(should, -1)
      assert block_sizes(blocks) == [2048, 2048, 904]
      assert Enum.all?(blocks, &(&1.key == "n"))
      assert Enum.flat_map(blocks, & &1.match.any) == Enum.map(ids, &FilterId.uuid/1)
    end

    test "names no payload key but u, v and n anywhere in the tree" do
      filter = filter({:ids, ids(3)})
      assert filter |> keys() |> Enum.uniq() |> Enum.sort() == ~w(n u user_id v vault_id)
    end

    test "exactly max_ids is one block, one more is two" do
      %{should: s1} = scope_clause(filter({:ids, ids(2048)}))
      %{should: s2} = scope_clause(filter({:ids, ids(2049)}))
      assert block_sizes(Enum.drop(s1, -1)) == [2048]
      assert block_sizes(Enum.drop(s2, -1)) == [2048, 1]
    end

    test "max_note_ids (5 blocks) is accepted, one more is refused" do
      assert Qdrant.max_note_ids() == 5 * Qdrant.max_ids()
      %{should: should} = scope_clause(filter({:ids, ids(Qdrant.max_note_ids())}))
      assert length(should) == 6
      assert_raise ArgumentError, fn -> filter({:ids, ids(Qdrant.max_note_ids() + 1)}) end
    end

    test "an empty id list matches only points without n (post-filtered away)" do
      assert scope_clause(filter({:ids, []})) == %{
               should: [%{key: "n", match: %{any: []}}, @empty_n]
             }
    end
  end

  describe "{:exclude, ids}" do
    test "the tenant, then n outside the ids (a point without n passes, post-filtered)" do
      ids = ids(2049)
      %{must_not: blocks} = scope_clause(filter({:exclude, ids}))
      assert block_sizes(blocks) == [2048, 1]
      assert Enum.all?(blocks, &(&1.key == "n"))
    end

    test "an empty complement (every note matches) is the tenant filter alone" do
      assert filter({:exclude, []}) == Qdrant.build_tenant_filter(@base)
    end

    test "over max_note_ids is refused" do
      assert_raise ArgumentError, fn -> filter({:exclude, ids(Qdrant.max_note_ids() + 1)}) end
    end
  end

  # What the filter MATCHES, point by point (a minimal Qdrant evaluator).
  describe "evaluated" do
    @other_user "33333333-3333-3333-3333-333333333333"

    defp point(note, user \\ @user) do
      %{"u" => FilterId.uuid(user), "v" => FilterId.uuid(@vault)}
      |> then(&if note, do: Map.put(&1, "n", FilterId.uuid(note)), else: &1)
    end

    defp matches?(filter, p), do: eval(Jason.decode!(Jason.encode!(filter)), p)

    defp eval(%{} = f, p) when not is_map_key(f, "key") and not is_map_key(f, "is_empty") do
      Enum.all?(f["must"] || [], &eval(&1, p)) and
        (f["should"] in [nil, []] or Enum.any?(f["should"], &eval(&1, p))) and
        not Enum.any?(f["must_not"] || [], &eval(&1, p))
    end

    defp eval(%{"is_empty" => %{"key" => k}}, p), do: p[k] in [nil, []]

    defp eval(%{"key" => k, "match" => %{"value" => v}}, p),
      do: p[k] == v or (is_list(p[k]) and v in p[k])

    defp eval(%{"key" => k, "match" => %{"any" => vs}}, p),
      do: Enum.any?(List.wrap(p[k]), &(&1 in vs))

    test "include: a point with n by its id; a point without n passes" do
      [hit, miss] = ids(2)
      filter = filter({:ids, [hit]})

      assert matches?(filter, point(hit))
      refute matches?(filter, point(miss))
      assert matches?(filter, point(nil))
    end

    test "exclude: a point with n unless excluded; a point without n passes" do
      [excluded, kept] = ids(2)
      filter = filter({:exclude, [excluded]})

      assert matches?(filter, point(kept))
      refute matches?(filter, point(excluded))
      assert matches?(filter, point(nil))
    end

    test "the tenant holds for every point" do
      [hit] = ids(1)

      for scope <- [{:ids, [hit]}, {:exclude, [Ecto.UUID.generate()]}] do
        filter = filter(scope)
        refute matches?(filter, point(hit, @other_user))
        refute matches?(filter, point(nil, @other_user))
      end
    end
  end

  test "recommend adds its source points beside the note scope" do
    note = Ecto.UUID.generate()
    source = Ecto.UUID.generate()
    body = Qdrant.recommend_body([source], @base ++ [note_scope: {:exclude, [note]}])

    assert body.filter.must_not == [%{has_id: [source]}]

    n = FilterId.uuid(note)
    assert %{must_not: [%{key: "n", match: %{any: [^n]}}]} = List.last(body.filter.must)
  end

  test "no :note_scope is the tenant filter alone" do
    refute inspect(Qdrant.build_tenant_filter(@base)) =~ ~s(key: "n")
  end
end
