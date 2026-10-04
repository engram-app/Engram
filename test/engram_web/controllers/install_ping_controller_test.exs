defmodule EngramWeb.InstallPingControllerTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Repo
  alias Engram.Telemetry.InstallPing

  @valid %{
    "id" => "0192f3a0-7b1e-7c3a-9d2e-5a1b2c3d4e5f",
    "version" => "0.5.518",
    "os" => "linux",
    "arch" => "amd64",
    "runtime" => "docker"
  }

  setup do
    # runtime.exs forces this false in test (no Paddle key); the collector is SaaS-only.
    prev = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev) end)
  end

  defp ping(conn, params), do: post(conn, "/api/telemetry/ping", params)
  defp rows, do: Repo.all(InstallPing, skip_tenant_check: true)

  test "204 and one row for a valid ping", %{conn: conn} do
    assert response(ping(conn, @valid), 204)

    assert [
             %InstallPing{
               id: id,
               version: "0.5.518",
               os: "linux",
               arch: "amd64",
               runtime: "docker"
             }
           ] =
             rows()

    assert id == @valid["id"]
  end

  test "a repeat ping upserts the same install and refreshes its fields", %{conn: conn} do
    assert response(ping(conn, @valid), 204)
    assert response(ping(conn, %{@valid | "version" => "0.6.0", "arch" => "arm64"}), 204)

    assert [%InstallPing{version: "0.6.0", arch: "arm64"}] = rows()
  end

  test "different installs are separate rows", %{conn: conn} do
    assert response(ping(conn, @valid), 204)
    assert response(ping(conn, %{@valid | "id" => Ecto.UUID.generate()}), 204)

    assert length(rows()) == 2
  end

  for {field, bad} <- [
        {"id", "not-a-uuid"},
        {"os", "plan9"},
        {"arch", "mips"},
        {"runtime", "kubernetes"},
        {"version", String.duplicate("9", 33)}
      ] do
    test "422 and no row when #{field} is invalid", %{conn: conn} do
      conn = ping(conn, Map.put(@valid, unquote(field), unquote(bad)))

      assert json_response(conn, 422)
      assert rows() == []
    end
  end

  test "422 when a field is missing", %{conn: conn} do
    assert json_response(ping(conn, Map.delete(@valid, "runtime")), 422)
    assert rows() == []
  end

  test "extra fields are ignored, never stored", %{conn: conn} do
    assert response(ping(conn, Map.put(@valid, "hostname", "my-box")), 204)
    refute Map.has_key?(hd(rows()) |> Map.from_struct(), :hostname)
  end

  test "404 on a self-host instance (billing disabled): only SaaS collects", %{conn: conn} do
    prev = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, false)
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev) end)

    assert json_response(ping(conn, @valid), 404)
    assert rows() == []
  end
end
