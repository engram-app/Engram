defmodule Engram.Logger.CategoryTest do
  use ExUnit.Case, async: true
  alias Engram.Logger.Category

  test "all/0 returns the known categories" do
    assert Category.all() == [
             :http,
             :sync,
             :search,
             :auth,
             :billing,
             :crypto,
             :lifecycle,
             :oban,
             :boot,
             :data
           ]
  end

  test "valid?/1 accepts known categories and rejects others" do
    assert Category.valid?(:billing)
    assert Category.valid?(:data)
    refute Category.valid?(:nonsense)
  end

  test "data warnings ship to Loki (data-integrity is always kept)" do
    assert Category.loki_ship?(:warning, :data)
  end

  test "warning and error always ship to Loki regardless of category" do
    assert Category.loki_ship?(:error, :http)
    assert Category.loki_ship?(:warning, :sync)
  end

  test "info ships to Loki only for high-value categories" do
    assert Category.loki_ship?(:info, :billing)
    assert Category.loki_ship?(:info, :crypto)
    assert Category.loki_ship?(:info, :lifecycle)
    assert Category.loki_ship?(:info, :oban)
    assert Category.loki_ship?(:info, :boot)
  end

  test "routine info categories do NOT ship to Loki" do
    refute Category.loki_ship?(:info, :http)
    refute Category.loki_ship?(:info, :sync)
    refute Category.loki_ship?(:info, :search)
    refute Category.loki_ship?(:info, :auth)
  end

  test "debug never ships to Loki" do
    refute Category.loki_ship?(:debug, :billing)
  end
end
