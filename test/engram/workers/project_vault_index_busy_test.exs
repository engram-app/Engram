defmodule Engram.Workers.ProjectVaultIndexBusyTest do
  @moduledoc """
  Delta 2 L2: the projection snoozes on a contended vault gate BEFORE the
  snapshot decrypt, and gives up once the job is old, because Oban's snooze
  decrements `attempt` and `max_attempts` never caps it.
  """
  use Engram.DataCase, async: false

  alias Engram.Vaults.SeqGate
  alias Engram.Workers.ProjectVaultIndex

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)
    parent = self()

    # Holder plus one queued waiter: the gate is contended.
    holder =
      Task.async(fn ->
        SeqGate.with_vault(vault.id, fn ->
          send(parent, :held)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :held
    waiter = Task.async(fn -> SeqGate.with_vault(vault.id, fn -> :ok end) end)
    wait_contended(vault.id)

    on_exit(fn -> send(holder.pid, :release) end)
    %{user: user, vault: vault, holder: holder, waiter: waiter}
  end

  defp wait_contended(v, tries \\ 100) do
    cond do
      SeqGate.contended?(v) -> :ok
      tries == 0 -> flunk("gate never contended")
      true -> Process.sleep(10) && wait_contended(v, tries - 1)
    end
  end

  defp job(ctx, inserted_at) do
    %Oban.Job{
      args: %{"user_id" => ctx.user.id, "vault_id" => ctx.vault.id},
      inserted_at: inserted_at
    }
  end

  test "snoozes without projecting while the gate is contended", ctx do
    assert {:snooze, 5} = ProjectVaultIndex.perform(job(ctx, DateTime.utc_now()))
  end

  test "gives up with an error once the job is past the give-up age", ctx do
    old = DateTime.add(DateTime.utc_now(), -601, :second)
    assert {:error, :vault_write_queue_saturated} = ProjectVaultIndex.perform(job(ctx, old))
  end
end
