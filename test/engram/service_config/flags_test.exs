defmodule Engram.ServiceConfig.FlagsTest do
  # async: false: the flags live in node-wide :persistent_term and the source
  # in global app env.
  use Engram.DataCase, async: false

  import Engram.ServiceFlagsHelpers
  import ExUnit.CaptureLog

  alias Engram.Cache
  alias Engram.ServiceConfig
  alias Engram.ServiceConfig.Flags

  setup do
    ServiceConfig.put_override(:service_overrides_enabled, true)
    Cache.clear_local(:service_overrides)
    Cache.clear_local(:service_overrides_last_good)
    on_exit(fn -> Cache.clear_local(:service_overrides) end)
    :ok
  end

  defp count(log, needle), do: log |> String.split(needle) |> length() |> Kernel.-(1)

  describe "precedence" do
    test "flag beats DB beats default" do
      assert ServiceConfig.get(:folder_ops, :default) == :default

      :ok = ServiceConfig.override(:folder_ops, false, by: "t")
      assert ServiceConfig.get(:folder_ops, :default) == false

      start_flags(%{"folder_ops" => true})
      assert ServiceConfig.get(:folder_ops, :default) == true
    end

    test "effective/0 names the source of every key" do
      :ok = ServiceConfig.override(:tenant_idf, true, by: "t")
      start_flags(%{"folder_ops" => true})

      eff = ServiceConfig.effective()
      assert eff.folder_ops == %{value: true, source: :flags}
      assert eff.tenant_idf == %{value: true, source: :db}
      assert %{source: :env} = eff.index_rebuild
    end
  end

  describe "fail-safe" do
    test "an unreachable source keeps the last good value, one warning per state change" do
      path = start_flags(%{"folder_ops" => true})
      File.rm!(path)

      log =
        capture_log(fn ->
          poll()
          poll()
        end)

      assert ServiceConfig.get(:folder_ops, :default) == true
      assert count(log, "service flags source unreachable") == 1
    end

    test "boot with an unreachable source uses DB and defaults" do
      :ok = ServiceConfig.override(:folder_ops, false, by: "t")

      capture_log(fn ->
        use_source({:file, "/nonexistent/service_flags.json"})
        start_supervised!({Flags, {:file, "/nonexistent/service_flags.json"}})
        :sys.get_state(Flags)
      end)

      assert Flags.current() == %{}
      assert ServiceConfig.get(:folder_ops, :default) == false
      assert ServiceConfig.get(:client_logs_stop_writes, :default) == :default
    end

    test "an unknown key is ignored and the others still apply" do
      log = capture_log(fn -> start_flags(%{"no_such_flag" => 1, "folder_ops" => true}) end)

      assert ServiceConfig.get(:folder_ops, :default) == true
      assert Flags.current() == %{folder_ops: true}
      assert log =~ "service flag rejected"
      assert log =~ "no_such_flag"
    end

    test "a bad value is rejected and the old value is kept; other keys still apply" do
      path = start_flags(%{"folder_ops" => true})

      log =
        capture_log(fn ->
          write_flags(path, %{"folder_ops" => "yes", "client_logs_stop_writes" => true})
        end)

      assert ServiceConfig.get(:folder_ops, :default) == true
      assert ServiceConfig.get(:client_logs_stop_writes, :default) == true
      assert count(log, "service flag rejected") == 1
    end

    test "duplicate JSON keys reject the whole document, at any depth" do
      path = start_flags(%{"folder_ops" => true})

      for dup <- [
            ~s({"folder_ops": false, "folder_ops": false}),
            ~s({"paused_accounts": [{"id": "a", "id": "b", "until": "x"}]})
          ] do
        log = capture_log(fn -> write_flags(path, dup) end)
        assert log =~ "service flags document invalid"
        assert Flags.current() == %{folder_ops: true}
        # Back to a good document so the next case is a fresh state change.
        write_flags(path, %{"folder_ops" => true})
      end
    end

    test "invalid JSON keeps the last good map" do
      path = start_flags(%{"folder_ops" => true})
      capture_log(fn -> write_flags(path, "{not json") end)
      assert Flags.current() == %{folder_ops: true}
    end
  end

  describe "the DB write path" do
    test "put and delete are refused for a managed key only when a source is configured" do
      assert :ok = ServiceConfig.override(:folder_ops, true, by: "t")
      assert :ok = ServiceConfig.clear(:folder_ops, by: "t")

      use_source({:file, "/etc/engram/service_flags.json"})

      assert {:error, :managed_by_flags} = ServiceConfig.override(:folder_ops, true, by: "t")
      assert {:error, :managed_by_flags} = ServiceConfig.clear(:folder_ops, by: "t")
      # A key the flags file does not own keeps its DB path.
      assert :ok = ServiceConfig.override(:tenant_idf, true, by: "t")
    end

    test "paused_accounts is flags-only: refused with or without a source" do
      assert {:error, :managed_by_flags} =
               ServiceConfig.override(:paused_accounts, [], by: "t")
    end

    test "self-host (no source): no reader, DB overrides read and write as before" do
      refute Flags.configured?()
      assert Process.whereis(Flags) == nil
      assert :ok = ServiceConfig.override(:folder_ops, true, by: "t")
      assert ServiceConfig.get(:folder_ops, false) == true
      refute Flags.paused?(Ecto.UUID.generate())
    end
  end

  describe "paused_accounts" do
    test "an expired entry is ignored and logged once" do
      id = Ecto.UUID.generate()

      log =
        capture_log(fn ->
          path = start_flags(%{"paused_accounts" => [paused(id, -60)]})
          write_flags(path, %{"paused_accounts" => [paused(id, -60)], "folder_ops" => true})
          poll()
        end)

      refute Flags.paused?(id)
      assert count(log, "paused_accounts entry expired") == 1
    end

    test "an unexpired entry pauses; ids match case-insensitively" do
      id = Ecto.UUID.generate()
      start_flags(%{"paused_accounts" => [paused(String.upcase(id), 3600)]})
      assert Flags.paused?(id)
      refute Flags.paused?(Ecto.UUID.generate())
    end

    test "a newly paused id drops its sockets; a lifted one too; a boot load does not" do
      boot = Ecto.UUID.generate()
      id = Ecto.UUID.generate()
      EngramWeb.Endpoint.subscribe("user_socket:#{boot}")
      EngramWeb.Endpoint.subscribe("user_socket:#{id}")

      path = start_flags(%{"paused_accounts" => [paused(boot, 3600)]})
      refute_received %Phoenix.Socket.Broadcast{topic: "user_socket:" <> _}

      capture_log(fn ->
        write_flags(path, %{"paused_accounts" => [paused(boot, 3600), paused(id, 3600)]})
      end)

      topic = "user_socket:#{id}"
      assert_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
      refute_received %Phoenix.Socket.Broadcast{topic: "user_socket:" <> _}

      capture_log(fn -> write_flags(path, %{"paused_accounts" => [paused(boot, 3600)]}) end)
      assert_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    test "bad entries reject the key: not a uuid, a non-UTC until, a duplicate id, extra fields" do
      id = Ecto.UUID.generate()
      good = paused(id, 3600)

      for bad <- [
            [%{"id" => "not-a-uuid", "until" => good["until"]}],
            [%{"id" => id, "until" => "2030-01-01T00:00:00+02:00"}],
            [good, good],
            [Map.put(good, "note", "x")]
          ] do
        assert {:error, {:invalid_value, :paused_accounts, _}} =
                 Engram.ServiceConfig.Overrides.validate(:paused_accounts, bad)
      end

      assert :ok = Engram.ServiceConfig.Overrides.validate(:paused_accounts, [good])
    end
  end

  describe "plugin_floor" do
    test "a floor change asks user channels to recheck, like the rpc lock; boot does not" do
      Phoenix.PubSub.subscribe(Engram.PubSub, Engram.Admin.ClientLocks.topic())
      lock = %{"min" => "1.99.0", "update_to" => "1.99.0", "reason" => "r"}
      exp = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      path = start_flags(%{"plugin_floor" => Map.put(lock, "expires_at", exp)})
      refute_received {:client_gate_recheck, _}

      capture_log(fn -> write_flags(path, %{}) end)
      assert_received {:client_gate_recheck, "1.99.0"}

      capture_log(fn ->
        write_flags(path, %{
          "plugin_floor" => %{lock | "min" => "1.98.0"} |> Map.put("expires_at", exp)
        })
      end)

      assert_received {:client_gate_recheck, "1.98.0"}
      assert Engram.PluginVersion.minimum() == "1.98.0"
    end
  end

  describe "change log" do
    test "one :data line per changed key with key, old, new and source; no raw user id" do
      id = Ecto.UUID.generate()
      path = start_flags(%{"folder_ops" => false})

      log =
        capture_log([metadata: [:category]], fn ->
          write_flags(path, %{"folder_ops" => true, "paused_accounts" => [paused(id, 3600)]})
        end)

      assert log =~ "service flag changed key=folder_ops old=false new=true source=file"
      assert log =~ "service flag changed key=paused_accounts old=0 new=1"
      assert log =~ Engram.Crypto.HMAC.hash_user_id(id)
      assert log =~ "category=data"
      refute log =~ id
      assert count(log, "service flag changed") == 2
    end
  end

  describe "isolation" do
    test "the reader never queries the database" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "flags-no-repo-#{inspect(ref)}",
        [:engram, :repo, :query],
        fn _, _, _, _ -> send(parent, {ref, self()}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("flags-no-repo-#{inspect(ref)}") end)

      id = Ecto.UUID.generate()
      path = start_flags(%{"folder_ops" => true})
      pid = Process.whereis(Flags)

      capture_log(fn ->
        write_flags(path, %{"paused_accounts" => [paused(id, 3600)]})
        write_flags(path, %{"paused_accounts" => [paused(id, -5)]})
        File.rm!(path)
        poll()
      end)

      refute_received {^ref, ^pid}
    end
  end

  describe "AppConfig source" do
    setup do
      Req.Test.set_req_test_to_shared()

      Application.put_env(:engram, :service_flags_req_options,
        plug: {Req.Test, Flags},
        aws_sigv4: [access_key_id: "test", secret_access_key: "test", service: :appconfig]
      )

      on_exit(fn ->
        Application.delete_env(:engram, :service_flags_req_options)
        Req.Test.set_req_test_to_private()
      end)

      source =
        {:appconfig,
         %{application: "app", environment: "env", profile: "prof", region: "us-east-1"}}

      use_source(source)
      {:ok, source: source}
    end

    # Serves StartConfigurationSession and GetLatestConfiguration, one of
    # `bodies` per GET in order (then empty); records every request.
    defp stub_appconfig(bodies) do
      {:ok, agent} = Agent.start_link(fn -> %{log: [], bodies: bodies} end)

      Req.Test.stub(Flags, fn conn ->
        Agent.update(
          agent,
          &%{&1 | log: [{conn.method, conn.request_path, conn.query_string} | &1.log]}
        )

        if conn.method == "POST" do
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"InitialConfigurationToken" => "t0"})
        else
          case Agent.get_and_update(agent, fn
                 %{bodies: [b | rest]} = s -> {b, %{s | bodies: rest}}
                 s -> {"", s}
               end) do
            {:status, status} ->
              Plug.Conn.send_resp(conn, status, ~s({"Message":"expired"}))

            body ->
              conn
              |> Plug.Conn.put_resp_header(
                "next-poll-configuration-token",
                "t#{System.unique_integer([:positive])}"
              )
              |> Plug.Conn.send_resp(200, body)
          end
        end
      end)

      agent
    end

    defp requests(agent), do: agent |> Agent.get(& &1.log) |> Enum.reverse()

    test "starts a session, applies a body, treats an empty body as unchanged, re-sessions on BadRequest",
         %{source: source} do
      agent = stub_appconfig([~s({"folder_ops": true}), "", {:status, 400}])

      start_supervised!({Flags, source})
      :sys.get_state(Flags)
      assert Flags.current() == %{folder_ops: true}

      poll()
      assert Flags.current() == %{folder_ops: true}

      capture_log(fn -> poll() end)
      assert Flags.current() == %{folder_ops: true}

      assert [{"POST", "/configurationsessions", _}, {"GET", "/configuration", q0} | rest] =
               requests(agent)

      assert q0 =~ "configuration_token=t0"
      assert [{"GET", "/configuration", q1}, {"GET", "/configuration", _}] = rest
      refute q1 =~ "configuration_token=t0"

      # The failed GET dropped the session: the next poll starts a new one.
      poll()
      assert {"POST", "/configurationsessions", _} = agent |> requests() |> Enum.at(4)
    end
  end
end
