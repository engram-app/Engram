defmodule EngramWeb.UsersControllerTest do
  use EngramWeb.ConnCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Accounts

  defp auth_conn(user) do
    jwt = Accounts.generate_jwt(user)
    build_conn() |> put_req_header("authorization", "Bearer " <> jwt)
  end

  setup do
    # Bootstrap admin so members can exist without inheriting admin role.
    {:ok, _bootstrap} =
      Accounts.create_user_with_password("bootstrap-admin@example.com", "password123")

    {:ok, user} = Accounts.create_user_with_password("user@example.com", "password123")

    {:ok, user: user}
  end

  describe "GET /api/me" do
    test "returns id, email, role, display_name", %{user: user} do
      conn = auth_conn(user) |> get("/api/me")
      body = json_response(conn, 200)
      assert body["user"]["email"] == "user@example.com"
      assert body["user"]["role"] == "member"
      assert Map.has_key?(body["user"], "display_name")
    end

    test "returns the analytics id even when onboarding is incomplete" do
      # Load-bearing: /api/me is on the user-scoped pipeline, which runs Auth but
      # NOT RequireOnboarding. The entire funnel we are trying to measure happens
      # BEFORE onboarding completes, so if this ever moves behind the gate the
      # instrumentation goes dark for exactly the users it exists to observe.
      user =
        insert_user(email: "sabio@web.de", external_id: "user_sabio", onboarding_profile: %{})

      conn = auth_conn(user) |> get("/api/me")
      body = json_response(conn, 200)

      assert body["user"]["analytics_id"] == Engram.Observability.PostHog.analytics_id(user.email)
    end
  end

  describe "analytics opt-out" do
    test "an opted-out user gets no analytics id and the opt-out flag" do
      user = insert_user(email: "objector@example.com", external_id: "user_obj")
      {:ok, user} = Engram.Accounts.set_analytics_opt_out(user)
      assert %DateTime{} = user.analytics_opt_out_at

      body = auth_conn(user) |> get("/api/me") |> json_response(200)
      assert body["user"]["analytics_id"] == nil
      assert body["user"]["analytics_opt_out"] == true
    end

    test "a normal user reports analytics_opt_out false", %{user: user} do
      body = auth_conn(user) |> get("/api/me") |> json_response(200)
      assert body["user"]["analytics_opt_out"] == false
    end

    test "PATCH analytics_opt_out true opts the user out", %{user: user} do
      body = patch_me(user, %{analytics_opt_out: true}) |> json_response(200)
      assert body["user"]["analytics_opt_out"] == true
      assert body["user"]["analytics_id"] == nil
      assert %DateTime{} = Accounts.get_user(user.id).analytics_opt_out_at
    end

    test "opting out again keeps the original objection time", %{user: user} do
      {:ok, user} = Accounts.set_analytics_opt_out(user)

      assert json_response(patch_me(user, %{analytics_opt_out: true}), 200)
      assert Accounts.get_user(user.id).analytics_opt_out_at == user.analytics_opt_out_at
    end

    test "PATCH analytics_opt_out false opts the user back in", %{user: user} do
      {:ok, user} = Accounts.set_analytics_opt_out(user)

      body = patch_me(user, %{analytics_opt_out: false}) |> json_response(200)
      assert body["user"]["analytics_opt_out"] == false
      assert body["user"]["analytics_id"] == Engram.Observability.PostHog.analytics_id(user.email)
      assert Accounts.get_user(user.id).analytics_opt_out_at == nil
    end

    test "422 on a non-boolean analytics_opt_out, and nothing changes", %{user: user} do
      conn = patch_me(user, %{analytics_opt_out: "maybe", display_name: "Pat"})

      assert %{"errors" => %{"analytics_opt_out" => [_ | _]}} = json_response(conn, 422)
      fresh = Accounts.get_user(user.id)
      assert fresh.analytics_opt_out_at == nil
      assert fresh.display_name == nil
    end
  end

  defp patch_me(user, body) do
    auth_conn(user)
    |> put_req_header("content-type", "application/json")
    |> patch("/api/me", Jason.encode!(body))
  end

  describe "PATCH /api/me" do
    test "updates display_name", %{user: user} do
      conn =
        auth_conn(user)
        |> put_req_header("content-type", "application/json")
        |> patch("/api/me", Jason.encode!(%{display_name: "Pat"}))

      body = json_response(conn, 200)
      assert body["user"]["display_name"] == "Pat"
    end

    test "422 on too-long display_name", %{user: user} do
      conn =
        auth_conn(user)
        |> put_req_header("content-type", "application/json")
        |> patch("/api/me", Jason.encode!(%{display_name: String.duplicate("x", 81)}))

      # Sibling-controller 422 shape (%{errors: field → [messages]}) — unified
      # from the old one-off %{error: "validation_failed", details: ...}.
      assert %{"errors" => %{"display_name" => [_ | _]}} = json_response(conn, 422)
    end

    test "stores locale and returns it from GET /api/me", %{user: user} do
      conn =
        auth_conn(user)
        |> put_req_header("content-type", "application/json")
        |> patch("/api/me", Jason.encode!(%{locale: "ja"}))

      assert json_response(conn, 200)["user"]["locale"] == "ja"
      assert json_response(auth_conn(user) |> get("/api/me"), 200)["user"]["locale"] == "ja"
    end

    test "422 on a malformed locale", %{user: user} do
      conn =
        auth_conn(user)
        |> put_req_header("content-type", "application/json")
        |> patch("/api/me", Jason.encode!(%{locale: "not a tag"}))

      assert %{"errors" => %{"locale" => [_ | _]}} = json_response(conn, 422)
    end

    test "401 without bearer" do
      conn = build_conn() |> patch("/api/me", %{display_name: "x"})
      assert response(conn, 401)
    end
  end

  describe "DELETE /api/me" do
    setup :set_mox_from_context
    setup :verify_on_exit!

    setup do
      # `create_user_with_password` assigns a Clerk-style external_id, so the
      # `Lifecycle.hard_delete` cascade calls `Clerk.ApiMock.delete_user/1`.
      # Stub it so it returns :ok without per-test expectations.
      stub(Engram.Auth.Clerk.ApiMock, :delete_user, fn _ -> :ok end)
      :ok
    end

    # The password rides the BODY. In a query string it is written to Phoenix's
    # and the load balancer's access logs and to the browser's Sentry fetch
    # breadcrumb — a credential the user typed into a confirm dialog, spread
    # across three log stores. This test is the contract that keeps the body
    # path working, so the frontend can never be pushed back to the query.
    test "200 with correct password in the request BODY, hard-deletes the user row", %{user: user} do
      conn = auth_conn(user) |> delete("/api/me", %{password: "password123"})
      assert %{"ok" => true} = json_response(conn, 200)

      refute Engram.Repo.get(Engram.Accounts.User, user.id, skip_tenant_check: true)
    end

    # Kept working on purpose: an older cached SPA bundle is still out there
    # sending the query form, and breaking its delete would be worse than the
    # leak it causes. Remove once the bundle floor has moved.
    test "200 with correct password in the query string (legacy bundles)", %{user: user} do
      conn = auth_conn(user) |> delete("/api/me?password=password123")
      assert %{"ok" => true} = json_response(conn, 200)

      refute Engram.Repo.get(Engram.Accounts.User, user.id, skip_tenant_check: true)
    end

    test "403 on wrong password", %{user: user} do
      conn = auth_conn(user) |> delete("/api/me?password=wrong")
      assert %{"error" => "invalid_password"} = json_response(conn, 403)
    end

    test "409 last_admin for the only admin" do
      {:ok, admin} = Accounts.find_by_normalized_email("bootstrap-admin@example.com")
      assert admin.role == "admin"

      conn = auth_conn(admin) |> delete("/api/me?password=password123")
      assert %{"error" => "last_admin"} = json_response(conn, 409)
    end

    test "400 when password param is missing", %{user: user} do
      conn = auth_conn(user) |> delete("/api/me")
      assert %{"error" => "password_required"} = json_response(conn, 400)
    end

    # #2182: a stalled CI Qdrant held this request 10 s (two in-request clears,
    # each on a 5 s budget), the client retried the DELETE, and the replay got
    # 410. The request must not touch Qdrant at all; the purge runs as a job
    # once the account is gone, and still removes every point.
    test "a stalled Qdrant does not hold the request; the points are purged after", %{
      user: user
    } do
      bypass = Bypass.open()
      Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      Engram.ServiceConfig.put_override(:qdrant_search_timeout, 10_000)
      test_pid = self()
      {:ok, stalled} = Agent.start_link(fn -> true end)

      Bypass.stub(bypass, "POST", "/collections/:col/points/delete", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:qdrant_delete, Jason.decode!(body)})
        # Stalled while the request is in flight, healthy for the job after.
        if Agent.get(stalled, & &1), do: Process.sleep(3_000)
        Plug.Conn.send_resp(conn, 200, ~s({"status":"ok","result":{}}))
      end)

      {elapsed_us, conn} =
        :timer.tc(fn -> auth_conn(user) |> delete("/api/me", %{password: "password123"}) end)

      assert %{"ok" => true} = json_response(conn, 200)
      refute_received {:qdrant_delete, _}, "DELETE /api/me called Qdrant inside the request"
      assert elapsed_us < 2_500_000, "DELETE /api/me took #{div(elapsed_us, 1000)} ms"
      refute Engram.Repo.get(Engram.Accounts.User, user.id, skip_tenant_check: true)

      Agent.update(stalled, fn _ -> false end)

      assert [job] = all_enqueued(worker: Engram.Workers.PurgeUserVectors)
      assert job.args == %{"user_id" => user.id}
      assert :ok = perform_job(Engram.Workers.PurgeUserVectors, job.args)

      expected = Engram.Vector.Qdrant.match_filter(:user, user.id) |> Jason.encode!()
      assert_received {:qdrant_delete, %{"filter" => %{"must" => [user_filter]}}}
      assert user_filter == Jason.decode!(expected)
    end
  end
end
