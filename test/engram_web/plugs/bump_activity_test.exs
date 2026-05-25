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

    test "warm cache hit within the window issues no meter query", %{conn: conn} do
      user = insert(:user)

      # First request: cold cache → reads (+writes) the meter and warms the cache.
      conn |> Plug.Conn.assign(:current_user, user) |> BumpActivity.call([])

      # Second request: warm cache → must not touch the DB at all.
      queries =
        count_meter_queries(fn ->
          conn |> Plug.Conn.assign(:current_user, user) |> BumpActivity.call([])
        end)

      assert queries == 0
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

  # Counts Repo queries against the `usage_meters` source while `fun` runs.
  defp count_meter_queries(fun) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:engram, :repo, :query],
      fn _event, _measurements, %{source: source}, _config ->
        if source == "usage_meters", do: Agent.update(counter, &(&1 + 1))
      end,
      nil
    )

    try do
      fun.()
      Agent.get(counter, & &1)
    after
      :telemetry.detach(handler_id)
      Agent.stop(counter)
    end
  end
end
