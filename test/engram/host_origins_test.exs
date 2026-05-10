defmodule Engram.HostOriginsTest do
  use ExUnit.Case, async: true

  alias Engram.HostOrigins

  describe "parse/1" do
    test "returns nil for nil or empty" do
      assert HostOrigins.parse(nil) == nil
      assert HostOrigins.parse("") == nil
      assert HostOrigins.parse("   ") == nil
      assert HostOrigins.parse(",,") == nil
    end

    test "single host expands to https + http origins plus obsidian origins" do
      %{canonical_host: canonical, origins: origins} = HostOrigins.parse("app.engram.page")

      assert canonical == "app.engram.page"
      assert "https://app.engram.page" in origins
      assert "http://app.engram.page" in origins
      assert "app://obsidian.md" in origins
      assert "capacitor://localhost" in origins
      assert "http://localhost" in origins
    end

    test "comma-separated list — first entry is canonical, all entries in allowlist" do
      %{canonical_host: canonical, origins: origins} =
        HostOrigins.parse("app.engram.page,engram.ax")

      assert canonical == "app.engram.page"
      assert "https://app.engram.page" in origins
      assert "http://app.engram.page" in origins
      assert "https://engram.ax" in origins
      assert "http://engram.ax" in origins
    end

    test "trims whitespace and ignores empty entries" do
      %{canonical_host: canonical, origins: origins} =
        HostOrigins.parse("  app.engram.page , , engram.ax  ")

      assert canonical == "app.engram.page"
      assert "https://engram.ax" in origins
    end

    test "deduplicates origins when canonical is repeated" do
      %{origins: origins} = HostOrigins.parse("engram.ax,engram.ax")
      assert Enum.count(origins, &(&1 == "https://engram.ax")) == 1
      assert Enum.count(origins, &(&1 == "http://engram.ax")) == 1
    end

    test "supports host:port entries" do
      %{origins: origins} = HostOrigins.parse("app.engram.page,10.0.20.214:8000")
      assert "https://10.0.20.214:8000" in origins
      assert "http://10.0.20.214:8000" in origins
    end
  end
end
