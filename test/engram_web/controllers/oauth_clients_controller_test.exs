defmodule EngramWeb.OAuthClientsControllerTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.OAuth

  defp register_client(name \\ "Claude") do
    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "client_name" => name
      })

    client
  end

  describe "GET /api/oauth/clients/:client_id" do
    test "returns client_id + client_name only (no secret, no redirect_uris)", %{conn: conn} do
      client = register_client("My App")

      conn = get(conn, "/api/oauth/clients/#{client.client_id}")

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)

      assert json["client_id"] == client.client_id
      assert json["client_name"] == "My App"
      # `kind` is "mcp" for DCR-minted clients (the public endpoint rejects
      # "obsidian"); the consent page reads it to pick the right cap key.
      assert json["kind"] == "mcp"
      assert Map.keys(json) |> Enum.sort() == ["client_id", "client_name", "kind"]
    end

    test "does not require Authorization header (public endpoint)", %{conn: conn} do
      client = register_client()

      conn = get(conn, "/api/oauth/clients/#{client.client_id}")

      refute conn.status == 401
      assert conn.status == 200
    end

    test "returns 404 for unknown client_id (UUID-shaped)", %{conn: conn} do
      conn = get(conn, "/api/oauth/clients/00000000-0000-0000-0000-000000000000")

      assert conn.status == 404
      json = Jason.decode!(conn.resp_body)
      assert json["error"] == "not_found"
    end

    test "returns 404 for non-UUID client_id (no enumeration leak)", %{conn: conn} do
      conn = get(conn, "/api/oauth/clients/not-a-uuid")

      assert conn.status == 404
    end
  end
end
