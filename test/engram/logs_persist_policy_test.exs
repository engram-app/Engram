defmodule Engram.LogsPersistPolicyTest do
  # async: false: asserts on a global telemetry event.
  use Engram.DataCase, async: false

  alias Engram.Logs
  alias Engram.Logs.PersistPolicy

  @event [:engram, :client_logs, :dropped]

  setup do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "persist-policy-#{inspect(ref)}",
      @event,
      fn _e, measurements, meta, _ -> send(test_pid, {:dropped, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("persist-policy-#{inspect(ref)}") end)
    %{user: insert(:user)}
  end

  defp line(level, message), do: %{"level" => level, "category" => "sync", "message" => message}

  defp stored(user) do
    {:ok, rows} = Logs.list_logs(user, limit: 1000)
    rows |> Enum.map(& &1.message) |> Enum.sort()
  end

  describe "filtered (SaaS default)" do
    test "drops plain info and debug, keeps warn and error", %{user: user} do
      batch = [
        line("info", "Push start"),
        line("debug", "route: x"),
        line("warn", "Echo skip (attachment): n1"),
        line("error", "push failed")
      ]

      assert {:ok, 2} = Logs.insert_logs(user, batch, nil, persist_all: false)
      assert stored(user) == ["Echo skip (attachment): n1", "push failed"]
    end

    test "keeps every allowlisted info line", %{user: user} do
      batch = for prefix <- PersistPolicy.info_allowlist(), do: line("info", prefix <> " x=1")
      n = length(batch)

      assert {:ok, ^n} = Logs.insert_logs(user, batch, nil, persist_all: false)
      assert length(stored(user)) == n
    end

    test "matches the allowlist by prefix only", %{user: user} do
      assert {:ok, 0} =
               Logs.insert_logs(user, [line("info", "x sync_gate_opened waited_s=3")], nil,
                 persist_all: false
               )
    end

    test "the first-sync milestones are on the allowlist" do
      for msg <- [
            "Layout ready — starting initial sync",
            "Vault not registered — skipping initial sync",
            "sync_gate_opened waited_s=12 context=preview",
            "pullAll started — replay from 0",
            "pullAll(deleteLocalExtras) replay done — applied=40"
          ] do
        assert PersistPolicy.persist?(%{level: "info", message: msg}), msg
      end
    end

    test "counts dropped lines by level", %{user: user} do
      batch = [line("info", "a"), line("info", "b"), line("debug", "c"), line("warn", "d")]
      Logs.insert_logs(user, batch, nil, persist_all: false)

      assert_receive {:dropped, %{lines: 2}, %{reason: :filtered, level: "info"}}
      assert_receive {:dropped, %{lines: 1}, %{reason: :filtered, level: "debug"}}
      refute_receive {:dropped, _, %{level: "warn"}}
    end

    test "an unknown client level is tagged other, never raw", %{user: user} do
      Logs.insert_logs(user, [line("verbose-#{System.unique_integer()}", "a")], nil,
        persist_all: false
      )

      assert_receive {:dropped, %{lines: 1}, %{reason: :filtered, level: "other"}}
    end
  end

  describe "persist_all (CI, test, self-host)" do
    test "keeps info lines", %{user: user} do
      assert {:ok, 2} =
               Logs.insert_logs(user, [line("info", "Push start"), line("debug", "x")], nil,
                 persist_all: true
               )

      refute_receive {:dropped, _, _}
    end

    test "is the test-env default, so the e2e oracle still sees everything", %{user: user} do
      assert {:ok, 1} = Logs.insert_logs(user, [line("info", "Push start")])
    end
  end

  describe "admit (the per-device budget hook)" do
    test "is asked only for the lines that would be kept", %{user: user} do
      test_pid = self()

      admit = fn n ->
        send(test_pid, {:admit, n})
        true
      end

      Logs.insert_logs(user, [line("info", "a"), line("warn", "b")], nil,
        persist_all: false,
        admit: admit
      )

      assert_receive {:admit, 1}
    end

    test "is not asked when nothing would be kept", %{user: user} do
      admit = fn _ -> flunk("admit called for an all-filtered batch") end

      assert {:ok, 0} =
               Logs.insert_logs(user, [line("info", "a")], nil, persist_all: false, admit: admit)
    end

    test "a refused batch stores nothing and counts the lines over budget", %{user: user} do
      assert {:ok, 0} =
               Logs.insert_logs(user, [line("warn", "a"), line("error", "b")], nil,
                 admit: fn _ -> false end
               )

      assert stored(user) == []
      assert_receive {:dropped, %{lines: 1}, %{reason: :over_budget, level: "warn"}}
      assert_receive {:dropped, %{lines: 1}, %{reason: :over_budget, level: "error"}}
    end
  end
end
