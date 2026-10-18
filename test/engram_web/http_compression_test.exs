defmodule EngramWeb.HttpCompressionTest do
  # Compression happens in Bandit's adapter, below Plug, so a ConnTest never
  # sees it. Serve a body through a real Bandit with the options runtime.exs
  # applies, and read the content-encoding a client gets back.
  use ExUnit.Case, async: true

  alias Engram.RuntimeConfig

  defmodule BodyPlug do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{notes: List.duplicate("Meeting notes.md", 2_000)})
      )
    end
  end

  defp served_encoding(env, accept) do
    http_options = RuntimeConfig.http_compression(fn key -> Map.get(env, key) end)

    pid =
      start_supervised!(
        {Bandit,
         plug: BodyPlug, port: 0, ip: :loopback, startup_log: false, http_options: http_options},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port)
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/", [{"accept-encoding", accept}], nil)
    headers = recv_headers(conn, ref)
    Mint.HTTP.close(conn)
    List.keyfind(headers, "content-encoding", 0, {nil, nil}) |> elem(1)
  end

  defp recv_headers(conn, ref) do
    receive do
      message ->
        {:ok, conn, responses} = Mint.HTTP.stream(conn, message)

        case Enum.find(responses, &match?({:headers, ^ref, _}, &1)) do
          {:headers, ^ref, headers} -> headers
          nil -> recv_headers(conn, ref)
        end
    after
      5_000 -> flunk("no response headers")
    end
  end

  test "SaaS: no content-encoding even when the client (Cloudflare) accepts gzip" do
    assert served_encoding(%{"ENGRAM_SAAS_ONLY" => "true"}, "gzip, br") == nil
  end

  test "self-host: deflate when offered, gzip when it is all the client takes" do
    assert served_encoding(%{}, "gzip, deflate, br") == "deflate"
    assert served_encoding(%{}, "gzip") == "gzip"
  end
end
