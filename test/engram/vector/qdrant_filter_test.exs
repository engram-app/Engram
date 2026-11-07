defmodule Engram.Vector.QdrantFilterTest do
  use ExUnit.Case, async: true

  import Engram.QdrantFilterView

  alias Engram.Vector.Qdrant

  @base [user_id: "u1"]

  defp build(opts), do: legacy_view(Qdrant.build_tenant_filter(opts))

  # R3a: the payload filters left the points. Folder, tag, type, date and
  # field filters resolve in Postgres to note ids, so the Qdrant filter names
  # no payload key but the identity ones, whatever opts a caller still sends.
  test "payload filter opts and a note scope name no key but u, v and n" do
    filter =
      Qdrant.build_tenant_filter(
        user_id: "6f9619ff-8b86-d011-b42d-00c04fc964ff",
        vault_id: "6f9619ff-8b86-d011-b42d-00c04fc964ff",
        type_hmac: Base.encode64(:crypto.strong_rand_bytes(32)),
        tags_hmac: [Base.encode64(:crypto.strong_rand_bytes(32))],
        folder_hmac: Base.encode64(:crypto.strong_rand_bytes(32)),
        fm_timestamp_gte: 1,
        fm_created_lte: 2,
        attr_filters: [%{nested: %{key: "fa", filter: %{must: []}}}],
        note_scope: {:ids, [Ecto.UUID.generate()]}
      )

    keys = filter |> keys() |> Enum.uniq() |> Enum.sort()
    assert keys == ~w(n u user_id v vault_id)
  end

  defp keys(%{} = m), do: Enum.flat_map(m, fn {k, v} -> key(k, v) ++ keys(v) end)
  defp keys(l) when is_list(l), do: Enum.flat_map(l, &keys/1)
  defp keys(_), do: []
  defp key(:key, v), do: [v]
  defp key(_, _), do: []

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

  # Both formats while `:legacy_filter_fields` is on (the default): a
  # collection may still hold v3/v4 points. v5-only once it is off.
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

      assert Qdrant.match_filter(:path, b64) == %{
               should: [
                 %{key: "path_hmac", match: %{value: b64}},
                 %{key: "p", match: %{value: FilterId.from_hmac(@hmac)}}
               ]
             }
    end

    test "a value with no v5 form keeps the legacy condition alone" do
      assert Qdrant.match_filter(:path, "c2hvcnQ=") == %{
               key: "path_hmac",
               match: %{value: "c2hvcnQ="}
             }
    end

    test "with legacy fields off only the v5 condition is sent" do
      ServiceConfig.put_override(:legacy_filter_fields, false)

      assert Qdrant.match_filter(:user, @uuid) == %{
               key: "u",
               match: %{value: FilterId.uuid(@uuid)}
             }
    end

    test "the tenant condition stays inside must, so it is still an AND" do
      %{must: must} = Qdrant.build_tenant_filter(user_id: @uuid, vault_id: @uuid)
      assert [%{should: [_, _]}, %{should: [_, _]}] = must
    end
  end
end
