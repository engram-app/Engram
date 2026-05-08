defmodule Engram.ApplicationTest do
  use Engram.DataCase, async: false

  alias Engram.Crypto.BootCanary
  alias Engram.Repo

  describe "preflight!/0 (T3-audit C2)" do
    setup do
      # Boot canary is disabled in :test by default — opt in just for these
      # tests so we can verify the synchronous preflight contract.
      previous_enabled = Application.get_env(:engram, :boot_canary_enabled, true)
      Application.put_env(:engram, :boot_canary_enabled, true)
      on_exit(fn -> Application.put_env(:engram, :boot_canary_enabled, previous_enabled) end)
      :ok
    end

    test "raises (and would halt Application.start/2) when master key cannot unwrap canary" do
      # T3-audit C2 — the prior wiring put BootCanary.verify!/0 inside a
      # `Task.start_link` child with `restart: :temporary`. start_link
      # returned {:ok, _pid} synchronously before verify!/0 ever ran, so a
      # later raise was logged and silently ignored by the supervisor —
      # the app booted with the wrong key. preflight!/0 MUST run
      # synchronously inside Application.start/2 so a raise propagates
      # out of start/2 and the VM exits non-zero.
      Repo.delete_all("system_canaries")
      BootCanary.provision!()

      original = Application.get_env(:engram, :encryption_master_key)
      foreign = Base.encode64(:binary.copy(<<0xAA>>, 32))
      Application.put_env(:engram, :encryption_master_key, foreign)

      on_exit(fn -> Application.put_env(:engram, :encryption_master_key, original) end)

      assert_raise RuntimeError, ~r/boot canary unwrap failed/, fn ->
        Engram.Application.preflight!()
      end
    end

    test "succeeds when master key matches the provisioned canary" do
      Repo.delete_all("system_canaries")
      BootCanary.provision!()

      assert :ok = Engram.Application.preflight!()
    end

    test "skips boot canary when disabled, still validates crypto config" do
      Application.put_env(:engram, :boot_canary_enabled, false)
      Repo.delete_all("system_canaries")
      # No canary row exists; if verify!/0 ran it would auto-provision +
      # succeed. The contract here is that preflight! returns :ok without
      # touching the canary table when disabled.
      assert :ok = Engram.Application.preflight!()
      assert Repo.aggregate("system_canaries", :count) == 0
    end
  end

  describe "wiring source-lint (T3-audit C2)" do
    @app_path "lib/engram/application.ex"

    test "does NOT wrap BootCanary.verify!/0 in a supervised Task" do
      # Source-lint regression guard. The bug pattern was a Task.start_link
      # child for BootCanary.verify!/0 with restart: :temporary — start_link
      # returns synchronously, the verify!/0 raise lands later in the spawned
      # process, and `:temporary` makes the supervisor ignore the EXIT.
      # Result: app booted with wrong master key.
      src = File.read!(@app_path)

      refute src =~ "boot_canary_task",
             "Engram.Application.boot_canary_task/0 was the bug. BootCanary.verify!/0 " <>
               "must run synchronously inside Application.start/2 (via preflight!/0), " <>
               "not under a supervised Task child."

      # Match the supervisor child-spec form `start: {Task, :start_link, ...}`
      # so docstring prose explaining the bug doesn't trip the lint.
      refute src =~ ~r/start:\s*\{Task,\s*:start_link/,
             "No supervisor child may use Task.start_link to run BootCanary.verify!/0 — " <>
               "start_link returns before the function raises, and :temporary causes the " <>
               "supervisor to silently swallow the eventual EXIT."
    end

    test "calls preflight!/0 from start/2 before children" do
      src = File.read!(@app_path)
      assert src =~ "def start(", "expected Engram.Application.start/2"
      assert src =~ "preflight!()", "start/2 must invoke preflight!/0 synchronously"
    end
  end
end
