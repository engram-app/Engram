defmodule Engram.Observability.SentryFinchClientTest do
  # async: false because the client's Finch pool is registered under a fixed global
  # name (the module), which the running app may already have started because
  # config.exs names this module as the Sentry client.
  use ExUnit.Case, async: false

  alias Engram.Observability.SentryFinchClient

  setup do
    # The app may already run this Finch pool (config.exs sets it as the Sentry
    # client). Start it under the test supervisor only if it is not already up.
    unless Process.whereis(SentryFinchClient) do
      start_supervised!(SentryFinchClient.child_spec())
    end

    :ok
  end

  test "child_spec/0 returns a supervisable Finch spec" do
    assert %{id: Engram.Observability.SentryFinchClient, start: {Finch, :start_link, _}} =
             SentryFinchClient.child_spec()
  end

  test "post/3 sends the body and returns {:ok, status, headers, body}" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == "payload"
      Plug.Conn.resp(conn, 200, ~s({"id":"abc"}))
    end)

    url = "http://localhost:#{bypass.port}/api/1/envelope/"

    assert {:ok, 200, resp_headers, resp_body} =
             SentryFinchClient.post(url, [{"content-type", "application/json"}], "payload")

    assert is_list(resp_headers)
    assert resp_body == ~s({"id":"abc"})
  end

  test "post/3 returns {:error, reason} when the endpoint is unreachable" do
    # Nothing listens on port 1.
    assert {:error, _reason} =
             SentryFinchClient.post("http://localhost:1/api/1/envelope/", [], "payload")
  end
end
