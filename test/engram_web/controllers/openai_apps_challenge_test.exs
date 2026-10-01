defmodule EngramWeb.OpenAIAppsChallengeTest do
  # async: false — mutates the global :openai_apps_challenge app env.
  use EngramWeb.ConnCase, async: false

  setup do
    prev = Application.get_env(:engram, :openai_apps_challenge)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:engram, :openai_apps_challenge, prev),
        else: Application.delete_env(:engram, :openai_apps_challenge)
    end)

    :ok
  end

  test "returns the configured token as bare plain text", %{conn: conn} do
    Application.put_env(:engram, :openai_apps_challenge, "tok_abc123")

    conn = get(conn, "/.well-known/openai-apps-challenge")

    assert conn.status == 200
    assert conn.resp_body == "tok_abc123"
    assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
  end

  test "answers a text/plain Accept header, not only json", %{conn: conn} do
    Application.put_env(:engram, :openai_apps_challenge, "tok_abc123")

    conn =
      conn
      |> put_req_header("accept", "text/plain")
      |> get("/.well-known/openai-apps-challenge")

    assert conn.status == 200
  end

  # The token changes when a new plugin draft is created; an edge-cached old
  # token would fail verification until the cache expired.
  test "is not publicly cacheable", %{conn: conn} do
    Application.put_env(:engram, :openai_apps_challenge, "tok_abc123")

    conn = get(conn, "/.well-known/openai-apps-challenge")

    refute Enum.any?(get_resp_header(conn, "cache-control"), &(&1 =~ "public"))
  end

  test "404s when no token is configured (self-host, or before submission)", %{conn: conn} do
    Application.delete_env(:engram, :openai_apps_challenge)

    conn = get(conn, "/.well-known/openai-apps-challenge")

    assert conn.status == 404
  end
end
