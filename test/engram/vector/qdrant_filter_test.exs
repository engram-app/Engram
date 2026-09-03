defmodule Engram.Vector.QdrantFilterTest do
  use ExUnit.Case, async: true

  alias Engram.Vector.Qdrant

  @base [user_id: "u1"]

  test "type_hmac adds an equality match clause" do
    %{must: must} = Qdrant.build_tenant_filter(@base ++ [type_hmac: "aGFzaA=="])
    assert %{key: "type_hmac", match: %{value: "aGFzaA=="}} in must
  end

  test "date bounds add range clauses (unix seconds)" do
    %{must: must} =
      Qdrant.build_tenant_filter(
        @base ++ [fm_timestamp_gte: 1_750_000_000, fm_created_lte: 1_760_000_000]
      )

    assert %{key: "fm_timestamp", range: %{gte: 1_750_000_000}} in must
    assert %{key: "fm_created", range: %{lte: 1_760_000_000}} in must
  end

  test "gte and lte on the same field merge into one range clause" do
    %{must: must} =
      Qdrant.build_tenant_filter(@base ++ [fm_timestamp_gte: 1, fm_timestamp_lte: 2])

    assert %{key: "fm_timestamp", range: %{gte: 1, lte: 2}} in must
  end

  test "no OKF opts produces the unchanged base filter" do
    assert %{must: [%{key: "user_id", match: %{value: "u1"}}]} =
             Qdrant.build_tenant_filter(@base)
  end

  test "a vault_id list emits an any-match clause" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    %{must: must} =
      Qdrant.build_tenant_filter(user_id: "u1", vault_id: [a, b])

    assert %{key: "vault_id", match: %{any: [^a, ^b]}} =
             Enum.find(must, &(&1[:key] == "vault_id"))
  end

  test "a single vault_id binary still emits an exact-value clause" do
    a = Ecto.UUID.generate()

    %{must: must} = Qdrant.build_tenant_filter(user_id: "u1", vault_id: a)

    assert %{key: "vault_id", match: %{value: ^a}} =
             Enum.find(must, &(&1[:key] == "vault_id"))
  end

  test "no vault_id emits no vault clause" do
    %{must: must} = Qdrant.build_tenant_filter(user_id: "u1")
    refute Enum.any?(must, &(&1[:key] == "vault_id"))
  end
end
