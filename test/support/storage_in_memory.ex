defmodule Engram.Storage.InMemory do
  @moduledoc """
  ETS-backed in-memory storage adapter for tests.

  Default stub for `Engram.MockStorage` — tests that need to assert on
  storage interactions still use `Mox.expect/3` directly; tests that
  just want a working backend get pass-through behaviour for free.
  """

  @behaviour Engram.Storage

  @table :engram_test_storage_in_memory

  @doc "Lazily ensures the ETS table exists. Idempotent and safe to call concurrently."
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:public, :named_table, :set])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  @impl true
  def put(key, binary, _opts \\ []) do
    ensure_table()
    :ets.insert(@table, {key, binary})
    :ok
  end

  @impl true
  def get(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, binary}] -> {:ok, binary}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete(key) do
    ensure_table()
    :ets.delete(@table, key)
    :ok
  end

  @impl true
  def exists?(key) do
    ensure_table()
    :ets.member(@table, key)
  end

  @impl true
  def delete_prefix(prefix) do
    ensure_table()

    keys =
      :ets.foldl(
        fn {k, _}, acc -> if String.starts_with?(k, prefix), do: [k | acc], else: acc end,
        [],
        @table
      )

    Enum.each(keys, &:ets.delete(@table, &1))
    {:ok, length(keys)}
  end
end
