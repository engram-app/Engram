defmodule Engram.CacheTest do
  use ExUnit.Case, async: true
  alias Engram.Cache

  test "backend/0 always returns :ets" do
    assert Cache.backend() == :ets
  end
end
