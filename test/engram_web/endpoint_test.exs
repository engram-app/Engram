defmodule EngramWeb.EndpointTest do
  use EngramWeb.ConnCase, async: true

  describe "static assets" do
    test "GET /email/engram-mark.png returns the PNG", %{conn: conn} do
      conn = get(conn, "/email/engram-mark.png")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/png"]

      assert byte_size(conn.resp_body) > 1000,
             "expected a real PNG, got #{byte_size(conn.resp_body)} bytes"
    end
  end
end
