defmodule EngramWeb.Admin.TelemetryControllerTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Instance

  setup do
    Application.put_env(:engram, :auth_provider, :local)
    System.delete_env("DO_NOT_TRACK")
    System.delete_env("ENGRAM_TELEMETRY")

    on_exit(fn ->
      Application.put_env(:engram, :auth_provider, :local)
      System.delete_env("DO_NOT_TRACK")
      System.delete_env("ENGRAM_TELEMETRY")
    end)

    :ok
  end

  test "GET shows nil (not asked), no env override, and the exact payload", %{conn: conn} do
    admin = insert(:user, role: "admin")
    body = conn |> authenticate(admin) |> get(~p"/api/admin/telemetry") |> json_response(200)

    assert body["telemetry_enabled"] == nil
    assert body["env_disabled"] == false

    assert body["payload"] |> Map.keys() |> Enum.sort() == [
             "arch",
             "id",
             "os",
             "runtime",
             "version"
           ]

    assert body["payload"]["id"] == Instance.install_id()
  end

  test "GET flags an environment override", %{conn: conn} do
    System.put_env("DO_NOT_TRACK", "1")
    admin = insert(:user, role: "admin")
    body = conn |> authenticate(admin) |> get(~p"/api/admin/telemetry") |> json_response(200)

    assert body["env_disabled"] == true
  end

  test "PATCH records the operator's answer", %{conn: conn} do
    admin = insert(:user, role: "admin")

    body =
      conn
      |> authenticate(admin)
      |> patch(~p"/api/admin/telemetry", %{enabled: true})
      |> json_response(200)

    assert body["telemetry_enabled"] == true
    assert Instance.telemetry_enabled() == true
  end

  test "PATCH can record a refusal", %{conn: conn} do
    admin = insert(:user, role: "admin")

    body =
      conn
      |> authenticate(admin)
      |> patch(~p"/api/admin/telemetry", %{enabled: false})
      |> json_response(200)

    assert body["telemetry_enabled"] == false
    assert Instance.telemetry_enabled() == false
  end

  test "PATCH rejects a non-boolean with 422 and stores nothing", %{conn: conn} do
    admin = insert(:user, role: "admin")

    body =
      conn
      |> authenticate(admin)
      |> patch(~p"/api/admin/telemetry", %{enabled: "yes"})
      |> json_response(422)

    assert body["error"] == "invalid_enabled"
    assert Instance.telemetry_enabled() == nil
  end

  test "non-admin gets 403", %{conn: conn} do
    member = insert(:user, role: "member")
    assert conn |> authenticate(member) |> get(~p"/api/admin/telemetry") |> json_response(403)

    assert conn
           |> authenticate(member)
           |> patch(~p"/api/admin/telemetry", %{enabled: true})
           |> json_response(403)
  end
end
