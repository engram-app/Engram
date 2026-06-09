defmodule Engram.IdempotencyTest do
  use ExUnit.Case, async: false
  alias Engram.Idempotency

  setup do
    # Use a fresh table per test so we don't fight start_link/already_started across tests.
    # The Idempotency GenServer is started in the supervision tree at app start
    # for normal runs; in tests we want to verify the basic put/get behavior.
    on_exit(fn -> if :ets.whereis(:engram_idempotency) != :undefined, do: :ets.delete_all_objects(:engram_idempotency) end)
    case Idempotency.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
    :ok
  end

  test "remember/2 stores; lookup/1 returns it" do
    Idempotency.remember("key-1", %{status: 200, body: %{ok: true}})
    assert {:ok, %{status: 200}} = Idempotency.lookup("key-1")
  end

  test "lookup/1 returns :miss for unknown keys" do
    assert :miss = Idempotency.lookup("unknown")
  end

  test "expired entries return :miss" do
    Idempotency.remember("key-2", %{status: 200, body: %{}}, ttl_ms: 0)
    Process.sleep(5)
    assert :miss = Idempotency.lookup("key-2")
  end
end
