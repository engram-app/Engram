defmodule EngramWeb.HttpCompressionTest do
  # Compression happens in Bandit's adapter, below Plug, so a ConnTest never
  # sees it. Serve a body through a real Bandit with the options runtime.exs
  # applies, and read the content-encoding a client gets back.
  use ExUnit.Case, async: true

  alias Engram.RuntimeConfig

  @body Jason.encode!(%{notes: List.duplicate("Meeting notes.md", 2_000)})

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

  # {content-encoding, body decoded per that header}
  defp served(env, accept) do
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
    {headers, body} = recv_response(conn, ref, nil, [])
    Mint.HTTP.close(conn)
    encoding = List.keyfind(headers, "content-encoding", 0, {nil, nil}) |> elem(1)
    {encoding, decode(encoding, body)}
  end

  defp decode(nil, body), do: body
  defp decode("gzip", body), do: :zlib.gunzip(body)
  # HTTP "deflate" is zlib-wrapped (RFC 1950), which :zlib.uncompress reads.
  defp decode("deflate", body), do: :zlib.uncompress(body)

  defp recv_response(conn, ref, headers, chunks) do
    receive do
      message ->
        {:ok, conn, responses} = Mint.HTTP.stream(conn, message)

        Enum.reduce_while(responses, {headers, chunks}, fn
          {:headers, ^ref, h}, {_, c} -> {:cont, {h, c}}
          {:data, ^ref, d}, {h, c} -> {:cont, {h, [d | c]}}
          {:done, ^ref}, {h, c} -> {:halt, {:done, h, c}}
          _, acc -> {:cont, acc}
        end)
        |> case do
          {:done, h, c} -> {h, c |> Enum.reverse() |> IO.iodata_to_binary()}
          {h, c} -> recv_response(conn, ref, h, c)
        end
    after
      5_000 -> flunk("no complete response")
    end
  end

  test "SaaS: no content-encoding even when the client (Cloudflare) accepts gzip" do
    assert served(%{"ENGRAM_SAAS_ONLY" => "true"}, "gzip, br") == {nil, @body}
  end

  test "self-host: deflate when offered, gzip when it is all the client takes" do
    assert served(%{}, "gzip, deflate, br") == {"deflate", @body}
    assert served(%{}, "gzip") == {"gzip", @body}
  end
end
