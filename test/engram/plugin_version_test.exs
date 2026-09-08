defmodule Engram.PluginVersionTest do
  use ExUnit.Case, async: true

  alias Engram.PluginVersion

  # Pinned so these cases keep asserting the SHAPE of the comparison after the
  # floor moves. A test written against `PluginVersion.minimum()` asserts
  # nothing — it re-derives the answer from the value under test.
  @floor "1.28.0"

  test "minimum/0 is the floor these cases were written against" do
    assert PluginVersion.minimum() == @floor
  end

  describe "supported?/1 — absent or unreadable is ALLOWED" do
    test "nil (client predates the header) passes" do
      assert PluginVersion.supported?(nil)
    end

    test "empty string passes" do
      assert PluginVersion.supported?("")
    end

    test "unparseable garbage passes" do
      assert PluginVersion.supported?("not-a-version")
      assert PluginVersion.supported?("1.28")
      assert PluginVersion.supported?("v1.28.0")
    end

    test "an over-long header is not parsed and passes" do
      assert PluginVersion.supported?(String.duplicate("9", 5000))
    end

    test "a non-binary passes" do
      assert PluginVersion.supported?(:whatever)
      assert PluginVersion.supported?(1)
    end
  end

  describe "supported?/1 — ordering" do
    test "exactly the floor passes" do
      assert PluginVersion.supported?(@floor)
    end

    test "above the floor passes" do
      assert PluginVersion.supported?("1.28.1")
      assert PluginVersion.supported?("1.29.0")
      assert PluginVersion.supported?("2.0.0")
    end

    test "below the floor is refused" do
      refute PluginVersion.supported?("1.27.9")
      refute PluginVersion.supported?("1.0.0")
      refute PluginVersion.supported?("0.9.99")
    end

    test "compares numerically, not lexically" do
      # "1.9.0" > "1.28.0" as strings; the whole point of parsing.
      refute PluginVersion.supported?("1.9.0")
      assert PluginVersion.supported?("1.128.0")
    end

    test "a pre-release sorts below its own release" do
      refute PluginVersion.supported?("1.28.0-beta.1")
      assert PluginVersion.supported?("1.29.0-beta.1")
    end

    test "surrounding whitespace is tolerated" do
      refute PluginVersion.supported?("  1.27.0  ")
      assert PluginVersion.supported?("  1.29.0  ")
    end
  end

  test "update_url/0 points at the plugin's Obsidian pane" do
    assert PluginVersion.update_url() =~ "engram-vault-sync"
  end
end
