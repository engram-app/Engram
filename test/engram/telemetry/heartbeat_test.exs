defmodule Engram.Telemetry.HeartbeatTest do
  use Engram.DataCase, async: false

  alias Engram.Instance
  alias Engram.Telemetry.Heartbeat

  setup do
    prev_billing = Application.get_env(:engram, :billing_enabled)
    prev_census = Application.get_env(:engram, :census_ping)
    Application.put_env(:engram, :billing_enabled, false)
    # config/config.exs enables it for prod builds only; tests opt in explicitly.
    Application.put_env(:engram, :census_ping, true)
    System.delete_env("DO_NOT_TRACK")
    System.delete_env("ENGRAM_TELEMETRY")

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev_billing)
      Application.put_env(:engram, :census_ping, prev_census)
      System.delete_env("DO_NOT_TRACK")
      System.delete_env("ENGRAM_TELEMETRY")
    end)
  end

  describe "payload/0" do
    test "is exactly id, version, os, arch, runtime and nothing else" do
      payload = Heartbeat.payload()

      assert payload |> Map.keys() |> Enum.sort() == [:arch, :id, :os, :runtime, :version]
      assert payload.id == Instance.install_id()
      assert payload.version == to_string(Application.spec(:engram, :vsn))
      assert payload.os in ~w(linux darwin windows other)
      assert payload.arch in ~w(amd64 arm64 other)
      assert payload.runtime in ~w(docker source)
    end
  end

  describe "enabled?/0" do
    test "true by default: an operator who has not answered counts as on" do
      assert Instance.telemetry_enabled() == nil
      assert Heartbeat.enabled?()
    end

    test "true once acknowledged" do
      {:ok, _} = Instance.set_telemetry_enabled(true)
      assert Heartbeat.enabled?()
    end

    test "false when the operator opted out" do
      {:ok, _} = Instance.set_telemetry_enabled(false)
      refute Heartbeat.enabled?()
    end

    test "false on SaaS (billing_enabled) even when on by default" do
      Application.put_env(:engram, :billing_enabled, true)
      refute Heartbeat.enabled?()
    end

    test "false outside prod builds, so dev and source runs never ping the real collector" do
      Application.put_env(:engram, :census_ping, false)
      refute Heartbeat.enabled?()
    end

    test "DO_NOT_TRACK=1 overrides the default and an explicit yes" do
      {:ok, _} = Instance.set_telemetry_enabled(true)
      System.put_env("DO_NOT_TRACK", "1")
      refute Heartbeat.enabled?()
    end

    test "ENGRAM_TELEMETRY=off overrides the default and an explicit yes" do
      {:ok, _} = Instance.set_telemetry_enabled(true)
      System.put_env("ENGRAM_TELEMETRY", "off")
      refute Heartbeat.enabled?()
    end
  end

  describe "log_boot_notice/0" do
    import ExUnit.CaptureLog

    # config/test.exs pins :warning, which would drop the info line and turn the
    # "silent" cases below into vacuous passes.
    setup do
      prev = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev) end)
    end

    test "tells a self-host operator the ping is on and how to turn it off" do
      log = capture_log(fn -> Heartbeat.log_boot_notice() end)

      assert log =~ "anonymous daily usage ping"
      assert log =~ "ENGRAM_TELEMETRY=off"
    end

    test "is silent outside prod builds (nothing is sent there)" do
      Application.put_env(:engram, :census_ping, false)
      assert capture_log(fn -> Heartbeat.log_boot_notice() end) == ""
    end

    test "is silent on SaaS" do
      Application.put_env(:engram, :billing_enabled, true)
      assert capture_log(fn -> Heartbeat.log_boot_notice() end) == ""
    end

    test "is silent when the environment already forbids the ping" do
      System.put_env("ENGRAM_TELEMETRY", "off")
      assert capture_log(fn -> Heartbeat.log_boot_notice() end) == ""
    end
  end
end
