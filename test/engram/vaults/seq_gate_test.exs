defmodule Engram.Vaults.SeqGateTest do
  use Engram.DataCase, async: false

  alias Engram.Attachments
  alias Engram.Vaults.SeqGate

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
    Mox.stub(Engram.MockStorage, :put, fn _k, _b, _o -> :ok end)

    user = insert(:user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  # Holds the vault's gate (what a long seq-lock holder looks like to waiters)
  # until told to let go.
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

  # RED on main (deletes run straight into the DB and complete while the vault is
  # contended), GREEN with the gate: waiters queue in-BEAM BEFORE
  # Repo.with_tenant, so they hold no pool connection while the seq lock is busy.
  test "50 concurrent single deletes wait outside the DB while the vault is contended", %{
    user: user,
    vault: vault
  } do
    for i <- 1..50 do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "a/#{i}.png",
          "content_base64" => Base.encode64("x")
        })
    end

    holder = hold_gate(vault.id)

    deletes =
      for i <- 1..50 do
        Task.async(fn -> Attachments.delete_attachment(user, vault, "a/#{i}.png") end)
      end

    assert Task.yield_many(deletes, 300) |> Enum.all?(fn {_t, res} -> is_nil(res) end),
           "deletes ran while the vault gate was held (they would hold pool connections)"

    # Unrelated work on the same repo is not starved.
    assert {:ok, _} = Engram.Repo.with_tenant(user.id, fn -> 1 end)

    send(holder.pid, :release)
    assert Enum.all?(Task.await_many(deletes, 10_000), &(&1 == :ok))
    {:ok, metas} = Attachments.list_attachments(user, vault)
    assert metas == []
  end

  test "serializes one vault but not different vaults", %{vault: vault} do
    holder = hold_gate(vault.id)
    other = Ecto.UUID.generate()

    assert :ran = SeqGate.with_vault(other, fn -> :ran end)

    waiter = Task.async(fn -> SeqGate.with_vault(vault.id, fn -> :ran end) end)
    assert Task.yield(waiter, 100) == nil
    send(holder.pid, :release)
    assert Task.await(waiter) == :ran
  end

  test "a crashed holder releases the lock", %{vault: vault} do
    holder = hold_gate(vault.id)
    waiter = Task.async(fn -> SeqGate.with_vault(vault.id, fn -> :ran end) end)
    assert Task.yield(waiter, 100) == nil

    Process.unlink(holder.pid)
    Process.exit(holder.pid, :kill)
    assert Task.await(waiter) == :ran
  end

  test "a wait timeout degrades open and leaves no lock behind", %{vault: vault} do
    holder = hold_gate(vault.id)
    assert SeqGate.with_vault(vault.id, fn -> :ran end, timeout: 50) == :ran
    send(holder.pid, :release)
    Task.await(holder)
    assert SeqGate.with_vault(vault.id, fn -> :again end) == :again
  end
end
