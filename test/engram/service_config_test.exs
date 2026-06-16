defmodule Engram.ServiceConfigTest do
  # async: true is the whole point — these cases prove two concurrently-running
  # owners can hold distinct per-process overrides without racing each other or
  # the global app env. This is the seam that lets the Voyage/Qdrant Bypass
  # test families flip from async: false to async: true.
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig

  describe "get/2 without an override" do
    test "returns the provided default for an unset key" do
      assert ServiceConfig.get(:__sc_no_such_key__, "fallback") == "fallback"
    end

    test "falls back to Application.get_env when set and no override present" do
      # A key no other (async) test touches, so reading app env here is safe.
      key = :__sc_app_env_only_key__
      Application.put_env(:engram, key, "from-app-env")
      on_exit(fn -> Application.delete_env(:engram, key) end)

      assert ServiceConfig.get(key, "default") == "from-app-env"
    end
  end

  describe "put_override/2" do
    test "overrides get/2 in the same process, beating app env" do
      key = :__sc_override_same_proc__
      Application.put_env(:engram, key, "app-env")
      on_exit(fn -> Application.delete_env(:engram, key) end)

      :ok = ServiceConfig.put_override(key, "overridden")

      assert ServiceConfig.get(key, "default") == "overridden"
    end

    test "is visible to a $callers child process (Task), not just the owner" do
      key = :__sc_override_caller_chain__
      :ok = ServiceConfig.put_override(key, "owner-value")

      # The Task's self() has no override; it must resolve via $callers up to
      # this (owner) process. Task propagates $callers automatically.
      child_value = Task.async(fn -> ServiceConfig.get(key, "default") end) |> Task.await()

      assert child_value == "owner-value"
    end
  end

  describe "per-owner isolation (the async-safety guarantee)" do
    test "two concurrent owners hold distinct overrides with no cross-talk" do
      key = :__sc_isolation__

      t1 =
        Task.async(fn ->
          :ok = ServiceConfig.put_override(key, "one")
          # Yield so both tasks have written before either reads — maximizes the
          # window in which a shared-global bug would clobber the other's value.
          Process.sleep(5)
          ServiceConfig.get(key, "default")
        end)

      t2 =
        Task.async(fn ->
          :ok = ServiceConfig.put_override(key, "two")
          Process.sleep(5)
          ServiceConfig.get(key, "default")
        end)

      assert Task.await(t1) == "one"
      assert Task.await(t2) == "two"
    end
  end
end
