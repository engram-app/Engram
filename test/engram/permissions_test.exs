defmodule Engram.PermissionsTest do
  use Engram.DataCase, async: true

  alias Engram.Permissions

  defp conn_with(assigns), do: %Plug.Conn{assigns: assigns}

  test "no credential restrictions means every vault" do
    assert Permissions.vault_scope(conn_with(%{})) == :all
  end

  test "an OAuth grant narrows to its vault set" do
    scope = Permissions.vault_scope(conn_with(%{oauth_scope_vault_ids: ["a", "b"]}))
    assert Permissions.allows?(scope, %{id: "a"})
    refute Permissions.allows?(scope, %{id: "c"})
  end

  test "restrictions INTERSECT, never union" do
    # An API key permitted to {a, b} presenting an OAuth grant for {b, c}
    # may reach only b — the overlap. Taking either side alone would widen
    # the credential past what one of its two restrictions allows.
    scope =
      Permissions.intersect_for_test(
        MapSet.new(["a", "b"]),
        MapSet.new(["b", "c"])
      )

    refute Permissions.allows?(scope, %{id: "a"})
    assert Permissions.allows?(scope, %{id: "b"})
    refute Permissions.allows?(scope, %{id: "c"})
  end

  test "filter/2 keeps only permitted vaults, :all keeps all" do
    vaults = [%{id: "a"}, %{id: "b"}]
    assert Permissions.filter(:all, vaults) == vaults
    assert Permissions.filter(MapSet.new(["b"]), vaults) == [%{id: "b"}]
  end

  test "check/2 mirrors allows?/2" do
    assert Permissions.check(:all, %{id: "a"}) == :ok
    assert Permissions.check(MapSet.new(["b"]), %{id: "a"}) == :forbidden
  end
end
