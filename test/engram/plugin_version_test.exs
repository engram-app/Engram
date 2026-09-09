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

    # Over-length fails OPEN and SILENTLY, so a version scheme that outgrows
    # the bound disables the floor with no signal. These pin where the cliff
    # is and prove the real formats clear it with room to spare.
    test "the length cliff is at 32 bytes" do
      # 31 bytes: parsed, and refused.
      refute PluginVersion.supported?("1.0.0" <> String.duplicate(" ", 26))
      # 33 bytes: not parsed, and allowed.
      assert PluginVersion.supported?("1.0.0" <> String.duplicate(" ", 28))
    end

    test "the longest version this repo can emit fits under the cliff" do
      longest = "1.28.1-pr.512.g876f2c2"
      assert byte_size(longest) <= 32
      # Not merely "allowed" — allowed BECAUSE it parsed, not because it was
      # too long to read. Below-floor sibling must therefore be refused.
      refute PluginVersion.supported?("1.27.1-pr.512.g876f2c2")
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

    # A pre-release of the floor CONTAINS the floor's code. Semver says
    # 1.28.0-beta.1 < 1.28.0; applying that here would refuse every beta
    # tester and PR reviewer running a build of the very release that fixes
    # the thing the floor exists for, and send them to a plugin pane with
    # nothing newer to install.
    test "a pre-release of the floor is ALLOWED, not ordered below it" do
      assert PluginVersion.supported?("#{@floor}-beta.1")
      assert PluginVersion.supported?("#{@floor}-rc.1")
    end

    # The exact shapes engram-obsidian-sync/scripts/release-version.mjs emits
    # and pr-build.yml stamps into manifest.json. Their absence is what let
    # the semver-ordering bug through the first time.
    test "the repo's real pre-release formats are allowed" do
      assert PluginVersion.supported?("1.28.0-beta.3")
      assert PluginVersion.supported?("1.28.0-pr.512.g876f2c2")
      assert PluginVersion.supported?("1.29.0-pr.1.gabc1234")
    end

    test "a pre-release of a version BELOW the floor is still refused" do
      refute PluginVersion.supported?("1.27.0-beta.1")
      refute PluginVersion.supported?("1.27.9-pr.512.g876f2c2")
    end

    test "build metadata is ignored" do
      assert PluginVersion.supported?("#{@floor}+build.7")
      refute PluginVersion.supported?("1.27.0+build.7")
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
