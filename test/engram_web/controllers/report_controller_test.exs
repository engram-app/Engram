defmodule EngramWeb.ReportControllerTest do
  use EngramWeb.ConnCase, async: false
  alias Engram.Accounts
  alias Engram.Repo
  alias Engram.Support.IssueReport

  setup do
    {:ok, user} = Accounts.create_user_with_password("reporter@example.com", "password123")
    {:ok, user: user}
  end

  defp authed(user) do
    jwt = Accounts.generate_jwt(user)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> jwt)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("user-agent", "obsidian/1.5 engram/1.9.24")
    |> put_req_header("x-vault-id", "vault-abc")
  end

  test "creates a report and stamps identity server-side", %{user: user} do
    conn =
      authed(user)
      |> post(
        "/api/reports",
        Jason.encode!(%{description: "broken sync", surface: "plugin", app_version: "1.9.24"})
      )

    assert %{"report" => %{"id" => id, "status" => "open"}} = json_response(conn, 201)
    report = Repo.get(IssueReport, id)
    assert report.user_id == user.id
    assert report.vault_id == "vault-abc"
    assert report.surface == "plugin"
    assert byte_size(report.device_fingerprint) == 12
  end

  test "rejects unauthenticated requests" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/reports",
        Jason.encode!(%{description: "x", surface: "web", app_version: "1"})
      )

    assert conn.status in [401, 403]
  end

  test "422 on an over-long description", %{user: user} do
    conn =
      authed(user)
      |> post(
        "/api/reports",
        Jason.encode!(%{
          description: String.duplicate("a", 5001),
          surface: "web",
          app_version: "1"
        })
      )

    assert json_response(conn, 422)["errors"]
  end

  test "429 after exceeding the per-user rate limit", %{user: user} do
    body = Jason.encode!(%{description: "spam", surface: "web", app_version: "1"})

    statuses =
      for _ <- 1..6 do
        authed(user) |> post("/api/reports", body) |> Map.get(:status)
      end

    assert 429 in statuses
  end
end
