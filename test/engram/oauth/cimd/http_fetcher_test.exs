defmodule Engram.OAuth.Cimd.HttpFetcherTest do
  # The transport, against a real local HTTP server. `fetch_target/1` is used
  # rather than `fetch/1` because the SSRF guard would (correctly) refuse a
  # loopback target — that separation is the point of the two functions, and the
  # guard's own rules are covered in Engram.Http.SsrfGuardTest.
  # async: false — this module makes REAL HTTP calls (Bypass), including a 256 KB
  # body it halts mid-stream and a `Bypass.down/1`, and each distinct
  # `connect_options` spins up its own Finch pool. Run async, that competes with
  # neighbours whose assertions are timing-bounded (`Engram.Embedders.VoyageTest`
  # uses a 5s receive_timeout), which showed up as `Req.TransportError{reason:
  # :timeout}` in unrelated suites rather than as a failure here.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Engram.OAuth.Cimd.HttpFetcher

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, target: %{url: endpoint_url(bypass), host: "localhost"}}
  end

  defp endpoint_url(bypass), do: "http://127.0.0.1:#{bypass.port}/doc.json"

  defp respond(conn, status, body, content_type) do
    conn
    |> Plug.Conn.put_resp_content_type(content_type)
    |> Plug.Conn.resp(status, body)
  end

  test "returns the decoded document on 200 application/json", %{bypass: bypass, target: target} do
    document = %{"client_id" => "https://claude.ai/c", "redirect_uris" => ["http://127.0.0.1/cb"]}

    Bypass.expect_once(bypass, "GET", "/doc.json", fn conn ->
      respond(conn, 200, Jason.encode!(document), "application/json")
    end)

    assert {:ok, ^document} = HttpFetcher.fetch_target(target)
  end

  test "tolerates content-type parameters", %{bypass: bypass, target: target} do
    Bypass.expect_once(bypass, "GET", "/doc.json", fn conn ->
      respond(conn, 200, ~s({"a":1}), "application/json; charset=utf-8")
    end)

    assert {:ok, %{"a" => 1}} = HttpFetcher.fetch_target(target)
  end

  # A vendor serving HTML where a document should be is misconfigured, and
  # guessing at it invites parsing whatever an error page contains.
  test "refuses a non-JSON content type", %{bypass: bypass, target: target} do
    Bypass.expect_once(bypass, "GET", "/doc.json", fn conn ->
      respond(conn, 200, ~s({"a":1}), "text/html")
    end)

    assert {:error, :not_json} = HttpFetcher.fetch_target(target)
  end

  test "refuses malformed JSON", %{bypass: bypass, target: target} do
    Bypass.expect_once(bypass, "GET", "/doc.json", fn conn ->
      respond(conn, 200, "{not json", "application/json")
    end)

    assert {:error, :invalid_json} = HttpFetcher.fetch_target(target)
  end

  # A JSON array parses fine and would then blow up on `document["client_id"]`.
  test "refuses valid JSON that is not an object", %{bypass: bypass, target: target} do
    Bypass.expect_once(bypass, "GET", "/doc.json", fn conn ->
      respond(conn, 200, "[1,2,3]", "application/json")
    end)

    assert {:error, :invalid_json} = HttpFetcher.fetch_target(target)
  end

  test "reports a non-200 status", %{bypass: bypass, target: target} do
    Bypass.expect_once(bypass, "GET", "/doc.json", fn conn ->
      respond(conn, 404, "nope", "application/json")
    end)

    assert {:error, {:http_status, 404}} = HttpFetcher.fetch_target(target)
  end

  # THE redirect rule. Following it would fetch a URL the SSRF guard never
  # approved, which is the whole guard bypassed in one hop. A vendor that
  # redirects its metadata document does not work, and that is correct.
  test "does not follow a redirect", %{bypass: bypass, target: target} do
    Bypass.expect_once(bypass, "GET", "/doc.json", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
      |> Plug.Conn.resp(302, "")
    end)

    assert {:error, {:http_status, 302}} = HttpFetcher.fetch_target(target)
  end

  # Capped mid-stream, so a hostile vendor cannot stream gigabytes into our heap.
  # 64 KB cap; 256 KB is unambiguously over it.
  test "caps an oversized body", %{bypass: bypass, target: target} do
    oversized = String.duplicate("a", 256 * 1024)

    Bypass.expect_once(bypass, "GET", "/doc.json", fn conn ->
      respond(conn, 200, ~s({"padding":"#{oversized}"}), "application/json")
    end)

    assert {:error, :body_too_large} = HttpFetcher.fetch_target(target)
  end

  test "accepts a body just under the cap", %{bypass: bypass, target: target} do
    padding = String.duplicate("a", 32 * 1024)

    Bypass.expect_once(bypass, "GET", "/doc.json", fn conn ->
      respond(conn, 200, ~s({"padding":"#{padding}"}), "application/json")
    end)

    assert {:ok, %{"padding" => ^padding}} = HttpFetcher.fetch_target(target)
  end

  # Replaces the old `{:error, :fetch_failed}` assertion: that atom threw away
  # the exception, which is why the 2026-10-13 ChatGPT 503 has no known cause.
  test "reports a transport failure with its phase and reason", %{bypass: bypass, target: target} do
    Bypass.down(bypass)

    {result, log} = with_log(fn -> HttpFetcher.fetch_target(target) end)

    assert {:error, {:transport_error, :connect, :econnrefused}} = result
    assert log =~ "mcp_cimd_fetch_failed"
    assert log =~ "phase=connect"
    assert log =~ "dialed_ip=127.0.0.1"
  end

  test "accepts application/jwk-set+json", %{bypass: bypass, target: target} do
    Bypass.expect_once(bypass, "GET", "/doc.json", fn conn ->
      respond(conn, 200, ~s({"keys":[]}), "application/jwk-set+json")
    end)

    assert {:ok, %{"keys" => []}} = HttpFetcher.fetch_target(target)
  end

  test "identifies itself with a user agent", %{bypass: bypass, target: target} do
    Bypass.expect_once(bypass, "GET", "/doc.json", fn conn ->
      assert ["Engram-OAuth/1.0 (+https://engram.page)"] =
               Plug.Conn.get_req_header(conn, "user-agent")

      respond(conn, 200, "{}", "application/json")
    end)

    assert {:ok, %{}} = HttpFetcher.fetch_target(target)
  end

  describe "address failover and the time budget" do
    # TEST-NET-1 is never routed: a connect there either times out or fails
    # fast, and both must fall through to the next validated address.
    test "a black-holed first address fails over to the second within 3 s", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/doc.json", fn conn ->
        respond(conn, 200, ~s({"ok":true}), "application/json")
      end)

      target = %{
        url: endpoint_url(bypass),
        host: "localhost",
        ips: [{192, 0, 2, 1}, {127, 0, 0, 1}]
      }

      {micros, result} = :timer.tc(fn -> HttpFetcher.fetch_target(target) end)

      assert {:ok, %{"ok" => true}} = result
      assert micros < 3_000_000
    end

    # A raw socket rather than Bypass: Bypass fails the test on exit when its
    # handler is still mid-request, which is exactly the state under test.
    test "a stalled body returns within the budget and logs phase=recv" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      server =
        spawn(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)
          {:ok, _request} = :gen_tcp.recv(socket, 0)

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 64\r\n\r\n{\"keys\":"
            )

          Process.sleep(10_000)
        end)

      on_exit(fn ->
        Process.exit(server, :kill)
        :gen_tcp.close(listen)
      end)

      target = %{url: "http://127.0.0.1:#{port}/doc.json", host: "localhost"}

      {{micros, result}, log} =
        with_log(fn -> :timer.tc(fn -> HttpFetcher.fetch_target(target) end) end)

      assert {:error, {:transport_error, :recv, _}} = result
      assert micros < 3_500_000
      assert log =~ "phase=recv"
    end
  end

  # fetch/1 is guard-then-fetch. Proving the guard is actually wired in matters
  # more than proving it works twice.
  describe "fetch/1 applies the SSRF guard" do
    test "refuses a private address" do
      assert {:error, :private_address} = HttpFetcher.fetch("https://169.254.169.254/doc.json")
    end

    test "refuses plain http" do
      assert {:error, :not_https} = HttpFetcher.fetch("http://claude.ai/doc.json")
    end
  end
end
