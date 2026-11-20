defmodule EngramWeb.NotesRestWriteBudgetTest do
  @moduledoc """
  Per-user budget on `POST /api/notes` (`rest_writes_per_min`): every caller
  but an API-key script (2026-11-18: one Free user's plugin sent ~300k writes
  in 24 h and nothing refused it). A small per-user override stands in for the
  default so a test need not push 300 notes.
  async: false: the limiter's bucket store is global.
  """
  use EngramWeb.ConnCase, async: false

  alias EngramWeb.SyncRateLimit

  @cap 3

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    :ok
  end

  defp cap!(user, n),
    do: insert(:user_limit_override, user: user, key: "rest_writes_per_min", value: %{"v" => n})

  defp session_conn(n \\ @cap) do
    user = insert(:user)
    insert(:vault, user: user, is_default: true)
    cap!(user, n)
    authenticate(build_conn(), user)
  end

  defp api_key_conn do
    %{conn: conn, user: user} = authed_api_conn(%{conn: build_conn()})
    cap!(user, @cap)
    conn
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
    conn = api_key_conn()

    for n <- 1..(@cap + 2) do
      assert json_response(write(conn, n), 200)
    end
  end

  # The plugin can run on a pasted API key; the flood was ~10/s, under the
  # 30/s api_rps_cap, so the key alone must not exempt it.
  test "an API-key caller sending X-Plugin-Version is charged the budget" do
    conn = put_req_header(api_key_conn(), "x-plugin-version", "9.9.9")

    for n <- 1..@cap, do: assert(json_response(write(conn, n), 200))
    assert json_response(write(conn, @cap + 1), 429)["error"] == "rate_limited"
  end

  # The load sim (e2e/load/grant.sql) seeds 10k notes through this route.
  test "a -1 override lifts the budget for one account" do
    conn = session_conn(-1)

    for n <- 1..(@cap + 2), do: assert(json_response(write(conn, n), 200))
  end

  describe "burst and sustained windows (catalog default)" do
    test "a 150-file first sync fits the burst; a 10/s loop is refused within the minute" do
      user = insert(:user)
      assert {{burst, 60_000}, _} = SyncRateLimit.rest_write_limits(user)
      assert burst >= 150

      for _ <- 1..burst, do: assert(:ok = SyncRateLimit.check_rest_write(user))

      assert {:error, {:rate_limited, ms}} = SyncRateLimit.check_rest_write(user)
      assert ms > 0
    end

    test "past the burst window, the sustained window still refuses a loop" do
      user = insert(:user)
      {_, {sustained, sustained_ms}} = SyncRateLimit.rest_write_limits(user)

      # Earlier minutes of a loop spent the sustained window; this minute's
      # burst window is empty.
      EngramWeb.RateLimiter.hit(
        "rest_write_10m:#{user.id}",
        sustained_ms,
        sustained,
        :rest_write,
        sustained
      )

      assert {:error, {:rate_limited, _}} = SyncRateLimit.check_rest_write(user)
    end
  end
end
