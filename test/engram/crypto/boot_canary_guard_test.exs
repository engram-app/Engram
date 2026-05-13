defmodule Engram.Crypto.BootCanaryGuardTest do
  use Engram.DataCase, async: false

  alias Engram.Crypto.{BootCanary, BootCanaryGuard}

  setup do
    Repo.delete_all("system_canaries")
    :ok
  end

  describe "start_link/0 (T3-audit C2)" do
    test "returns :ignore on success — no process needs to stick around" do
      BootCanary.provision!()

      assert :ignore = BootCanaryGuard.start_link()
    end

    test "returns {:error, _} when master key cannot unwrap canary" do
      # T3-audit C2 — this is the contract that makes Application.start/2
      # fail-loud. When BootCanary.verify!/0 raises inside init/1,
      # GenServer.start_link returns {:error, reason}. Inside the supervisor
      # tree this propagates as a child startup failure → Supervisor.start_link
      # returns {:error, _} → Application.start/2 returns {:error, _} → VM
      # exits non-zero. The OLD wiring (`Task.start_link` + `:temporary`)
      # silently dropped the raise; the app booted with the wrong key.
      #
      # `start_link` links the new process to the caller, so we trap exits
      # to receive `{:error, _}` instead of crashing the test process when
      # init/1 raises.
      Process.flag(:trap_exit, true)

      BootCanary.provision!()

      original = Application.get_env(:engram, :encryption_master_key)
      foreign = Base.encode64(:binary.copy(<<0xAA>>, 32))
      Application.put_env(:engram, :encryption_master_key, foreign)
      on_exit(fn -> Application.put_env(:engram, :encryption_master_key, original) end)

      assert {:error, reason} = BootCanaryGuard.start_link()

      # The exception is wrapped in the GenServer init failure tuple. Walk
      # both shapes — `{exception, stacktrace}` (modern OTP) and bare reason.
      message = extract_message(reason)
      assert message =~ "boot canary unwrap failed"
    end

    test "auto-provisions a fresh canary when table is empty (boot-from-scratch)" do
      assert Repo.aggregate("system_canaries", :count) == 0

      assert :ignore = BootCanaryGuard.start_link()

      assert Repo.aggregate("system_canaries", :count) == 1
    end
  end

  defp extract_message({%RuntimeError{message: m}, _stack}), do: m
  defp extract_message(%RuntimeError{message: m}), do: m
  defp extract_message(other), do: inspect(other)
end
