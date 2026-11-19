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

  test "an API-key script (no plugin signal) stays on api_rps_cap, not this budget" do
    %{conn: conn} = authed_api_conn(%{conn: build_conn()})

    for n <- 1..(@cap + 2) do
      assert json_response(write(conn, n), 200)
    end
  end

  # The plugin can run on a pasted API key; the flood was ~10/s, under the
  # 30/s api_rps_cap, so the key alone must not exempt it.
  test "an API-key caller sending X-Plugin-Version is charged the budget" do
    %{conn: conn} = authed_api_conn(%{conn: build_conn()})
    conn = put_req_header(conn, "x-plugin-version", "9.9.9")

    for n <- 1..@cap, do: assert(json_response(write(conn, n), 200))
    assert json_response(write(conn, @cap + 1), 429)["error"] == "rate_limited"
  end

  describe "burst and sustained windows (real limits)" do
    setup do
      Application.delete_env(:engram, :rest_write_rate_limit_override)
      :ok
    end

    test "a 150-file first sync fits the burst; a 10/s loop is refused within the minute" do
      user_id = Ecto.UUID.generate()
      {{burst, _}, _} = EngramWeb.SyncRateLimit.rest_write_limits()

      for _ <- 1..150, do: assert(:ok = EngramWeb.SyncRateLimit.check_rest_write(user_id))
      for _ <- 151..burst, do: assert(:ok = EngramWeb.SyncRateLimit.check_rest_write(user_id))

      assert {:error, {:rate_limited, ms}} = EngramWeb.SyncRateLimit.check_rest_write(user_id)
      assert ms > 0
    end

    test "past the burst window, the sustained window still refuses a loop" do
      user_id = Ecto.UUID.generate()
      {_, {sustained, sustained_ms}} = EngramWeb.SyncRateLimit.rest_write_limits()

      # Earlier minutes of a loop spent the sustained window; this minute's
      # burst window is empty.
      EngramWeb.RateLimiter.hit(
        "rest_write_10m:#{user_id}",
        sustained_ms,
        sustained,
        :rest_write,
        sustained
      )

      assert {:error, {:rate_limited, _}} = EngramWeb.SyncRateLimit.check_rest_write(user_id)
    end
  end
end
