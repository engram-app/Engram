defmodule EngramWeb.OriginProbeSocketTest do
  use ExUnit.Case, async: true

  test "connect/3 always returns {:ok, socket} with no params" do
    assert {:ok, %Phoenix.Socket{}} =
             EngramWeb.OriginProbeSocket.connect(%{}, %Phoenix.Socket{}, %{})
  end

  test "connect/3 ignores any params" do
    assert {:ok, %Phoenix.Socket{}} =
             EngramWeb.OriginProbeSocket.connect(
               %{"anything" => "anyvalue", "token" => "ignored"},
               %Phoenix.Socket{},
               %{}
             )
  end

  test "id/1 returns nil (no identity, no broadcast routing)" do
    assert is_nil(EngramWeb.OriginProbeSocket.id(%Phoenix.Socket{}))
  end
end
