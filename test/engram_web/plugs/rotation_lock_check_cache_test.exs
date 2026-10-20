defmodule EngramWeb.Plugs.RotationLockCheckCacheTest do
  # Not async: the query recorder's telemetry handler is global, so an async
  # neighbour's RotationLockCheck queries would land in the count.
  use EngramWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias EngramWeb.Plugs.RotationLockCheck

  # The request's current_user comes from the :user cache, so a lock taken
  # on another node shows up there only once its eviction lands. Writes are
  # what encrypt under the old DEK, so they re-read the lock from the DB.
  describe "stale cached user" do
    setup do
      user = insert(:user)

      {1, _} =
        Engram.Repo.update_all(
          from(u in User, where: u.id == ^user.id),
          set: [dek_rotation_locked_at: DateTime.utc_now()]
        )

      # The struct as the cache still holds it: unlocked.
      %{user: user}
    end

    test "a REST write gates its tenant transactions instead of querying", %{
      conn: conn,
      user: user
    } do
      {conn, qs} =
        Engram.QueryRecorder.record(fn ->
          %{conn | method: "POST"}
          |> assign(:current_user, user)
          |> RotationLockCheck.call([])
        end)

      refute conn.halted
      assert Enum.filter(qs, &(&1.caller =~ "RotationLockCheck")) == []

      # The write's own transaction sees the DB lock and refuses.
      assert_raise Engram.Crypto.RotationInProgress, fn ->
        Engram.Repo.with_tenant(user.id, fn -> :write end)
      end

      # The response clears the gate (a keep-alive connection reuses the
      # process) and gives a 503 its Retry-After.
      sent = conn |> put_status(503) |> Plug.Conn.send_resp(503, "")
      assert ["60"] = Plug.Conn.get_resp_header(sent, "retry-after")
      assert {:ok, :read} = Engram.Repo.with_tenant(user.id, fn -> :read end)
    end

    test "a refused write renders the halt's body" do
      assert EngramWeb.ErrorJSON.render("503.json", %{
               reason: %Engram.Crypto.RotationInProgress{}
             }) == %{error: "rotation_in_progress"}
    end

    test "a GET trusts the cached user (no query)", %{conn: conn, user: user} do
      {conn, qs} =
        Engram.QueryRecorder.record(fn ->
          conn |> assign(:current_user, user) |> RotationLockCheck.call([])
        end)

      refute conn.halted
      assert Enum.filter(qs, &(&1.caller =~ "RotationLockCheck")) == []
    end

    defp mcp_post(conn, user, body) do
      %{conn | method: "POST", path_info: ["api", "mcp"], body_params: body}
      |> assign(:current_user, user)
    end

    defp tool_call(name),
      do: %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name}
      }

    test "an MCP read-only tool trusts the cached user (no query)", %{conn: conn, user: user} do
      read_methods =
        ~w(tools/list prompts/list prompts/get resources/list resources/read
           resources/templates/list completion/complete)

      for body <- [tool_call("get_notes") | Enum.map(read_methods, &%{"method" => &1})] do
        {conn, qs} =
          Engram.QueryRecorder.record(fn ->
            conn |> mcp_post(user, body) |> RotationLockCheck.call([])
          end)

        refute conn.halted
        assert Enum.filter(qs, &(&1.caller =~ "RotationLockCheck")) == []
      end
    end

    test "an MCP write tool, unknown tool or batch re-reads the lock and halts", %{
      conn: conn,
      user: user
    } do
      for body <- [tool_call("write_note"), tool_call("no_such_tool"), %{"_json" => []}] do
        conn = conn |> mcp_post(user, body) |> RotationLockCheck.call([])
        assert conn.halted
        assert conn.status == 503
      end
    end

    test "a read-only tool name on another POST route is still a gated write", %{
      conn: conn,
      user: user
    } do
      %{conn | method: "POST", path_info: ["api", "notes"], body_params: tool_call("get_notes")}
      |> assign(:current_user, user)
      |> RotationLockCheck.call([])

      assert_raise Engram.Crypto.RotationInProgress, fn ->
        Engram.Repo.with_tenant(user.id, fn -> :write end)
      end
    end
  end
end
