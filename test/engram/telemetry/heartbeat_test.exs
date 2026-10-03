defmodule Engram.Telemetry.HeartbeatTest do
  use Engram.DataCase, async: false

  alias Engram.Instance
  alias Engram.Telemetry.Heartbeat

  setup do
    prev_billing = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, false)
    System.delete_env("DO_NOT_TRACK")
    System.delete_env("ENGRAM_TELEMETRY")

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev_billing)
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
    test "false until the operator opts in" do
      refute Heartbeat.enabled?()
    end

    test "true once opted in" do
      {:ok, _} = Instance.set_telemetry_enabled(true)
      assert Heartbeat.enabled?()
    end

    test "false when the operator opted out" do
      {:ok, _} = Instance.set_telemetry_enabled(false)
      refute Heartbeat.enabled?()
    end

    test "false on SaaS (billing_enabled) even if opted in" do
      {:ok, _} = Instance.set_telemetry_enabled(true)
      Application.put_env(:engram, :billing_enabled, true)
      refute Heartbeat.enabled?()
    end

    test "DO_NOT_TRACK=1 overrides an opt-in" do
      {:ok, _} = Instance.set_telemetry_enabled(true)
      System.put_env("DO_NOT_TRACK", "1")
      refute Heartbeat.enabled?()
    end

    test "ENGRAM_TELEMETRY=off overrides an opt-in" do
      {:ok, _} = Instance.set_telemetry_enabled(true)
      System.put_env("ENGRAM_TELEMETRY", "off")
      refute Heartbeat.enabled?()
    end
  end
end
