defmodule Engram.Aws.ReqClientTest do
  @moduledoc """
  Regression guard for Engram #1252: req 0.7 rewrote bodyless GETs into POSTs,
  which turned every S3 download into a signature-mismatched POST while uploads
  kept working. These assert the verb that actually reaches the wire.
  """
  use ExUnit.Case, async: false

  alias Engram.Aws.ReqClient

  setup do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:wire, conn.method, body})
      Plug.Conn.resp(conn, 200, "ok")
    end)

    {:ok, url: "http://localhost:#{bypass.port}/bucket/key.png"}
  end

  defp wire do
    receive do
      {:wire, method, body} -> {method, body}
    after
      1_000 -> flunk("no request reached the server")
    end
  end

  test "a GET with ex_aws's empty-string body stays a GET", %{url: url} do
    assert {:ok, %{status_code: 200}} = ReqClient.request(:get, url, "", [], [])
    assert {"GET", ""} = wire()
  end

  test "a HEAD with an empty-string body stays a HEAD", %{url: url} do
    assert {:ok, %{status_code: 200}} = ReqClient.request(:head, url, "", [], [])
    assert {"HEAD", ""} = wire()
  end

  test "a PUT keeps its verb and its body byte-for-byte", %{url: url} do
    payload = <<137, 80, 78, 71, 13, 10, 26, 10>>

    assert {:ok, %{status_code: 200}} = ReqClient.request(:put, url, payload, [], [])
    assert {"PUT", ^payload} = wire()
  end

  test "a PUT with a legitimately empty body keeps its empty body", %{url: url} do
    assert {:ok, %{status_code: 200}} = ReqClient.request(:put, url, "", [], [])
    assert {"PUT", ""} = wire()
  end

  test "a DELETE keeps its verb", %{url: url} do
    assert {:ok, %{status_code: 200}} = ReqClient.request(:delete, url, "", [], [])
    assert {"DELETE", ""} = wire()
  end

  test "a POST keeps its verb and body", %{url: url} do
    assert {:ok, %{status_code: 200}} = ReqClient.request(:post, url, "xml", [], [])
    assert {"POST", "xml"} = wire()
  end

  test "response headers come back as a list, matching the ExAws contract", %{url: url} do
    assert {:ok, %{headers: headers}} = ReqClient.request(:get, url, "", [], [])
    assert is_list(headers)
  end
end
