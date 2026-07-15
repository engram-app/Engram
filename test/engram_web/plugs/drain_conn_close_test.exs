defmodule EngramWeb.Plugs.DrainConnCloseTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias EngramWeb.Plugs.DrainConnClose

  setup do
    on_exit(&Engram.Drainer.reset_draining_for_test/0)
  end

  test "no header while not draining" do
    conn = DrainConnClose.call(conn(:get, "/api/health"), [])
    assert Plug.Conn.get_resp_header(conn, "connection") == []
  end

  test "connection: close once drain has started" do
    Engram.Drainer.drain(grace_ms: 0, pause_oban: fn -> :ok end)
    conn = DrainConnClose.call(conn(:get, "/api/health"), [])
    assert Plug.Conn.get_resp_header(conn, "connection") == ["close"]
  end
end
