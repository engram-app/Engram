defmodule Engram.Logger.MetadataTest do
  use ExUnit.Case, async: true
  alias Engram.Logger.Metadata

  test "stamps category and computed loki_ship for an info business event" do
    meta = Metadata.with_category(:info, :billing, paddle_subscription_id: "sub_1")
    assert meta[:category] == :billing
    assert meta[:loki_ship] == true
    assert meta[:paddle_subscription_id] == "sub_1"
  end

  test "routine info is tagged loki_ship false" do
    meta = Metadata.with_category(:info, :http, status: 200)
    assert meta[:loki_ship] == false
  end

  test "error always loki_ship true" do
    meta = Metadata.with_category(:error, :http, status: 500)
    assert meta[:loki_ship] == true
  end

  test "raises on unknown category to catch typos at the call site" do
    assert_raise ArgumentError, fn -> Metadata.with_category(:info, :nonsense, []) end
  end
end
