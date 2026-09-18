defmodule Engram.Workers.ReindexKeyword do
  @moduledoc """
  #605 — re-normalize a vault's keyword sparse vectors against its current
  `avgdl`, and backfill notes indexed before the keyword leg existed.

  Recomputes the BM25 TF weight for every chunk (re-decrypt + re-tokenize via
  the normal index path) so length-normalization stays correct as the vault's
  avgdl drifts. Pre-launch this is the manual re-normalizer and the backfill
  tool; AUTOMATIC drift-triggering is deferred (uncalibratable with zero users).

  Clears each note's chunk-reuse markers and index hashes, then re-enqueues it
  through `EmbedNote`, which rebuilds the named dense + keyword vectors in one
  decrypted pass. Both clears are load-bearing — see
  `Engram.Indexing.flag_notes_for_rebuild/1` for why re-enqueuing on its own
  re-normalized nothing (#1477).

  Cost: a full re-embed of the vault — one embed request per note, every chunk
  billed, for a semantic user; zero Voyage spend for a keyword-only one. That is
  the point of a re-normalize, but it is why this is operator-triggered, unique
  per vault, and enqueued at backfill priority.
  """
  # `unique` on vault_id: without it two runs a minute apart each flag the whole
  # vault and re-embed it, because by the second run nothing is pending for
  # `reject_already_queued/2` to catch. That is a doubled Voyage bill with no
  # signal that it happened.
  use Oban.Worker,
    queue: :embed,
    max_attempts: 3,
    unique: [period: 3600, keys: [:vault_id], states: :incomplete]

  import Ecto.Query

  alias Engram.Indexing
  alias Engram.KeywordIndex.Stats
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.EmbedNote

  require Logger

  # `user_id` rides the args because `perform/1` cannot derive it: the `vaults`
  # row that would supply it is under the tenant policy this job needs scoped
  # in the first place.
  @spec enqueue(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, term()}
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  def enqueue(user_id, vault_id) do
    args = %{user_id: to_string(user_id), vault_id: to_string(vault_id)}

    case args |> new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Legacy args: a job enqueued before `user_id` joined them. It cannot be
  # repaired at runtime — deriving the owner needs the `vaults` row, which sits
  # under the same policy that broke this job in the first place. Discard
  # loudly so the operator re-triggers, rather than running unscoped and
  # reporting a success that flagged nothing.
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"vault_id" => vault_id} = args})
      when not is_map_key(args, "user_id") do
    Logger.error(
      "reindex_keyword discarded: job args predate user_id",
      Metadata.with_category(:error, :oban, vault_id: vault_id)
    )

    {:discard, :missing_user_id}
  end

  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id}}) do
    # ONE `with_tenant/2` over the whole body. Two separate things inside need
    # the tenant and both fail silently without it:
    #
    #   * the `notes` select — filtered to `[]`, after which every later step
    #     is a well-behaved no-op on an empty list and the job logs
    #     `total_count: 0`, indistinguishable from "this vault had nothing to
    #     do";
    #   * `Indexing.flag_notes_for_rebuild/1` — its two `update_all`s run under
    #     `Repo.cross_tenant/1`, which suppresses only Engram's app-level
    #     tripwire and sets no Postgres state, so the policy filters those too.
    #
    # `Oban.insert_all` inside the transaction is deliberate: the flagging and
    # the jobs that act on it either both land or neither does.
    Repo.with_tenant!(user_id, fn -> do_reindex(vault_id) end)
  end

  defp do_reindex(vault_id) do
    note_ids =
      from(n in Note,
        where: n.vault_id == ^vault_id and is_nil(n.deleted_at) and n.kind == "note",
        select: n.id
      )
      |> Repo.all()

    # `avgdl` is a per-node ETS cache with a 10-minute TTL
    # (`KeywordIndex.StatsCache`), and `Indexing.prepare_index/3` reads it per
    # note. Without this evict, a re-normalize started inside that window
    # re-encodes every chunk against the SAME stale average it was run to
    # replace — a full Voyage bill producing byte-identical weights, and it
    # looks like success. `Stats.evict/1`'s own docstring names this exact case
    # and had no caller in `lib/` until now.
    #
    # Node-local: `NodeLocalEts` does not sync this table, so on a multi-worker
    # cluster this only covers the node running the job. Today `embed` drains on
    # one worker node, so it is sufficient; if that changes this wants
    # `:sync_evict`.
    :ok = Stats.evict(vault_id)

    # #1477 — re-enqueuing alone was inert for two separate reasons, and
    # `Indexing.flag_notes_for_rebuild/1` documents both. Clearing either marker
    # without the other leaves this worker a silent no-op.
    flagged = Indexing.flag_notes_for_rebuild(note_ids)

    Logger.info(
      "reindex_keyword flagged notes for rebuild",
      Metadata.with_category(:info, :oban, vault_id: vault_id, total_count: flagged)
    )

    # insert_all ignores `unique`, so re-running a reindex over a vault that
    # still has embeds in flight would double every one of them. See
    # EmbedNote.reject_already_queued/2.
    # Backfill priority, not 0. `Indexing.flag_notes_for_rebuild/1` just nulled
    # `embed_hash` on every note here, which is exactly the population
    # `EmbedNote.priority_for/1`
    # rates 9, and a whole vault enqueued at 0 puts every other user's live edit
    # behind it in the shared `embed` queue. The argument to
    # `reject_already_queued/2` matters for the same reason and is not passive:
    # it PROMOTES pending jobs to the priority it is given, so passing 0 would
    # drag unrelated backfill jobs up with it.
    priority = EmbedNote.backfill_priority()

    jobs =
      note_ids
      |> EmbedNote.reject_already_queued(priority)
      |> Enum.map(fn id -> EmbedNote.new(%{note_id: to_string(id)}, priority: priority) end)

    _ = if jobs != [], do: Oban.insert_all(jobs)
    :ok
  end
end
