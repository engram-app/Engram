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

  @impl true
  def selfhost?, do: true

  @impl true
  def sign_url(_key, _opts) do
    raise "Engram.Storage.InMemory.sign_url/2 — test stub does not presign"
  end

  @impl true
  def list_user_prefixes do
    ensure_table()

    ids =
      :ets.foldl(
        fn {k, _}, acc ->
          case String.split(k, "/", parts: 2) do
            [user_id_str, _rest] ->
              case Integer.parse(user_id_str) do
                {id, ""} -> [id | acc]
                _ -> acc
              end

            _ ->
              acc
          end
        end,
        [],
        @table
      )

    {:ok, Enum.uniq(ids)}
  end
end
