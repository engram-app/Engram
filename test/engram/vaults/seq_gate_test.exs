defmodule Engram.Vaults.SeqGateTest do
  use Engram.DataCase, async: false

  alias Engram.Vaults.SeqGate

  # Holds the vault's gate from another process until told to let go.
  defp hold_gate(vault_id) do
    parent = self()

    task =
      Task.async(fn ->
        SeqGate.with_vault(vault_id, fn ->
          send(parent, :held)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :held, 1_000
    task
  end

  defp waiter(vault_id, opts \\ []),
    do: Task.async(fn -> SeqGate.with_vault(vault_id, fn -> :ran end, opts) end)

  defp wait_for_waiting(n, tries \\ 100) do
    cond do
      SeqGate.queue_depth().waiting >= n -> :ok
      tries == 0 -> flunk("queue never reached #{n} waiters")
      true -> Process.sleep(10) && wait_for_waiting(n, tries - 1)
    end
  end

  setup do: %{vault_id: Ecto.UUID.generate()}

  test "serializes one vault but not different vaults", %{vault_id: v} do
    holder = hold_gate(v)
    assert SeqGate.with_vault(Ecto.UUID.generate(), fn -> :ran end) == :ran

    w = waiter(v)
    assert Task.yield(w, 100) == nil
    send(holder.pid, :release)
    assert Task.await(w) == :ran
  end

  test "a crashed holder releases the lock", %{vault_id: v} do
    holder = hold_gate(v)
    w = waiter(v)
    assert Task.yield(w, 100) == nil

    Process.unlink(holder.pid)
    Process.exit(holder.pid, :kill)
    assert Task.await(w) == :ran
  end

  test "a raising holder releases the lock", %{vault_id: v} do
    assert_raise RuntimeError, fn -> SeqGate.with_vault(v, fn -> raise "boom" end) end
    assert SeqGate.with_vault(v, fn -> :ran end) == :ran
  end

  # Delta review M1: Busy must be a 429 (the plugin honors retry-after on 429
  # but parks a 503 after 5 tries) and must stay out of Sentry.
  test "a wait timeout sheds with Busy (429, not a Sentry error), nothing left queued",
       %{vault_id: v} do
    holder = hold_gate(v)

    e =
      assert_raise SeqGate.BusyError, fn -> SeqGate.with_vault(v, fn -> :ran end, timeout: 50) end

    assert Plug.Exception.status(e) == 429
    refute Engram.Sentry.EventFilter.server_error?(e)

    send(holder.pid, :release)
    Task.await(holder)
    # Had the timed-out caller stayed queued it would now hold the lock forever.
    assert SeqGate.with_vault(v, fn -> :again end, timeout: 500) == :again
  end

  test "a waiter killed while queued is skipped", %{vault_id: v} do
    holder = hold_gate(v)
    dead = waiter(v)
    wait_for_waiting(1)
    Process.unlink(dead.pid)
    Process.exit(dead.pid, :kill)

    send(holder.pid, :release)
    Task.await(holder)
    assert SeqGate.with_vault(v, fn -> :ran end, timeout: 500) == :ran
  end

  test "nested in-process and in-transaction calls do not wait on the gate", %{vault_id: v} do
    assert SeqGate.with_vault(v, fn -> SeqGate.with_vault(v, fn -> :inner end) end) == :inner

    holder = hold_gate(v)
    {:ok, res} = Engram.Repo.transaction(fn -> SeqGate.with_vault(v, fn -> :ran end) end)
    assert res == :ran
    send(holder.pid, :release)
  end

  # Delta review item 4: a missing or crashed gate must fail closed, not let
  # every queued writer into the DB at once.
  test "a missing gate fails closed with Busy", %{vault_id: v} do
    assert_raise SeqGate.BusyError, fn ->
      SeqGate.with_vault(v, fn -> :ran end, gate: :no_such_gate, timeout: 100)
    end
  end

  test "a crashed partition re-queues its waiters one at a time", %{vault_id: v} do
    holder = hold_gate(v)
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> {0, 0} end)

    waiters =
      for _ <- 1..5 do
        Task.async(fn ->
          SeqGate.with_vault(v, fn ->
            Agent.update(counter, fn {cur, max} -> {cur + 1, max(max, cur + 1)} end)
            Process.sleep(20)
            Agent.update(counter, fn {cur, max} -> {cur - 1, max} end)
          end)
        end)
      end

    wait_for_waiting(5)
    partition = GenServer.whereis({:via, PartitionSupervisor, {SeqGate, v}})
    Process.exit(partition, :kill)

    Task.await_many(waiters, 5_000)
    {_, max_concurrent} = Agent.get(counter, & &1)
    assert max_concurrent == 1, "waiters ran ungated together after the crash"
    send(holder.pid, :release)
    send(parent, :done)
  end

  test "emits acquire (ok/busy) and hold telemetry", %{vault_id: v} do
    me = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      [[:engram, :seq_gate, :acquire], [:engram, :seq_gate, :hold]],
      fn event, m, meta, _ -> if self() == me, do: send(me, {event, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    SeqGate.with_vault(v, fn -> :ok end)
    assert_receive {[:engram, :seq_gate, :acquire], %{duration: _}, %{result: :ok}}
    assert_receive {[:engram, :seq_gate, :hold], %{duration: d}, _} when d >= 0

    holder = hold_gate(v)
    assert_raise SeqGate.BusyError, fn -> SeqGate.with_vault(v, fn -> :ok end, timeout: 20) end
    assert_receive {[:engram, :seq_gate, :acquire], _, %{result: :busy}}
    send(holder.pid, :release)
  end

  test "queue_depth counts held vaults and queued writers on this node", %{vault_id: v} do
    holder = hold_gate(v)
    w = waiter(v)
    wait_for_waiting(1)
    assert %{held: held, waiting: waiting} = SeqGate.queue_depth()
    assert held >= 1 and waiting >= 1
    send(holder.pid, :release)
    Task.await(w)
  end

  # Delta 2 M1: the plugin aborts gated requests at 15s (src/api.ts
  # requestTimeoutMs). A server wait at or above it turns the 429 into a client
  # network error that counts toward parking the write.
  @plugin_request_timeout_ms 15_000
  test "the wait budget stays clearly under the plugin's request timeout" do
    assert SeqGate.wait_ms() <= @plugin_request_timeout_ms - 5_000
  end

  # Channel pushes time out at 10s in both clients (phoenix.js default on the
  # web, `timeoutMs = 10000` in the plugin). A channel write must shed well
  # inside that so the client reads `busy`, not a timeout.
  @channel_push_timeout_ms 10_000
  test "the channel wait budget stays clearly under the push timeout" do
    assert SeqGate.channel_wait_ms() <= @channel_push_timeout_ms - 5_000
  end

  # Delta 2 L1: note upsert runs the CRDT merge in its transaction; gating it
  # serialized merges per vault. Fails if someone re-wraps it.
  test "note upsert does not wait on a held vault gate" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    holder = hold_gate(vault.id)

    task =
      Task.async(fn ->
        Engram.Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "x"},
          actor: "test"
        )
      end)

    assert {:ok, {:ok, _note}} = Task.yield(task, 3_000), "upsert_note queued on the vault gate"
    send(holder.pid, :release)
  end

  # Delta 2 L4: a dead or cancelled waiter leaves the gauge at once, without
  # waiting for the queue to drain past it.
  test "a dead waiter stops counting as waiting immediately", %{vault_id: v} do
    holder = hold_gate(v)
    dead = waiter(v)
    wait_for_waiting(1)
    Process.unlink(dead.pid)
    Process.exit(dead.pid, :kill)
    Process.sleep(20)
    assert SeqGate.queue_depth().waiting == 0
    send(holder.pid, :release)
  end

  test "contended? is true only while writers queue behind the holder", %{vault_id: v} do
    refute SeqGate.contended?(v)
    holder = hold_gate(v)
    refute SeqGate.contended?(v)
    w = waiter(v)
    wait_for_waiting(1)
    assert SeqGate.contended?(v)
    send(holder.pid, :release)
    Task.await(w)
    refute SeqGate.contended?(v)
  end
end
