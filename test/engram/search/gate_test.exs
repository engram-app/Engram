defmodule Engram.Search.GateTest do
  @moduledoc """
  The search concurrency cap (`Engram.Search.Gate`): per user, per node,
  bounded wait, then a busy error. Every test runs on its own unregistered
  gate (the app-supervised one is sized to never bind in test).
  """
  use Engram.DataCase, async: true

  import Engram.Factory
  import ExUnit.CaptureLog

  alias Engram.Search
  alias Engram.Search.Gate
  alias Engram.ServiceConfig

  @wait 150

  # A per-test gate, and this process's searches pointed at it.
  defp gate(opts \\ []) do
    opts =
      Keyword.merge(
        [limit: 4, per_user: 2, max_waiting: 32, max_waiting_per_user: 8, name: nil],
        opts
      )

    g = start_supervised!(%{id: make_ref(), start: {Gate, :start_link, [opts]}})
    ServiceConfig.put_override(:search_gate, gate: g, acquire_timeout: @wait)
    g
  end

  # Holds one slot for `user` until sent `:go`. Returns the holder once the
  # slot is really held. A Task, so it inherits this test's ServiceConfig
  # override through `$callers`.
  defp hold(user) do
    test = self()

    {:ok, pid} =
      Task.start(fn ->
        Gate.run(user, fn ->
          send(test, {:holding, self()})
          receive do: (:go -> :ok)
        end)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:holding, ^pid}, 2_000
    pid
  end

  # Runs `Gate.run/2` for `user` in a Task; the result arrives as
  # `{:ran, tag, result}`.
  defp attempt(user, tag) do
    test = self()

    {:ok, pid} =
      Task.start(fn ->
        send(
          test,
          {:ran, tag,
           Gate.run(user, fn ->
             send(test, {:started, tag})
             :ok
           end)}
        )
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    {:ok, pid}
  end

  test "a third concurrent search of one user waits, then gets the busy error" do
    gate()
    a1 = hold("a")
    a2 = hold("a")

    attempt("a", :third)
    refute_receive {:started, :third}, @wait - 50, "ran past the per-user cap"
    assert_receive {:ran, :third, {:error, :search_busy}}, 2_000
    refute_received {:started, :third}

    send(a1, :go)
    send(a2, :go)
  end

  test "a waiting search runs as soon as one of its user's slots frees" do
    g = gate()
    ServiceConfig.put_override(:search_gate, gate: g, acquire_timeout: 5_000)
    a1 = hold("a")
    a2 = hold("a")

    attempt("a", :third)
    refute_receive {:started, :third}, 100
    send(a1, :go)
    assert_receive {:ran, :third, :ok}, 2_000

    send(a2, :go)
  end

  test "one user at its cap does not starve another" do
    gate()
    a1 = hold("a")
    a2 = hold("a")
    attempt("a", :a3)

    # A's third is queued; B still runs at once.
    assert Gate.run("b", fn -> :b_ran end) == :b_ran

    assert_receive {:ran, :a3, {:error, :search_busy}}, 2_000
    send(a1, :go)
    send(a2, :go)
  end

  test "the node-wide limit holds across users" do
    gate(limit: 2, per_user: 2)
    a = hold("a")
    b = hold("b")

    assert Gate.run("c", fn -> :ran end) == {:error, :search_busy}

    send(a, :go)
    send(b, :go)
  end

  test "a freed slot goes to the oldest waiter whose user is under its cap" do
    g = gate(limit: 2, per_user: 1)
    ServiceConfig.put_override(:search_gate, gate: g, acquire_timeout: 5_000)
    a = hold("a")
    b = hold("b")

    # Queue: a2 (user a, at cap) first, then c.
    attempt("a", :a2)
    wait_queued(g, 1)
    attempt("c", :c)
    wait_queued(g, 2)

    # b's slot frees: a is still at its cap, so c goes first.
    send(b, :go)
    assert_receive {:ran, :c, :ok}, 2_000
    refute_received {:started, :a2}

    send(a, :go)
    assert_receive {:ran, :a2, :ok}, 2_000
  end

  test "the per-user queue is bounded: past it a search is refused at once" do
    g = gate(max_waiting_per_user: 1)
    ServiceConfig.put_override(:search_gate, gate: g, acquire_timeout: 60_000)
    a1 = hold("a")
    a2 = hold("a")
    attempt("a", :queued)
    wait_queued(g, 1)

    {us, result} = :timer.tc(fn -> Gate.run("a", fn -> :ran end) end)
    assert result == {:error, :search_busy}
    assert us < 1_000_000, "a full queue must refuse at once, not wait"

    send(a1, :go)
    assert_receive {:ran, :queued, :ok}, 2_000
    send(a2, :go)
  end

  describe "no leaked slots" do
    test "a search that raises gives its slot back" do
      gate(limit: 1)
      assert_raise RuntimeError, fn -> Gate.run("a", fn -> raise "boom" end) end
      assert Gate.run("a", fn -> :ran end) == :ran
    end

    test "a search whose process is killed gives its slot back" do
      g = gate(limit: 1)
      holder = hold("a")
      Process.exit(holder, :kill)
      ServiceConfig.put_override(:search_gate, gate: g, acquire_timeout: 2_000)
      assert Gate.run("b", fn -> :ran end) == :ran
    end

    test "a caller that timed out waiting keeps no slot" do
      g = gate(limit: 1)
      holder = hold("a")

      # Gives up and stays alive, like an MCP request that moved on.
      assert Gate.run("b", fn -> :ran end) == {:error, :search_busy}

      send(holder, :go)
      ServiceConfig.put_override(:search_gate, gate: g, acquire_timeout: 2_000)
      assert Gate.run("c", fn -> :ran end) == :ran
      assert :sys.get_state(g).active == %{}
    end

    test "a waiter that dies while queued leaves the queue" do
      g = gate(limit: 1, max_waiting_per_user: 1)
      ServiceConfig.put_override(:search_gate, gate: g, acquire_timeout: 60_000)
      holder = hold("a")

      {:ok, waiter} = attempt("b", :dies)
      wait_queued(g, 1)
      Process.exit(waiter, :kill)

      # The dead waiter's queue place is gone, so b may queue again.
      attempt("b", :next)
      wait_queued(g, 1)
      send(holder, :go)
      assert_receive {:ran, :next, :ok}, 2_000
    end
  end

  test "every run reports its wait and outcome, with no user id" do
    test = self()
    handler = "search-gate-#{inspect(test)}"

    :telemetry.attach(
      handler,
      [:engram, :search, :gate],
      fn _e, m, meta, pid -> if self() == pid, do: send(pid, {:gate_event, m, meta}) end,
      test
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    gate(limit: 1)
    assert Gate.run("a", fn -> :ok end) == :ok
    assert_receive {:gate_event, %{wait: w}, %{outcome: :ok} = meta}
    assert is_integer(w) and map_size(meta) == 1

    holder = hold("a")
    assert Gate.run("b", fn -> :ran end) == {:error, :search_busy}
    assert_receive {:gate_event, %{wait: w}, %{outcome: :busy}}

    assert System.convert_time_unit(w, :native, :millisecond) >= @wait - 10
    send(holder, :go)
  end

  describe "through Engram.Search" do
    setup do
      Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      # Nothing listens here: a search that got past the gate would fail
      # with a transport error, never with :search_busy.
      ServiceConfig.put_override(:qdrant_url, "http://127.0.0.1:9")
      user = insert(:user)
      %{user: user, vault: insert(:vault, user: user)}
    end

    test "a search whose Qdrant request finds no slot is refused busy",
         %{user: user, vault: vault} do
      gate(per_user: 1)
      holder = hold(user.id)

      assert Search.search(user, vault, "anything") == {:error, :search_busy}
      send(holder, :go)
    end

    test "auto-placement logs a failed search and still places the note", %{
      user: user,
      vault: vault
    } do
      args = %{"title" => "Placed", "content" => "body"}

      log =
        capture_log([level: :warning], fn ->
          assert %{placed_folder: ""} =
                   Engram.MCP.Handlers.before_txn("create_note", user, vault, args)
        end)

      assert log =~ "mcp auto_place_folder failed"
    end

    test "similar_to searches go through the same gate", %{user: user, vault: vault} do
      gate(per_user: 1)
      holder = hold(user.id)

      assert Search.similar(user, vault, [Ecto.UUID.generate()]) == {:error, :search_busy}
      send(holder, :go)
    end
  end

  test "a second acquire from a holder is refused loudly and leaves the counts intact" do
    g = gate(limit: 4, per_user: 2)
    assert Engram.ConcurrencyGate.acquire(g, "a", 100) == :ok

    assert_raise ArgumentError, ~r/already holds a slot/, fn ->
      Engram.ConcurrencyGate.acquire(g, "a", 100)
    end

    assert :sys.get_state(g).counts == %{"a" => 1}
    Engram.ConcurrencyGate.release(g)
    assert :sys.get_state(g).counts == %{}
  end

  describe "the query embed holds no slot" do
    setup do
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      ServiceConfig.put_override(:qdrant_search_timeout, 30_000)

      empty = fn conn, body ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/query/batch", fn conn ->
        empty.(conn, ~s({"result":[{"points":[]},{"points":[]}]}))
      end)

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        empty.(conn, ~s({"result":{"points":[]}}))
      end)

      # "slow" stands in for a Voyage brownout: the embed hangs past the
      # gate's wait, then fails.
      test = self()

      Mox.stub(Engram.MockEmbedder, :embed_texts, fn
        ["slow"], _opts ->
          send(test, :embedding)
          Process.sleep(@wait * 4)
          {:error, :timeout}

        texts, _opts ->
          {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      users =
        for _ <- 1..2 do
          {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
          {user, insert(:vault, user: user)}
        end

      %{users: users}
    end

    test "a slow embed for one user does not stop another user's search; the slow one " <>
           "still degrades to keyword-only",
         %{users: [{a, a_vault}, {b, b_vault}]} do
      gate(limit: 1, per_user: 1)
      slow = Task.async(fn -> Search.search(a, a_vault, "slow", mode: :hybrid) end)
      assert_receive :embedding, 2_000

      # A is inside its embed. With the slot around the whole search this
      # was {:error, :search_busy}.
      assert Search.search(b, b_vault, "fast", mode: :hybrid) == {:ok, []}

      assert Task.await(slow, 5_000) == {:ok, []}
    end
  end

  defp wait_queued(g, n, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    cond do
      :queue.len(:sys.get_state(g).waiting) >= n ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("fewer than #{n} waiter(s) queued after 2 s")

      true ->
        receive(after: (1 -> wait_queued(g, n, deadline)))
    end
  end
end
