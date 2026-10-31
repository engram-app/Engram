defmodule Engram.Vaults.SeqGateTest do
  use Engram.DataCase, async: false

  alias Engram.Vaults.SeqGate

  # Holds the vault's gate from another process until told to let go.
  defp hold_gate(vault_id, opts \\ []) do
    parent = self()

    task =
      Task.async(fn ->
        SeqGate.with_vault(
          vault_id,
          fn ->
            send(parent, :held)
            receive do: (:release -> :ok)
          end,
          opts
        )
      end)

    assert_receive :held, 1_000
    task
  end

  defp waiter(vault_id, opts \\ []),
    do: Task.async(fn -> SeqGate.with_vault(vault_id, fn -> :ran end, opts) end)

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

  # Review M2: degrading open on timeout put every late waiter back on a pool
  # connection. It must shed instead, and leave no queued entry behind.
  test "a wait timeout sheds with Busy (503) and leaves nothing queued", %{vault_id: v} do
    holder = hold_gate(v)

    e = assert_raise SeqGate.Busy, fn -> SeqGate.with_vault(v, fn -> :ran end, timeout: 50) end
    assert Plug.Exception.status(e) == 503

    send(holder.pid, :release)
    Task.await(holder)
    # Had the timed-out caller stayed queued it would now hold the lock forever.
    assert SeqGate.with_vault(v, fn -> :again end, timeout: 500) == :again
  end

  test "a waiter killed while queued is skipped", %{vault_id: v} do
    holder = hold_gate(v)
    dead = waiter(v)
    Process.sleep(20)
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

  test "a missing gate runs ungated", %{vault_id: v} do
    assert SeqGate.with_vault(v, fn -> :ran end, gate: :no_such_gate) == :ran
  end
end
