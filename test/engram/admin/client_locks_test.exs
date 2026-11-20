defmodule Engram.Admin.ClientLocksTest do
  # async: false. Turns the runtime-override DB layer on and flips
  # `:billing_enabled`; both are node-wide.
  use EngramWeb.ConnCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Admin.ClientLocks
  alias Engram.Cache
  alias Engram.LegalFixtures
  alias Engram.Onboarding
  alias Engram.Onboarding.GateCache
  alias Engram.ServiceConfig
  alias Engram.Vaults

  # Compile-time floor is 1.36.0. These are LITERALS on purpose.
  @lock_args ["1.99.0", "1.99.0", 3600, "bad build floods logs"]

  defp lock!(extra \\ []) do
    [min, to, exp, reason] = @lock_args

    :ok =
      ClientLocks.lock_plugin_version(
        min,
        to,
        exp,
        reason,
        [by: "t"] ++ extra
      )
  end

  defp get_folders(conn, version) do
    conn |> Plug.Conn.put_req_header("x-plugin-version", version) |> get(~p"/api/folders")
  end

  setup %{conn: conn} do
    Application.put_env(:engram, :plugin_manifest_fetcher, fn -> {:ok, "1.99.0"} end)
    on_exit(fn -> Application.delete_env(:engram, :plugin_manifest_fetcher) end)
    ServiceConfig.put_override(:service_overrides_enabled, true)
    Cache.clear_local(:service_overrides)
    Cache.clear_local(:service_overrides_last_good)
    prev = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)

    LegalFixtures.insert_version(
      document: "terms_of_service",
      version: "2026-05-15",
      content_hash: "canonical",
      material: true,
      effective_date: nil
    )

    LegalFixtures.reset_version_cache()
    GateCache.evict_all()

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev)
      LegalFixtures.reset_version_cache()
      GateCache.evict_all()
      Cache.clear_local(:service_overrides)
    end)

    user = insert_user(onboarding_profile: %{})
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, _vault, _} = Vaults.register_vault(user, "Locks", Ecto.UUID.generate())
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    {:ok, _} = Onboarding.accept_free_tier(user)
    {:ok, user} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
    GateCache.evict_all()

    {:ok, conn: authenticate(conn, user), user: user}
  end

  describe "runtime plugin floor" do
    test "refuses a client above the compile floor but below the lock, passes an at-lock one", %{
      conn: conn
    } do
      assert conn |> get_folders("1.50.0") |> json_response(200)
      lock!()

      body = conn |> get_folders("1.50.0") |> json_response(426)
      assert body["error"] == "plugin_upgrade_required"
      # What users are told to install is `update_to`.
      assert body["min_version"] == "1.99.0"
      assert body["update_url"] == "obsidian://show-plugin?id=engram-vault-sync"
      assert conn |> get_folders("1.99.0") |> json_response(200)
    end

    test "lift: a refused client passes on the very next request; lift is idempotent", %{
      conn: conn
    } do
      lock!()
      conn |> get_folders("1.50.0") |> json_response(426)

      Phoenix.PubSub.subscribe(Engram.PubSub, ClientLocks.topic())
      assert :ok = ClientLocks.lift_plugin_lock(by: "t")
      assert_receive {:client_gate_recheck, "1.99.0"}
      assert conn |> get_folders("1.50.0") |> json_response(200)

      assert :ok = ClientLocks.lift_plugin_lock()
      assert :ok = ClientLocks.lift_plugin_lock()
      assert conn |> get_folders("1.50.0") |> json_response(200)
    end

    test "an expired lock is unlocked with no lift and no sweep", %{conn: conn} do
      past = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.to_iso8601()

      :ok =
        ServiceConfig.override(:plugin_floor, %{
          "min" => "1.99.0",
          "update_to" => "1.99.0",
          "expires_at" => past,
          "reason" => "x"
        })

      assert conn |> get_folders("1.50.0") |> json_response(200)
      assert %{expired?: true, active?: false} = ClientLocks.list_locks().plugin_floor
    end

    test "a garbled runtime value falls back to the compile-time floor", %{conn: conn} do
      # Per-process override bypasses the write-time validation, like a bad raw-SQL row.
      ServiceConfig.put_override(:plugin_floor, %{"min" => "banana"})
      assert conn |> get_folders("1.50.0") |> json_response(200)
      # The compile floor still binds.
      assert conn |> get_folders("1.0.0") |> json_response(426)
    end

    test "kill switch off behaves as lifted", %{conn: conn} do
      lock!()
      conn |> get_folders("1.50.0") |> json_response(426)
      :ok = ServiceConfig.override(:plugin_floor_enabled, false)
      assert conn |> get_folders("1.50.0") |> json_response(200)
      assert %{switch_on?: false, active?: false} = ClientLocks.list_locks().plugin_floor
    end

    test "can only raise: the compile floor still refuses what the lock would admit", %{
      conn: conn
    } do
      lock!()
      assert conn |> get_folders("1.0.0") |> json_response(426)
    end

    test "list_locks shows what is active and when it self-reverses" do
      lock!()
      state = ClientLocks.list_locks().plugin_floor

      assert %{
               active?: true,
               set?: true,
               effective_min: "1.99.0",
               min: "1.99.0",
               reason: "bad build floods logs"
             } = state

      assert %DateTime{} = state.expires_at
    end
  end

  describe "single source of the minimum" do
    test "HTTP body, socket-join body and features payload all report the lock's min and update_to",
         %{conn: conn, user: user} do
      :ok =
        ClientLocks.lock_plugin_version("1.98.0", "1.99.0", 3600, "r")

      http = conn |> get_folders("1.50.0") |> json_response(426)

      assert %{"min_version" => "1.98.0", "update_to" => "1.99.0", "your_version" => "1.50.0"} =
               http

      assert http["update_url"] == "obsidian://show-plugin?id=engram-vault-sync"

      assert {:error,
              %{min_version: "1.98.0", update_to: "1.99.0", reason: "plugin_upgrade_required"} =
                sock} =
               Engram.ClientGate.check(user, "1.50.0", false)

      assert sock.your_version == "1.50.0"

      assert %{min_version: "1.98.0", update_to: "1.99.0"} =
               EngramWeb.UserChannel.features().plugin_floor

      # Change the floor: every surface moves together.
      :ok =
        ClientLocks.lock_plugin_version("1.97.0", "1.97.5", 3600, "r")

      http = conn |> get_folders("1.50.0") |> json_response(426)
      assert {:error, sock} = Engram.ClientGate.check(user, "1.50.0", false)
      assert {http["min_version"], http["update_to"]} == {sock.min_version, sock.update_to}
      assert {"1.97.0", "1.97.5"} == {http["min_version"], http["update_to"]}

      assert %{min_version: "1.97.0", update_to: "1.97.5"} =
               EngramWeb.UserChannel.features().plugin_floor
    end

    test "with no lock the body is the compile-time floor, update_to included", %{conn: conn} do
      body = conn |> get_folders("1.0.0") |> json_response(426)
      assert %{"min_version" => "1.36.0", "update_to" => "1.36.0"} = body
    end

    test "an account_paused refusal carries no update_to", ctx do
      :ok = ClientLocks.quarantine_user(ctx.user.id, "r", 60)
      refute Map.has_key?(ctx.conn |> get(~p"/api/folders") |> json_response(403), "update_to")
    end
  end

  describe "manifest fetch over HTTP (Req.Test)" do
    setup do
      Application.delete_env(:engram, :plugin_manifest_fetcher)
      Application.put_env(:engram, :plugin_manifest_req_options, plug: {Req.Test, ClientLocks})

      on_exit(fn ->
        Application.delete_env(:engram, :plugin_manifest_req_options)
      end)
    end

    test "success reads the manifest version" do
      Req.Test.stub(ClientLocks, &Plug.Conn.send_resp(&1, 200, ~s({"version":"1.99.0"})))
      assert {:ok, "1.99.0"} = ClientLocks.latest_published()
      assert :ok = ClientLocks.lock_plugin_version("1.99.0", "1.99.0", 60, "r")
    end

    test "timeout, non-200 and garbage bodies are unverifiable and need confirm" do
      stubs = [
        &Req.Test.transport_error(&1, :timeout),
        &Plug.Conn.send_resp(&1, 404, "not found"),
        &Plug.Conn.send_resp(&1, 200, "<html>not json</html>"),
        &Plug.Conn.send_resp(&1, 200, ~s({"nope":1}))
      ]

      for stub <- stubs do
        Req.Test.stub(ClientLocks, stub)
        assert {:error, {:manifest_unavailable, _}} = ClientLocks.latest_published()

        assert {:error, {:update_to_not_verified_published, {:error, _}, :pass_confirm_true}} =
                 ClientLocks.lock_plugin_version("1.99.0", "1.99.0", 60, "r")

        assert :ok = ClientLocks.lock_plugin_version("1.99.0", "1.99.0", 60, "r", confirm: true)
        :ok = ClientLocks.lift_plugin_lock()
      end
    end
  end

  describe "guards" do
    test "refuses update_to below min, missing expiry, bad reason, min at or below the compile floor" do
      assert {:error, _} =
               ClientLocks.lock_plugin_version("1.99.0", "1.98.0", 60, "r", confirm: true)

      assert {:error, {:expiry_required, _}} =
               ClientLocks.lock_plugin_version("1.99.0", "1.99.0", nil, "r", confirm: true)

      assert {:error, {:expiry_required, _}} =
               ClientLocks.lock_plugin_version("1.99.0", "1.99.0", 0, "r", confirm: true)

      assert {:error, _} =
               ClientLocks.lock_plugin_version("1.99.0", "1.99.0", 60, "", confirm: true)

      assert {:error, {:min_not_above_compiled_floor, "1.36.0"}} =
               ClientLocks.lock_plugin_version("1.36.0", "1.36.0", 60, "r", confirm: true)

      assert ClientLocks.list_locks().plugin_floor.set? == false
    end

    test "refuses an update_to above the PUBLISHED manifest version (not operator input) unless confirmed" do
      Application.put_env(:engram, :plugin_manifest_fetcher, fn -> {:ok, "1.40.0"} end)

      assert {:error, {:update_to_not_verified_published, {:above, "1.40.0"}, :pass_confirm_true}} =
               ClientLocks.lock_plugin_version("1.99.0", "1.99.0", 60, "r")

      # The operator cannot vouch for themselves: an extra opt changes nothing.
      assert {:error, _} =
               ClientLocks.lock_plugin_version("1.99.0", "1.99.0", 60, "r",
                 highest_published: "1.99.0"
               )

      assert :ok = ClientLocks.lock_plugin_version("1.99.0", "1.99.0", 60, "r", confirm: true)
    end

    test "an unreachable manifest needs confirm" do
      Application.put_env(:engram, :plugin_manifest_fetcher, fn -> {:error, :nxdomain} end)

      assert {:error, {:update_to_not_verified_published, {:error, :nxdomain}, _}} =
               ClientLocks.lock_plugin_version("1.99.0", "1.99.0", 60, "r")

      assert :ok = ClientLocks.lock_plugin_version("1.99.0", "1.99.0", 60, "r", confirm: true)
    end

    test "a lock that re-enables a switched-off kill switch says so in the audit line" do
      :ok = ServiceConfig.override(:plugin_floor_enabled, false)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok = ClientLocks.lock_plugin_version("1.99.0", "1.99.0", 60, "r")
        end)

      assert log =~ "reenabled_kill_switch=true"
    end
  end

  describe "real override path (no per-process stubbing of the floor)" do
    test "ServiceConfig.override -> effective_minimum -> 426 over HTTP", %{conn: conn} do
      exp = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.to_iso8601()
      lock = %{"min" => "1.97.0", "update_to" => "1.98.0", "expires_at" => exp, "reason" => "r"}

      assert :ok = ServiceConfig.override(:plugin_floor, lock, by: "t")
      assert %{min: "1.97.0", show: "1.98.0"} = Engram.PluginVersion.effective_minimum()

      assert %{"min_version" => "1.97.0", "update_to" => "1.98.0"} =
               conn |> get_folders("1.50.0") |> json_response(426)

      assert :ok = ServiceConfig.clear(:plugin_floor)
      assert %{min: "1.36.0"} = Engram.PluginVersion.effective_minimum()
    end

    test "an invalid lock value is rejected at write time" do
      assert {:error, {:invalid_value, :plugin_floor, _}} =
               ServiceConfig.override(:plugin_floor, %{"min" => "nope"})
    end
  end

  describe "quarantine" do
    test "the +61 s job drops sockets only while still quarantined", ctx do
      :ok = ClientLocks.quarantine_user(ctx.user.id, "r", 3600)
      EngramWeb.Endpoint.subscribe("user_socket:#{ctx.user.id}")
      assert :ok = perform_job(Engram.Workers.QuarantineDisconnect, %{user_id: ctx.user.id})
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      :ok = ClientLocks.lift_quarantine(ctx.user.id)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert :ok = perform_job(Engram.Workers.QuarantineDisconnect, %{user_id: ctx.user.id})
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 200
    end

    test "refuses with account_paused, still stamps activity, and lifts on the next request",
         ctx do
      assert is_nil(Engram.UsageMeters.last_active_at(ctx.user.id))
      :ok = ClientLocks.quarantine_user(ctx.user.id, "log loop", 3600, by: "t")

      body = ctx.conn |> get(~p"/api/folders") |> json_response(403)
      assert body["error"] == "account_paused"
      assert %DateTime{} = Engram.UsageMeters.last_active_at(ctx.user.id)
      assert [%{reason: "log loop"}] = ClientLocks.list_locks().quarantined

      :ok = ClientLocks.lift_quarantine(ctx.user.id, by: "t")
      assert ctx.conn |> get(~p"/api/folders") |> json_response(200)
      assert :ok = ClientLocks.lift_quarantine(ctx.user.id)
      assert [] = ClientLocks.list_locks().quarantined
    end

    test "disconnects live sockets now and schedules the +61 s repeat", ctx do
      EngramWeb.Endpoint.subscribe("user_socket:#{ctx.user.id}")
      :ok = ClientLocks.quarantine_user(ctx.user.id, "log loop", 3600)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert_enqueued(worker: Engram.Workers.QuarantineDisconnect, args: %{user_id: ctx.user.id})

      :ok = ClientLocks.lift_quarantine(ctx.user.id)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "an expired quarantine is unlocked without a lift", ctx do
      :ok = ClientLocks.quarantine_user(ctx.user.id, "r", 60)

      Engram.Repo.update_all(
        Engram.Billing.UserLimitOverride,
        [set: [expires_at: DateTime.add(DateTime.utc_now(), -5, :second)]],
        skip_tenant_check: true
      )

      Engram.Billing.OverrideCache.evict_all()
      assert ctx.conn |> get(~p"/api/folders") |> json_response(200)
    end

    test "a failed +61 s job insert returns an error but the quarantine stands", ctx do
      Application.put_env(:engram, :quarantine_job_insert, fn _ -> {:error, :boom} end)
      on_exit(fn -> Application.delete_env(:engram, :quarantine_job_insert) end)

      assert {:error, {:second_disconnect_not_scheduled, _}} =
               ClientLocks.quarantine_user(ctx.user.id, "r", 3600)

      assert ctx.conn |> get(~p"/api/folders") |> json_response(403)
      assert [%{}] = ClientLocks.list_locks().quarantined
    end

    test "unknown user is refused" do
      assert {:error, :user_not_found} =
               ClientLocks.quarantine_user(Ecto.UUID.generate(), "r", 60)
    end

    test "quarantine and the version lock are independent", ctx do
      lock!()
      :ok = ClientLocks.quarantine_user(ctx.user.id, "r", 3600)

      :ok = ClientLocks.lift_quarantine(ctx.user.id)
      # Version lock survives a quarantine lift.
      assert ctx.conn |> get_folders("1.50.0") |> json_response(426)

      :ok = ClientLocks.quarantine_user(ctx.user.id, "r", 3600)
      :ok = ClientLocks.lift_plugin_lock()
      # Quarantine survives a version lift.
      assert ctx.conn |> get_folders("1.50.0") |> json_response(403)
    end
  end
end
