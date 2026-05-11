defmodule Engram.SpaIntegrityTest do
  use ExUnit.Case, async: true

  alias Engram.SpaIntegrity

  @moduletag :tmp_dir

  describe "verify!/1" do
    test "returns :ok when every asset referenced in index.html exists on disk", %{tmp_dir: dir} do
      asset_dir = Path.join(dir, "assets")
      File.mkdir_p!(asset_dir)
      File.write!(Path.join(asset_dir, "index-abc.js"), "console.log('hi')")
      File.write!(Path.join(asset_dir, "index-def.css"), "body{}")
      File.write!(Path.join(asset_dir, "chunk-ghi.js"), "export {}")

      File.write!(Path.join(dir, "index.html"), """
      <!DOCTYPE html><html><head>
      <link rel="stylesheet" href="/assets/index-def.css">
      <link rel="modulepreload" href="/assets/chunk-ghi.js">
      <script type="module" src="/assets/index-abc.js"></script>
      </head><body></body></html>
      """)

      assert :ok = SpaIntegrity.verify!(static_root: dir)
    end

    test "raises when index.html references an asset that doesn't exist", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "assets"))

      File.write!(Path.join(dir, "index.html"), """
      <script type="module" src="/assets/missing-xyz.js"></script>
      """)

      assert_raise RuntimeError, ~r/missing assets.*missing-xyz\.js/, fn ->
        SpaIntegrity.verify!(static_root: dir)
      end
    end

    test "raises when index.html itself is missing", %{tmp_dir: dir} do
      assert_raise RuntimeError, ~r/index\.html/, fn ->
        SpaIntegrity.verify!(static_root: dir)
      end
    end

    test "ignores non-/assets references (favicons, external CDNs)", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "index.html"), """
      <link rel="icon" href="/favicon.ico">
      <script src="https://cdn.example.com/lib.js"></script>
      """)

      assert :ok = SpaIntegrity.verify!(static_root: dir)
    end
  end
end
