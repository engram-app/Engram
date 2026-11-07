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

  defp filter(scope, extra \\ []),
    do: Qdrant.build_tenant_filter(@base ++ extra ++ [note_scope: scope])

  @empty_n %{is_empty: %{key: "n"}}

  # The one per-point branch beside the tenant: `should [n path, fallback]`.
  defp branches(%{must: must}) do
    tenant = Qdrant.build_tenant_filter(@base).must
    assert [%{should: [n_path, fallback]}] = must -- tenant
    {n_path, fallback}
  end

  defp n_blocks(%{should: blocks}), do: blocks

  defp block_sizes(blocks), do: Enum.map(blocks, &length(&1.match.any))

  describe "{:ids, ids}" do
    test "the tenant, then ONE should: the n blocks, or no n and today's conditions" do
      ids = ids(5_000)
      folder = Base.encode64(:crypto.strong_rand_bytes(32))
      filter = filter({:ids, ids}, folder_hmac: folder)
      {n_path, fallback} = branches(filter)

      refute Map.has_key?(filter, :must_not)
      blocks = n_blocks(n_path)
      assert block_sizes(blocks) == [2048, 2048, 904]
      assert Enum.all?(blocks, &(&1.key == "n"))
      assert Enum.flat_map(blocks, & &1.match.any) == Enum.map(ids, &FilterId.uuid/1)

      today = Qdrant.build_tenant_filter(@base ++ [folder_hmac: folder]).must
      assert fallback == %{must: [@empty_n | today -- Qdrant.build_tenant_filter(@base).must]}
    end

    test "exactly max_ids is one block, one more is two" do
      assert filter({:ids, ids(2048)}) |> branches() |> elem(0) |> n_blocks() |> block_sizes() ==
               [2048]

      assert filter({:ids, ids(2049)}) |> branches() |> elem(0) |> n_blocks() |> block_sizes() ==
               [2048, 1]
    end

    test "max_note_ids (5 blocks) is accepted, one more is refused" do
      assert Qdrant.max_note_ids() == 5 * Qdrant.max_ids()

      assert filter({:ids, ids(Qdrant.max_note_ids())})
             |> branches()
             |> elem(0)
             |> n_blocks()
             |> length() == 5

      assert_raise ArgumentError, fn -> filter({:ids, ids(Qdrant.max_note_ids() + 1)}) end
    end

    test "an empty id list matches nothing (fail closed, never an empty should)" do
      tenant = Qdrant.build_tenant_filter(@base).must
      assert filter({:ids, []}).must -- tenant == [%{should: [%{key: "n", match: %{any: []}}]}]
    end
  end

  describe "{:exclude, ids}" do
    test "the tenant, then ONE should: n outside the ids, or no n and today's conditions" do
      ids = ids(2049)
      {n_path, fallback} = branches(filter({:exclude, ids}, type_hmac: "dHlwZQ=="))

      assert [@empty_n | blocks] = n_path.must_not
      assert block_sizes(blocks) == [2048, 1]
      assert [@empty_n | _today] = fallback.must
    end

    test "an empty complement (every note matches) is the tenant filter alone" do
      assert filter({:exclude, []}) == Qdrant.build_tenant_filter(@base)
    end

    test "over max_note_ids is refused" do
      assert_raise ArgumentError, fn -> filter({:exclude, ids(Qdrant.max_note_ids() + 1)}) end
    end
  end

  # What the filter MATCHES, point by point (a minimal Qdrant evaluator):
  # a point with `n` is judged by its note id, one without by today's payload
  # conditions, and the tenant holds in both branches.
  describe "per-point fallback, evaluated" do
    @other_user "33333333-3333-3333-3333-333333333333"

    defp point(note, extra) do
      Map.merge(%{"u" => FilterId.uuid(@user), "v" => FilterId.uuid(@vault)}, extra)
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

    # With legacy filter fields on, each condition is `should [legacy, v5]`;
    # these points carry only the v5 keys, so the v5 member decides.
    setup do
      [folder, other] = for _ <- 1..2, do: :crypto.strong_rand_bytes(32)
      f = Engram.Vector.PayloadKeys.short(:folder_id)

      %{
        folder: Base.encode64(folder),
        in_folder: %{f => FilterId.from_hmac(folder)},
        out: %{f => FilterId.from_hmac(other)}
      }
    end

    test "include: a point with n by its id; without n by today's folder condition", ctx do
      [hit, miss] = ids(2)
      filter = filter({:ids, [hit]}, folder_hmac: ctx.folder)

      assert matches?(filter, point(hit, ctx.out))
      refute matches?(filter, point(miss, ctx.in_folder))
      assert matches?(filter, point(nil, ctx.in_folder))
      refute matches?(filter, point(nil, ctx.out))
    end

    test "exclude: a point with n unless excluded; without n by today's folder condition", ctx do
      [excluded, kept] = ids(2)
      filter = filter({:exclude, [excluded]}, folder_hmac: ctx.folder)

      assert matches?(filter, point(kept, ctx.out))
      refute matches?(filter, point(excluded, ctx.in_folder))
      assert matches?(filter, point(nil, ctx.in_folder))
      refute matches?(filter, point(nil, ctx.out))
    end

    test "the tenant holds in both branches", ctx do
      [hit] = ids(1)

      for scope <- [{:ids, [hit]}, {:exclude, [Ecto.UUID.generate()]}] do
        filter = filter(scope, folder_hmac: ctx.folder)
        foreign = &Map.put(&1, "u", FilterId.uuid(@other_user))
        refute matches?(filter, foreign.(point(hit, ctx.in_folder)))
        refute matches?(filter, foreign.(point(nil, ctx.in_folder)))
      end
    end
  end

  test "recommend adds its source points beside the note scope" do
    note = Ecto.UUID.generate()
    source = Ecto.UUID.generate()
    body = Qdrant.recommend_body([source], @base ++ [note_scope: {:exclude, [note]}])

    assert body.filter.must_not == [%{has_id: [source]}]
    {n_path, _fallback} = branches(body.filter)
    assert n_path.must_not == [@empty_n, %{key: "n", match: %{any: [FilterId.uuid(note)]}}]
  end

  test "no :note_scope leaves the filter exactly as before" do
    opts = @base ++ [folder_hmac: Base.encode64(:crypto.strong_rand_bytes(32))]
    refute inspect(Qdrant.build_tenant_filter(opts)) =~ ~s(key: "n")
  end
end
