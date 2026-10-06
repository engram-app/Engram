defmodule EngramWeb.Plugs.SettleUnreadBodyTest do
  @moduledoc """
  Pipeline refusals (401, 429, ...) on the raw octet-stream upload route answer
  with the body unread. The endpoint drains it after the response, so a bare
  Bandit does not reset the connection under the status.
  """
  use EngramWeb.ConnCase, async: false

  alias EngramWeb.Plugs.SettleUnreadBody

  setup do
    on_exit(fn -> Application.put_env(:engram, :pre_auth_rate_limit_override, nil) end)
    EngramWeb.RateLimiter.reset_buckets!()
    :ok
  end

  defp raw_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> post("/api/attachments?path=a.png&mtime=1.0", body)
  end

  defp unread(conn) do
    {Plug.Adapters.Test.Conn, state} = conn.adapter
    state.req_body
  end

  test "a 401 from Auth drains the raw body", %{conn: conn} do
    conn = raw_post(conn, :binary.copy("a", 3_000_000))

    assert json_response(conn, 401)
    assert unread(conn) == ""
    assert get_resp_header(conn, "connection") == []
  end

  test "a 429 from PreAuthRateLimit drains the raw body", %{conn: conn} do
    Application.put_env(:engram, :pre_auth_rate_limit_override, 1)
    raw_post(conn, "x")

    conn = raw_post(build_conn(), :binary.copy("a", 3_000_000))

    assert conn.status == 429
    assert unread(conn) == ""
  end

  test "a declared length past the ceiling closes instead of draining", %{conn: conn} do
    declared = Integer.to_string(EngramWeb.Endpoint.max_body_bytes() + 1)
    conn = conn |> put_req_header("content-length", declared) |> raw_post("MZ")

    assert json_response(conn, 401)
    assert unread(conn) == "MZ"
    assert get_resp_header(conn, "connection") == ["close"]
  end

  # Bandit HTTP/2 answers each 15 s read timeout with `{:more, "", conn}`
  # (bandit http2/stream.ex:283), so the byte budget never shrinks. Zero
  # progress must end the drain, or a silent client holds it forever.
  defmodule StalledAdapter do
    def read_req_body(%{reads: n}, _opts) when n > 3, do: raise("drained a stalled body")
    def read_req_body(%{reads: n} = state, _opts), do: {:more, "", %{state | reads: n + 1}}
  end

  test "settle/1 stops on a zero-progress read" do
    conn = %Plug.Conn{state: :sent, adapter: {StalledAdapter, %{reads: 0}}}

    assert %Plug.Conn{adapter: {StalledAdapter, %{reads: 1}}} = SettleUnreadBody.settle(conn)
  end
end
