defmodule EngramWeb.FieldsControllerTest do
  use EngramWeb.ConnCase, async: false

  import Engram.FieldCatalogHelpers

  setup %{conn: conn} do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)
    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), user: user, vault: vault}
  end

  test "GET /api/fields lists the vault's fields", %{conn: conn, user: user, vault: vault} do
    write_indexed!(user, vault, "a.md", "---\nstatus: draft\nrating: 4\n---\nbody\n")

    assert %{"fields" => fields} = conn |> get("/api/fields") |> json_response(200)
    by_name = Map.new(fields, &{&1["name"], &1})

    assert %{"kinds" => ["string"], "note_count" => 1, "values" => [%{"value" => "draft"}]} =
             by_name["status"]

    assert %{"kinds" => ["number"], "number_range" => %{"min" => 4.0, "max" => 4.0}} =
             by_name["rating"]

    assert_schema(fields, "FieldsResponse")
  end

  test "an empty vault answers an empty list", %{conn: conn} do
    assert %{"fields" => []} = conn |> get("/api/fields") |> json_response(200)
  end

  test "401 without auth" do
    assert build_conn() |> get("/api/fields") |> json_response(401)
  end

  defp assert_schema(fields, title) do
    spec = EngramWeb.ApiSpec.spec()
    OpenApiSpex.TestAssertions.assert_schema(%{"fields" => fields}, title, spec)
  end
end
