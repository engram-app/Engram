defmodule Engram.Vector.QdrantActiveClusterTest do
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  setup do
    old = Bypass.open()
    v2 = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{old.port}")
    ServiceConfig.put_override(:qdrant_api_key, "old-key")
    ServiceConfig.put_override(:qdrant_url_v2, "http://localhost:#{v2.port}")
    ServiceConfig.put_override(:qdrant_api_key_v2, "v2-key")
    %{old: old, v2: v2}
  end

  defp expect_scroll(bypass, key) do
    Bypass.expect_once(bypass, "POST", "/collections/c1/points/scroll", fn conn ->
      assert Plug.Conn.get_req_header(conn, "api-key") == [key]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":{"points":[],"next_page_offset":null}}))
    end)
  end

  defp scroll, do: Qdrant.scroll("c1", filter: %{}, limit: 1)

  test "the default is the old cluster with its key", %{old: old} do
    expect_scroll(old, "old-key")
    assert {:ok, _} = scroll()
    assert Qdrant.active_cluster() == "old"
  end

  test "v2 active routes calls to v2 with the v2 key", %{v2: v2} do
    ServiceConfig.put_override(:qdrant_active_cluster, "v2")
    expect_scroll(v2, "v2-key")
    assert {:ok, _} = scroll()
    assert Qdrant.base_url() == "http://localhost:#{v2.port}"
  end

  # A node whose task def lacks QDRANT_URL_V2 (one tier's TF not rolled)
  # writes the old cluster while its peers write v2: it must say so loudly.
  test "v2 without a URL reads old, and logs an error", %{old: old} do
    ServiceConfig.put_override(:qdrant_active_cluster, "v2")
    ServiceConfig.put_override(:qdrant_url_v2, nil)
    :persistent_term.erase({Qdrant, :v2_unconfigured_logged_at})
    expect_scroll(old, "old-key")

    log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, _} = scroll() end)
    assert log =~ "QDRANT_URL_V2"
  end

  test "with_cluster pins this process and restores after", %{old: old, v2: v2} do
    expect_scroll(v2, "v2-key")
    assert {:ok, _} = Qdrant.with_cluster("v2", &scroll/0)

    expect_scroll(old, "old-key")
    assert {:ok, _} = scroll()
  end

  test "with_cluster refuses an unconfigured v2" do
    ServiceConfig.put_override(:qdrant_url_v2, nil)
    assert_raise ArgumentError, fn -> Qdrant.with_cluster("v2", fn -> :ok end) end
  end
end
