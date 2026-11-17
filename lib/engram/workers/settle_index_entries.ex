defmodule Engram.Workers.SettleIndexEntries do
  @moduledoc """
  Retries ONE note's after-transaction settle (`Engram.Notes.settle_index/4`)
  when the inline one failed: a room exit, a DB error, the DEK rotation gate.

  Not projection. Projection converges rows to the index, so after a FAILED
  op whose settle also failed it would move the row to the path the API just
  refused. This job instead brings the entry to the committed row, under the
  same condition as the inline settle: only while the entry is absent, at the
  op's claimed path or at its pre-op path; anything else is another writer's.

  One job per note, deduplicated against pending ones
  (`Engram.Jobs.reject_pending/3`, on the indexed `note_id` arg). Paths are
  never in `oban_jobs.args` (`NoPlaintextArgsTest`): the condition compares
  HMACs of the two allowed paths under the user's filter key.
  """
  use Oban.Worker, queue: :crdt_checkpoint, max_attempts: 5

  alias Engram.{Accounts, Crypto, Jobs, Notes, Vaults}
  alias Engram.Crypto.RotationGate
  alias Engram.Notes.Enqueue

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(1)

  @doc """
  Queues a settle retry for each `{note_id, pre_path, claimed_path}` without
  one pending. Never raises: a failure is logged and counted by
  `Enqueue.enqueue_all/2`, and the entry then waits for a later settle.
  """
  @spec enqueue(map(), String.t(), [{String.t(), String.t(), String.t()}]) :: :ok
  def enqueue(user, vault_id, entries) do
    with {:ok, fk} <- Crypto.dek_filter_key(user) do
      pending = MapSet.new(Jobs.reject_pending(__MODULE__, Enum.map(entries, &elem(&1, 0))))

      entries
      |> Enum.filter(&MapSet.member?(pending, elem(&1, 0)))
      |> Enum.map(fn {id, pre, claimed} ->
        new(%{
          user_id: user.id,
          vault_id: vault_id,
          note_id: id,
          allowed: [hmac(fk, pre), hmac(fk, claimed)]
        })
      end)
      |> Enqueue.enqueue_all("settle_index_entries")
    end

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id} = args}) do
    with %{} = user <- Accounts.get_user(user_id),
         :ok <- RotationGate.check(user.id),
         {:ok, vault} <- Vaults.get_vault(user, vault_id),
         {:ok, fk} <- Crypto.dek_filter_key(user) do
      allowed = args["allowed"]
      note_id = args["note_id"]

      Notes.settle_index(user, vault, [note_id], fn _id, path ->
        hmac(fk, path) in allowed
      end)
    else
      {:error, :rotation_in_progress} -> {:snooze, 30}
      # User or vault gone: its index went with it.
      _ -> :ok
    end
  end

  defp hmac(fk, path), do: fk |> Crypto.hmac_field(path) |> Base.encode64()
end
