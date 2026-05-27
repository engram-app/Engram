defmodule EngramWeb.SignupRejectionControllerTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.Auth.SignupRejections

  defp uniq, do: "user_" <> Integer.to_string(System.unique_integer([:positive]))

  describe "GET /api/auth/signup-rejection" do
    test "returns the reason for a recorded rejection", %{conn: conn} do
      id = uniq()
      :ok = SignupRejections.record(id, :duplicate_identity)

      conn = get(conn, "/api/auth/signup-rejection", %{"clerk_id" => id})

      assert json_response(conn, 200) == %{"reason" => "duplicate_identity"}
    end

    test "returns 404 when no rejection is recorded", %{conn: conn} do
      conn = get(conn, "/api/auth/signup-rejection", %{"clerk_id" => uniq()})

      assert json_response(conn, 404)["reason"] == nil
    end

    test "returns 400 when clerk_id is missing", %{conn: conn} do
      conn = get(conn, "/api/auth/signup-rejection")

      assert json_response(conn, 400)["error"] =~ "clerk_id"
    end
  end
end
