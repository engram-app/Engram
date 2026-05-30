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
end
