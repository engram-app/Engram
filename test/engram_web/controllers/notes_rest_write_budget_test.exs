defmodule EngramWeb.NotesRestWriteBudgetTest do
  @moduledoc """
  Per-user budget on `POST /api/notes` for session / device-token callers
  (2026-11-18: one Free user sent ~300k writes in 24 h and nothing refused it).
  async: false: the limiter's bucket store and the limit override are global.
  """
  use EngramWeb.ConnCase, async: false

  @cap 3

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    Application.put_env(:engram, :rest_write_rate_limit_override, @cap)
    on_exit(fn -> Application.delete_env(:engram, :rest_write_rate_limit_override) end)
    :ok
  end

  defp session_conn do
    user = insert(:user)
    insert(:vault, user: user, is_default: true)
    authenticate(build_conn(), user)
  end

  defp write(conn, n),
    do: post(conn, "/api/notes", %{path: "T/N#{n}.md", content: "# n#{n}", mtime: 1.0})

  test "429 with retry-after once the per-minute budget is spent; below it passes" do
    conn = session_conn()

    for n <- 1..@cap, do: assert(json_response(write(conn, n), 200))

    denied = write(conn, @cap + 1)
    assert json_response(denied, 429)["error"] == "rate_limited"
    assert [secs] = get_resp_header(denied, "retry-after")
    assert String.to_integer(secs) >= 1
  end

  test "one user's flood does not touch another user" do
    flooder = session_conn()
    other = session_conn()

    for n <- 1..(@cap + 2), do: write(flooder, n)
    assert json_response(write(flooder, 99), 429)
    assert json_response(write(other, 1), 200)
  end

  test "API-key callers stay on api_rps_cap, not this budget" do
    %{conn: conn} = authed_api_conn(%{conn: build_conn()})

    for n <- 1..(@cap + 2) do
      assert json_response(write(conn, n), 200)
    end
  end
end
