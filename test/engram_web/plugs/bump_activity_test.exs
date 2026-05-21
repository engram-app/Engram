defmodule EngramWeb.Plugs.BumpActivityTest do
  use EngramWeb.ConnCase, async: false

  import Ecto.Query
  alias Engram.Repo
  alias Engram.UsageMeters
  alias EngramWeb.Plugs.BumpActivity

  describe "call/2" do
    test "bumps last_active_at on first request", %{conn: conn} do
      user = insert(:user)
      assert is_nil(UsageMeters.last_active_at(user.id))

      conn
      |> Plug.Conn.assign(:current_user, user)
      |> BumpActivity.call([])

      assert %DateTime{} = UsageMeters.last_active_at(user.id)
    end

    test "no-op when current_user not assigned", %{conn: conn} do
      assert ^conn = BumpActivity.call(conn, [])
    end

    test "no-op (no DB write) when last_active_at is fresh (< 1h)", %{conn: conn} do
      user = insert(:user)
      UsageMeters.bump_last_active(user.id)
      first_stamp = UsageMeters.last_active_at(user.id)

      conn
      |> Plug.Conn.assign(:current_user, user)
      |> BumpActivity.call([])

      assert UsageMeters.last_active_at(user.id) == first_stamp
    end

    test "bumps when last_active_at is older than 1h", %{conn: conn} do
      user = insert(:user)
      UsageMeters.bump_last_active(user.id)

      two_hours_ago = DateTime.utc_now() |> DateTime.add(-7200, :second)

      Repo.update_all(
        from(m in Engram.UsageMeters.Meter, where: m.user_id == ^user.id),
        [set: [last_active_at: two_hours_ago]],
        skip_tenant_check: true
      )

      conn
      |> Plug.Conn.assign(:current_user, user)
      |> BumpActivity.call([])

      bumped = UsageMeters.last_active_at(user.id)
      assert DateTime.diff(bumped, two_hours_ago, :second) > 7000
    end
  end
end
