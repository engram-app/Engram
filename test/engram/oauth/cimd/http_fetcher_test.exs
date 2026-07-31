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

  test "reports a transport failure when nothing is listening", %{bypass: bypass, target: target} do
    Bypass.down(bypass)
    assert {:error, :fetch_failed} = HttpFetcher.fetch_target(target)
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
