defmodule Engram.Vector.QdrantFilterTest do
  use ExUnit.Case, async: true

  import Engram.QdrantFilterView

  alias Engram.Vector.Qdrant

  @base [user_id: "u1"]

  defp build(opts), do: legacy_view(Qdrant.build_tenant_filter(opts))

  test "type_hmac adds an equality match clause" do
    %{must: must} = build(@base ++ [type_hmac: "aGFzaA=="])
    assert %{key: "type_hmac", match: %{value: "aGFzaA=="}} in must
  end

  test "date bounds add range clauses (unix seconds)" do
    %{must: must} =
      build(@base ++ [fm_timestamp_gte: 1_750_000_000, fm_created_lte: 1_760_000_000])

    assert %{key: "fm_timestamp", range: %{gte: 1_750_000_000}} in must
    assert %{key: "fm_created", range: %{lte: 1_760_000_000}} in must
  end

  test "gte and lte on the same field merge into one range clause" do
    %{must: must} =
      build(@base ++ [fm_timestamp_gte: 1, fm_timestamp_lte: 2])

    assert %{key: "fm_timestamp", range: %{gte: 1, lte: 2}} in must
  end

  test "no OKF opts produces the unchanged base filter" do
    assert %{must: [%{key: "user_id", match: %{value: "u1"}}]} =
             build(@base)
  end

  test "a vault_id list emits an any-match clause" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    %{must: must} =
      build(user_id: "u1", vault_id: [a, b])

    assert %{key: "vault_id", match: %{any: [^a, ^b]}} =
             Enum.find(must, &(&1[:key] == "vault_id"))
  end

  test "a single vault_id binary still emits an exact-value clause" do
    a = Ecto.UUID.generate()

    %{must: must} = build(user_id: "u1", vault_id: a)

    assert %{key: "vault_id", match: %{value: ^a}} =
             Enum.find(must, &(&1[:key] == "vault_id"))
  end

  test "no vault_id emits no vault clause" do
    %{must: must} = build(user_id: "u1")
    refute Enum.any?(must, &(&1[:key] == "vault_id"))
  end

  describe "dual format (Task 15.4)" do
    alias Engram.ServiceConfig
    alias Engram.Vector.FilterId

    @uuid "6f9619ff-8b86-d011-b42d-00c04fc964ff"
    @hmac :crypto.strong_rand_bytes(32)

    test "user and vault match the dashed legacy id or the undashed v5 id" do
      assert Qdrant.match_filter(:user, @uuid) == %{
               should: [
                 %{key: "user_id", match: %{value: @uuid}},
                 %{key: "u", match: %{value: "6f9619ff8b86d011b42d00c04fc964ff"}}
               ]
             }

      assert %{
               should: [
                 %{key: "vault_id", match: %{any: [@uuid]}},
                 %{key: "v", match: %{any: [_]}}
               ]
             } =
               Qdrant.match_filter(:vault, [@uuid])
    end

    test "an HMAC filter matches base64 or the 128-bit id" do
      b64 = Base.encode64(@hmac)

      for {field, legacy, short} <- [
            {:path, "path_hmac", "p"},
            {:folder, "folder_hmac", "f"},
            {:type, "type_hmac", "y"}
          ] do
        assert Qdrant.match_filter(field, b64) == %{
                 should: [
                   %{key: legacy, match: %{value: b64}},
                   %{key: short, match: %{value: FilterId.from_hmac(@hmac)}}
                 ]
               }
      end

      assert %{should: [%{key: "tags_hmac"}, %{key: "g", match: %{any: [id]}}]} =
               Qdrant.match_filter(:tags, [b64])

      assert id == FilterId.from_hmac(@hmac)
    end

    test "a value with no v5 form keeps the legacy condition alone" do
      assert Qdrant.match_filter(:path, "c2hvcnQ=") == %{
               key: "path_hmac",
               match: %{value: "c2hvcnQ="}
             }
    end

    test "ranges match fm_timestamp or up, fm_created or cr" do
      %{must: [_user, ts]} = Qdrant.build_tenant_filter(user_id: "u1", fm_timestamp_gte: 5)

      assert ts == %{
               should: [%{key: "fm_timestamp", range: %{gte: 5}}, %{key: "up", range: %{gte: 5}}]
             }

      assert Qdrant.range_filter(:fm_created, %{lte: 9}) ==
               %{should: [%{key: "fm_created", range: %{lte: 9}}, %{key: "cr", range: %{lte: 9}}]}
    end

    test "with legacy fields off only the v5 condition is sent" do
      ServiceConfig.put_override(:legacy_filter_fields, false)

      assert Qdrant.match_filter(:user, @uuid) == %{
               key: "u",
               match: %{value: FilterId.uuid(@uuid)}
             }

      assert Qdrant.range_filter(:fm_timestamp, %{gte: 1}) == %{key: "up", range: %{gte: 1}}
    end

    test "the tenant condition stays inside must, so it is still an AND" do
      %{must: must} = Qdrant.build_tenant_filter(user_id: @uuid, vault_id: @uuid)
      assert [%{should: [_, _]}, %{should: [_, _]}] = must
    end

    test "nested long-tail filters" do
      assert Qdrant.attr_filter("k1", "v1") == %{
               nested: %{
                 key: "at",
                 filter: %{
                   must: [%{key: "k", match: %{value: "k1"}}, %{key: "v", match: %{value: "v1"}}]
                 }
               }
             }

      assert %{nested: %{key: "nm", filter: %{must: [_, %{key: "n", range: %{gte: 4}}]}}} =
               Qdrant.num_range("k", gte: 4)

      assert %{nested: %{key: "dt", filter: %{must: [_, %{key: "t", range: %{lt: 9}}]}}} =
               Qdrant.date_range("k", lt: 9)
    end
  end
end
