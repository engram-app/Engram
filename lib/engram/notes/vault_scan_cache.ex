defmodule Engram.Notes.VaultScanCache do
  @moduledoc """
  Whole-vault aggregates (tag list, type list, folder counts) keyed on the
  vault's `change_seq`.

  These reads group or decrypt every live row of a vault, while their answer
  only moves when a note row does, and every such write takes a new seq from
  `vaults.change_seq` (`Vaults.next_seq!/1`) in its own transaction: the
  invariant the sync feed and the vault tree's ETag already rely on. Writes
  that skip it (DEK rotation, AAD rebind, embed stamps) leave every plaintext
  these aggregates show unchanged. So the key is the freshness: a write moves
  readers to a new key on every node at once, with no eviction to lose.

  `read/4` reads the seq BEFORE the rows. Under READ COMMITTED each statement
  sees every commit before it started, so the rows are at least as new as the
  seq they are stored under, never older.

  Values are decrypted plaintext in node memory, like the `:vaults` cache.
  """

  alias Engram.Cache
  alias Engram.Repo
  alias Engram.Vaults

  @cache :vault_scan

  @doc """
  The aggregate `what` for `vault`. Inside one tenant transaction: the seq,
  then on a miss `raw.()` (the DB read). `finish.(rows)` runs after commit
  (decrypt and shape, CPU work that must not hold a connection), and its
  result is cached under the seq.
  """
  @spec read(map(), map(), atom(), (-> term()), (term() -> term())) :: term()
  def read(user, vault, what, raw, finish) do
    {seq, found} =
      Repo.with_tenant!(user.id, fn ->
        seq = Vaults.raw_current_seq(vault.id)

        case get(vault.id, seq, what) do
          {:ok, value} -> {seq, {:hit, value}}
          :miss -> {seq, {:rows, raw.()}}
        end
      end)

    case found do
      {:hit, value} ->
        value

      {:rows, rows} ->
        value = finish.(rows)
        put(vault.id, seq, what, value)
        value
    end
  end

  @doc "A cached aggregate, for a caller that read `seq` in its own transaction."
  @spec get(Ecto.UUID.t(), integer(), atom()) :: {:ok, term()} | :miss
  def get(vault_id, seq, what), do: Cache.get(@cache, {vault_id, seq, what})

  @doc """
  Store an aggregate computed from rows read at or after `seq`. Waits for the
  caller's transaction to commit (immediate outside one): inside a write
  transaction the seq and rows include its own uncommitted write, and a
  rollback hands that seq to the next writer with different rows.
  """
  @spec put(Ecto.UUID.t(), integer(), atom(), term()) :: :ok
  def put(vault_id, seq, what, value),
    do: Repo.after_commit(fn -> Cache.put(@cache, {vault_id, seq, what}, value) end)
end
