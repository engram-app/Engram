defmodule Engram.Workers.SettleIndexEntries do
  @moduledoc """
  Retries ONE note's after-transaction settle (`Engram.Notes.settle_index/4`)
  when the inline one failed: a room exit, a DB error, the DEK rotation gate.

  Not projection. Projection converges rows to the index, so after a FAILED
  op whose settle also failed it would move the row to the path the API just
  refused. This job instead brings the entry to the committed row, under the
  same condition as the inline settle: only while the entry is absent, at the
  op's claimed path or at its pre-op path; anything else is another writer's.

  One pending job per note: a later failure merges its paths into it. Paths are
  never in `oban_jobs.args` (`NoPlaintextArgsTest`): the condition compares
  HMACs of the two allowed paths under the user's filter key.
  """
  use Oban.Worker, queue: :crdt_checkpoint, max_attempts: 5

  alias Engram.{Accounts, Crypto, Jobs, Notes, Repo, Vaults}
  alias Engram.Crypto.RotationGate
  alias Engram.Notes.Enqueue

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(1)

  @doc """
  Queues a settle retry for each `{note_id, pre_path, claimed_path}`. A note
  whose retry is already pending (not yet executing) gets this op's two paths
  added to that job's `allowed`, so a second failure is never dropped; an
  executing or absent one gets a new job. Never raises: a failure is logged
  and counted by `Enqueue.enqueue_all/2`, and the entry waits for a later
  settle.
  """
  @spec enqueue(map(), String.t(), [{String.t(), String.t(), String.t()}]) :: :ok
  def enqueue(user, vault_id, entries) do
    _ =
      with {:ok, fk} <- Crypto.dek_filter_key(user) do
        allowed =
          Map.new(entries, fn {id, pre, claimed} -> {id, [hmac(fk, pre), hmac(fk, claimed)]} end)

        allowed
        |> Map.drop(merge_pending(user, allowed))
        |> Enum.map(fn {id, paths} ->
          new(%{user_id: user.id, vault_id: vault_id, note_id: id, allowed: paths})
        end)
        |> Enqueue.enqueue_all("settle_index_entries")
      end

    :ok
  end

  # One statement for every note: append to each pending job's `allowed`, and
  # return the notes it found one for. Pending is `Jobs.pending_states/0`,
  # written in as SQL literals (a parameter would stop the planner matching
  # `oban_jobs_pending_note_id_index`'s partial predicate). The user_id
  # predicate is free and keeps the match to this user. A job that started
  # executing in between is not matched, so its note gets a new job.
  @pending_sql Enum.map_join(Jobs.pending_states(), ", ", &"'#{&1}'")
  @merge_sql """
  UPDATE oban_jobs AS j
     SET args = jsonb_set(j.args, '{allowed}', (j.args -> 'allowed') || v.value)
    FROM jsonb_each($1::jsonb) AS v
   WHERE j.worker = $2
     AND j.state IN (#{@pending_sql})
     AND (j.args ->> 'user_id') = $3
     AND (j.args ->> 'note_id') = v.key
  RETURNING j.args ->> 'note_id'
  """

  defp merge_pending(user, allowed) do
    %{rows: rows} =
      Repo.query!(@merge_sql, [allowed, inspect(__MODULE__), user.id])

    List.flatten(rows)
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
