defmodule Engram.Logger.DebugToggleTest do
  use ExUnit.Case, async: false
  alias Engram.Logger.DebugToggle

  test "enable/1 sets module level to debug, reset/1 clears it" do
    on_exit(fn -> :logger.unset_module_level(Engram.Search) end)

    assert DebugToggle.enable(Engram.Search) == :ok
    assert :logger.get_module_level(Engram.Search) == [{Engram.Search, :debug}]
    assert DebugToggle.reset(Engram.Search) == :ok
    assert :logger.get_module_level(Engram.Search) == []
  end
end
