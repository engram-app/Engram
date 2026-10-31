defmodule EngramWeb.Plugs.RetryAfterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias EngramWeb.Plugs.RetryAfter

  defp respond(status, headers \\ []) do
    conn = conn(:get, "/") |> RetryAfter.call([])
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
    send_resp(conn, status, "")
  end

  test "a 503 without one gets 30s" do
    assert get_resp_header(respond(503), "retry-after") == ["30"]
  end

  # SeqGate.BusyError renders as a bare 429: the plugin needs retry-after on it.
  test "a shed vault write (BusyError 429) gets a short retry-after" do
    conn =
      conn(:get, "/")
      |> RetryAfter.call([])
      |> assign(:reason, %Engram.Vaults.SeqGate.BusyError{})
      |> send_resp(429, "")

    assert get_resp_header(conn, "retry-after") == ["2"]
  end

  # A cap-0 refusal is a 429 with NO retry-after on purpose (nothing to loop
  # on). Only BusyError may get one added.
  test "any other 429 without one stays without one" do
    assert get_resp_header(respond(429), "retry-after") == []
  end

  test "a response that names its own keeps it" do
    assert get_resp_header(respond(429, [{"retry-after", "7"}]), "retry-after") == ["7"]
  end

  test "other statuses get none" do
    assert get_resp_header(respond(200), "retry-after") == []
  end
end
