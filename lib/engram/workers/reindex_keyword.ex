defmodule Engram.Workers.ReindexKeyword do
  @moduledoc """
  #605 — re-normalize a vault's keyword sparse vectors against its current
  `avgdl`, and backfill notes indexed before the keyword leg existed.

  Recomputes the BM25 TF weight for every chunk (re-decrypt + re-tokenize via
  the normal index path) so length-normalization stays correct as the vault's
  avgdl drifts. Pre-launch this is the manual re-normalizer and the backfill
  tool; AUTOMATIC drift-triggering is deferred (uncalibratable with zero users).

  Scaffold: re-enqueues each of the vault's notes through `EmbedNote`, which
  rebuilds the named dense + keyword vectors in one decrypted pass.
  """
  use Oban.Worker, queue: :embed, max_attempts: 3

  import Ecto.Query

  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.EmbedNote

  @spec enqueue(Ecto.UUID.t()) :: :ok | {:error, term()}
  def enqueue(vault_id) do
    case %{vault_id: to_string(vault_id)} |> new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"vault_id" => vault_id}}) do
    note_ids =
      from(n in Note,
        where: n.vault_id == ^vault_id and is_nil(n.deleted_at) and n.kind == "note",
        select: n.id
      )
      |> Repo.all(skip_tenant_check: true)

    jobs = Enum.map(note_ids, fn id -> EmbedNote.new(%{note_id: to_string(id)}) end)
    _ = Oban.insert_all(jobs)
    :ok
  end
end
