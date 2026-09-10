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
    test "the length cliff is at exactly 32 bytes" do
      # 32 bytes: parsed, and refused. Testing only 31 and 33 leaves the bound
      # free to drift by one without any test noticing.
      refute PluginVersion.supported?("1.0.0" <> String.duplicate(" ", 27))
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

    # THE case, and it must stay refused. A PR build's version is
    # `nextPatch(last_release)` — read from the branch's COMMITTED manifest, so
    # every open PR of any content claims the same triple. Allowing
    # `X.Y.Z-anything` to satisfy a floor of `X.Y.Z` would wave through a
    # BRAT-frozen build of a stale pre-fix branch, which is the exact
    # population the gate exists for. See the moduledoc.
    test "a pre-release of the floor is REFUSED" do
      refute PluginVersion.supported?("#{@floor}-beta.1")
      refute PluginVersion.supported?("#{@floor}-rc.1")
      refute PluginVersion.supported?("#{@floor}-pr.512.g876f2c2")
    end

    # The shapes release-version.mjs ACTUALLY emits. `nextPatch` increments
    # PATCH, so with stable 1.28.0 a preview is 1.28.1-*, never 1.28.0-*. An
    # earlier version of this table asserted 1.28.0-* — strings the generator
    # cannot produce — and so tested nothing about the real hazard.
    test "the repo's real preview formats sort above a released floor" do
      assert PluginVersion.supported?("1.28.1-beta.3")
      assert PluginVersion.supported?("1.28.1-pr.512.g876f2c2")
    end

    test "a pre-release of a version BELOW the floor is refused" do
      refute PluginVersion.supported?("1.27.0-beta.1")
      refute PluginVersion.supported?("1.27.9-pr.512.g876f2c2")
    end

    test "a full release above the floor is allowed" do
      assert PluginVersion.supported?("1.28.1")
      assert PluginVersion.supported?("1.29.0")
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
