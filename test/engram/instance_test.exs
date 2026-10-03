defmodule Engram.InstanceTest do
  use Engram.DataCase, async: false
  alias Engram.Instance

  test "registration_mode defaults to invite_only when unset" do
    assert Instance.registration_mode() == "invite_only"
  end

  test "set_registration_mode/1 persists and reads back" do
    assert {:ok, _} = Instance.set_registration_mode("open")
    assert Instance.registration_mode() == "open"
  end

  test "set_registration_mode/1 rejects invalid values" do
    assert {:error, :invalid_mode} = Instance.set_registration_mode("bogus")
  end

  test "set_registration_mode/1 keeps a single row (id=1) on repeated writes" do
    {:ok, _} = Instance.set_registration_mode("open")
    {:ok, _} = Instance.set_registration_mode("closed")
    assert Engram.Repo.aggregate(Engram.Instance.InstanceSettings, :count) == 1
  end

  describe "install_id/0" do
    test "mints a uuid and returns the same one on every call" do
      id = Instance.install_id()
      assert {:ok, _} = Ecto.UUID.cast(id)
      assert Instance.install_id() == id
      assert Engram.Repo.aggregate(Engram.Instance.TelemetrySettings, :count) == 1
    end

    test "never creates an instance_settings row, so it cannot freeze the registration default" do
      prev = Application.get_env(:engram, :default_registration_mode)
      Application.put_env(:engram, :default_registration_mode, "invite_only")
      on_exit(fn -> Application.put_env(:engram, :default_registration_mode, prev) end)

      _ = Instance.install_id()
      assert Engram.Repo.aggregate(Engram.Instance.InstanceSettings, :count) == 0

      # An env change after the first ping still applies.
      Application.put_env(:engram, :default_registration_mode, "open")
      assert Instance.registration_mode() == "open"
      assert Instance.bootstrap_pending?()
    end

    test "leaves an existing registration_mode and bootstrap stamp alone" do
      {:ok, _} = Instance.set_registration_mode("closed")
      {:ok, _} = Instance.mark_bootstrap_complete()
      _ = Instance.install_id()
      assert Instance.registration_mode() == "closed"
      refute Instance.bootstrap_pending?()
    end
  end

  describe "telemetry_enabled/0" do
    test "is nil until the operator answers" do
      assert Instance.telemetry_enabled() == nil
    end

    test "round-trips true and false, keeping install_id and mode" do
      id = Instance.install_id()
      {:ok, _} = Instance.set_registration_mode("open")

      assert {:ok, _} = Instance.set_telemetry_enabled(true)
      assert Instance.telemetry_enabled() == true
      assert {:ok, _} = Instance.set_telemetry_enabled(false)
      assert Instance.telemetry_enabled() == false

      assert Instance.install_id() == id
      assert Instance.registration_mode() == "open"
    end

    test "answering before any ping still mints one stable install_id" do
      {:ok, _} = Instance.set_telemetry_enabled(false)
      id = Instance.install_id()

      assert {:ok, _} = Ecto.UUID.cast(id)
      assert Instance.install_id() == id
      assert Instance.telemetry_enabled() == false
      assert Engram.Repo.aggregate(Engram.Instance.TelemetrySettings, :count) == 1
    end

    test "set_telemetry_enabled/1 never creates an instance_settings row either" do
      {:ok, _} = Instance.set_telemetry_enabled(true)
      assert Engram.Repo.aggregate(Engram.Instance.InstanceSettings, :count) == 0
    end
  end
end
