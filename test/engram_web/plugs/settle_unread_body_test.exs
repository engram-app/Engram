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

  defmodule ProgressAdapter do
    def get_http_protocol(_state), do: :"HTTP/1.1"
    def read_req_body(%{reads: n} = state, _opts), do: {:more, "x", %{state | reads: n + 1}}
  end

  test "settle/2 stops at the wall-clock deadline even while bytes trickle in" do
    conn = %Plug.Conn{state: :sent, adapter: {ProgressAdapter, %{reads: 0}}}

    assert %Plug.Conn{adapter: {ProgressAdapter, %{reads: 1}}} = SettleUnreadBody.settle(conn, 0)
  end

  defmodule RefuseRouter do
    import Plug.Conn
    def init(opts), do: opts
    def call(conn, _opts), do: conn |> send_resp(401, "nope") |> halt()
  end

  # Reports anything the plug raises: in the endpoint that exception would
  # reach Phoenix and Sentry.PlugCapture.
  defmodule Catcher do
    def init(test), do: {test, SettleUnreadBody.init(RefuseRouter)}

    def call(conn, {test, opts}) do
      SettleUnreadBody.call(conn, opts)
    rescue
      e ->
        send(test, {:raised, e})
        reraise e, __STACKTRACE__
    end
  end

  describe "behind a real Bandit listener" do
    setup do
      test = self()

      {:ok, pid} =
        start_supervised(
          {Bandit, plug: {Catcher, test}, port: 0, ip: :loopback, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      id = "settle-#{inspect(make_ref())}"

      :telemetry.attach(
        id,
        [:bandit, :request, :stop],
        fn _event, _measure, meta, _ -> send(test, {:bandit_stop, meta[:error]}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
      %{port: port}
    end

    defp post_head(length) do
      "POST /x HTTP/1.1\r\nhost: a\r\ncontent-type: application/octet-stream\r\n" <>
        "content-length: #{length}\r\n\r\n"
    end

    defp status_line(sock) do
      {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
      data |> String.split("\r\n") |> hd()
    end

    # Bandit alone drains 8 MB after the response; a 10 MB body is past that.
    test "HTTP/1: a body past Bandit's own drain gets the 401 and keeps the socket", %{port: port} do
      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      body = :binary.copy("a", 10_000_000)

      :ok = :gen_tcp.send(sock, [post_head(byte_size(body)), body])
      assert status_line(sock) == "HTTP/1.1 401 Unauthorized"

      :ok = :gen_tcp.send(sock, [post_head(1), "b"])
      assert status_line(sock) == "HTTP/1.1 401 Unauthorized"
      :gen_tcp.close(sock)
    end

    test "HTTP/1: a client that hangs up mid-drain raises nothing", %{port: port} do
      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      :ok = :gen_tcp.send(sock, [post_head(5_000_000), :binary.copy("a", 100_000)])
      assert status_line(sock) == "HTTP/1.1 401 Unauthorized"
      :gen_tcp.close(sock)

      assert_receive {:bandit_stop, _error}, 5_000
      refute_received {:raised, _}
    end

    # Bandit resets an unread HTTP/2 stream (RST_STREAM NO_ERROR) right after the
    # response. Draining it instead held the request open for each 15 s read
    # timeout (or forever, for a client trickling a byte every few seconds).
    test "HTTP/2: the request ends right after the 401, nothing is drained", %{port: port} do
      {:ok, conn} = Mint.HTTP2.connect(:http, "127.0.0.1", port)

      headers = [{"content-type", "application/octet-stream"}, {"content-length", "5000000"}]
      {:ok, conn, ref} = Mint.HTTP2.request(conn, "POST", "/x", headers, :stream)
      {:ok, _conn} = Mint.HTTP2.stream_request_body(conn, ref, :binary.copy("a", 16_000))

      assert_receive {:bandit_stop, nil}, 2_000
    end
  end
end
