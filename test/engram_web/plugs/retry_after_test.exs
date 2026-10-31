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
  test "a 429 without one gets a short retry-after" do
    assert get_resp_header(respond(429), "retry-after") == ["2"]
  end

  test "a response that names its own keeps it" do
    assert get_resp_header(respond(429, [{"retry-after", "7"}]), "retry-after") == ["7"]
  end

  test "other statuses get none" do
    assert get_resp_header(respond(200), "retry-after") == []
  end
end
