defmodule Engram.Workers.BackfillCrdtHead do
  @moduledoc """
  Warm the `notes.crdt_head` column so the sync manifest
  (`SyncController.manifest`) serves a real head marker per note instead of
  `nil`. The manifest passes `crdt_head` through as-is (a NULL flows as `nil`),
  so a cold client can only diff its per-note heads once the column is
  populated; this worker fills NULLs off the request path.

  Per (user, vault): walks notes whose `crdt_head` is still NULL, rebuilds each
  doc ONCE via `CrdtTransport.backfill_head/3` (which persists the computed
  head), cursor-batched, re-enqueuing itself until the vault is drained.

  Idempotent: the `is_nil(crdt_head)` predicate drops any note already set (by
  `update_v1` or a prior batch), so a retry or a second `enqueue_all/0` never
  re-rebuilds a note.

  Enqueued hourly by `Engram.Workers.WarmCrdtHeads`, and per user after a DEK
  rotation or an envelope re-encode (`enqueue_user/1`), never by hand.
  """

  # No `unique`: a cursor worker re-enqueues its own successor mid-run, which
  # collides with `:incomplete` uniqueness (the running job counts) and would
  # drop the successor, killing the loop after one batch. The `is_nil(crdt_head)`
  # filter already makes the work idempotent, so a duplicate enqueue_all just
  # does converging, harmless re-scans. The hourly `WarmCrdtHeads` cron skips
  # its enqueue while any job of this worker is in flight.
  use Oban.Worker, queue: :crdt_backfill, max_attempts: 5

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Backfill.IdWindows
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto.RotationGate
  alias Engram.Jobs
  alias Engram.Maintenance.Cursor
  alias Engram.Notes.{CrdtTransport, Note, NoteBody}
  alias Engram.Repo
  alias Engram.Vaults
  alias Engram.Vaults.Vault

  @default_batch_size 100
  # NULL-head notes examined per hourly run (see `enqueue_all/0`).
  @candidate_cap 5_000
  @cursor "warm_crdt_heads"
  @start_cursor "00000000-0000-0000-0000-000000000000"

  # 60 min, the Lifeline `rescue_after` ceiling. This walks every row it
  # owns, and none of the long queues (crdt_backfill/export/cleanup) is
  # user-facing — a slot held here costs nothing, while a kill mid-rotation
  # costs a lot. Finite is the point, not tight. See #1496.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(60)

  # Config-overridable so a test can exercise the cursor re-enqueue loop without
  # inserting @default_batch_size+1 notes. Prod uses the default.
  defp batch_size,
    do: Application.get_env(:engram, :crdt_head_backfill_batch_size, @default_batch_size)

  @doc """
  Enqueue one job per (user, vault) in a live vault that still has a
  NULL-crdt_head note (the worker discards a deleted vault's jobs). Returns
  the count. Run hourly by `Engram.Workers.WarmCrdtHeads`.
  """
  @spec enqueue_all() :: non_neg_integer()
  def enqueue_all do
    # Candidates, with no index on the head (a partial index on
    # `crdt_head IS NULL` makes every CRDT append, which clears the head, and
    # every warm a non-HOT body write; `NoteBodyReadTest` guards that):
    #   * recent: notes written since the last run, from the sync change
    #     sequence (`Engram.Maintenance.ChangeFeed`, index reads only); a
    #     checkpoint that changes the note takes a seq. Heads re-checked by
    #     primary key in `live_pairs/1`.
    #   * backstop: the next `candidate_cap/0` body rows in key order from a
    #     persisted cursor (`Engram.Maintenance.Cursor`), wrapping at the end:
    #     bounded rows per run, and the whole table every N/cap hours.
    # Not the hourly walk of every `notes` row (Job Load Audit 2026-11-03:
    # 2.7 GB). `TenantScan.all/2`: the maintenance pool on SaaS, per tenant
    # elsewhere (never a cross-tenant read on the app pool, #1349).
    cap = candidate_cap()

    from = Cursor.get(@cursor)

    window =
      cap
      |> null_head_query(from && {from["user_id"], from["note_id"]})
      |> TenantScan.all()
      |> Enum.sort_by(&{&1.user_id, &1.note_id})
      |> Enum.take(cap)

    last = List.last(window)

    :ok =
      Cursor.advance(
        @cursor,
        last && %{"user_id" => last.user_id, "note_id" => last.note_id},
        length(window),
        cap
      )

    {changed, commit} = Engram.Maintenance.ChangeFeed.changed("warm_crdt_heads:feed")
    recent = for n <- changed, do: %{user_id: n.user_id, note_id: n.id}

    candidates = Enum.uniq(Enum.filter(window, & &1.null?) ++ recent)

    pairs = live_pairs(candidates)

    # No `unique` on this worker, so bulk insert drops nothing a single one
    # deduped (#2169: one hourly tick must not be one insert per vault).
    count =
      pairs
      |> Enum.map(fn {user_id, vault_id} ->
        __MODULE__.new(%{"user_id" => user_id, "vault_id" => vault_id, "cursor" => @start_cursor})
      end)
      |> Jobs.insert_chunked()

    # The feed moves only once its candidates are queued.
    :ok = commit.()
    count
  end

  @doc false
  # The next `cap` body rows in key order, flagged when the head is NULL.
  # Public so the plan test pins the primary key.
  def null_head_query(cap, after_key \\ nil) do
    from(b in NoteBody,
      order_by: [b.user_id, b.note_id],
      select: %{user_id: b.user_id, note_id: b.note_id, null?: is_nil(b.crdt_head)},
      limit: ^cap
    )
    |> after_key(after_key)
  end

  defp after_key(query, nil), do: query

  defp after_key(query, {user_id, note_id}) do
    where(
      query,
      [b],
      fragment(
        "(?, ?) > (?::uuid, ?::uuid)",
        b.user_id,
        b.note_id,
        type(^user_id, Ecto.UUID),
        type(^note_id, Ecto.UUID)
      )
    )
  end

  defp candidate_cap,
    do: Application.get_env(:engram, :crdt_head_candidate_cap, @candidate_cap)

  # The live (user, vault) pairs of those notes: one primary-key probe per note.
  defp live_pairs([]), do: []

  defp live_pairs(candidates) do
    # The head re-check reads `note_bodies` (the copy the R8 contract keeps),
    # not `notes.crdt_head`. The candidates are read by primary key
    # (`IdWindows.by_id/2`): an `id IN` list lets the planner walk a
    # user-leading index instead (#2403).
    query = fn ids ->
      from(n in Note,
        join: b in NoteBody,
        on: b.note_id == n.id and b.user_id == n.user_id,
        join: v in Vault,
        on: v.id == n.vault_id and is_nil(v.deleted_at),
        where: n.kind == "note" and is_nil(b.crdt_head) and is_nil(n.deleted_at),
        distinct: true,
        select: {n.user_id, n.vault_id}
      )
      |> IdWindows.by_id(ids)
    end

    case TenantScan.pool() do
      {:fleet, repo} ->
        repo.all(query.(Enum.map(candidates, & &1.note_id)))

      # Per tenant: each user's own candidates only, never every id per user.
      :per_user ->
        candidates
        |> Enum.group_by(& &1.user_id, & &1.note_id)
        |> Enum.flat_map(fn {user_id, ids} ->
          Repo.with_tenant!(user_id, fn -> Repo.all(query.(ids)) end)
        end)
    end
    |> Enum.uniq()
  end

  @doc """
  Enqueue one job per vault of `user_id`, right after a sweep that rewrote
  every `crdt_state_ciphertext` (DEK rotation, envelope re-encode), so the
  heads the trigger NULLed do not wait for the hourly run.
  """
  @spec enqueue_user(Ecto.UUID.t()) :: :ok
  def enqueue_user(user_id) do
    # `vaults` is RLS-scoped, so an unscoped read returns [] and silently
    # enqueues nothing. The inserts stay OUTSIDE the tenant scope: `oban_jobs`
    # has no RLS, and `with_tenant/2` drops the connection to `engram_app`.
    {:ok, vault_ids} =
      Repo.with_tenant(user_id, fn ->
        from(v in Vault, where: v.user_id == ^user_id, select: v.id)
        |> Repo.all(skip_tenant_check: true)
      end)

    vault_ids
    |> Enum.map(&__MODULE__.new(%{"user_id" => user_id, "vault_id" => &1}))
    |> Jobs.insert_chunked()

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id} = args}) do
    cursor = args["cursor"] || @start_cursor

    # Gate DEK-touching work during a per-user rotation window (parity with
    # the other DEK-touching workers): backfill_head -> load_doc decrypts crdt_state,
    # which can transiently fail mid-rotation. crdt_head itself is rotation-
    # invariant (a hash of plaintext clock counts), so this is quiet-during-
    # rotation, not a correctness gate.
    case RotationGate.check(user_id) do
      {:error, :rotation_in_progress} -> {:snooze, 60}
      {:error, :user_not_found} -> {:discard, :user_deleted}
      :ok -> run(user_id, vault_id, cursor)
    end
  end

  defp run(user_id, vault_id, cursor) do
    case Accounts.get_user(user_id) do
      nil ->
        {:discard, :user_deleted}

      user ->
        case Vaults.get_vault(user, vault_id) do
          {:ok, vault} -> backfill_batch(user, vault, cursor)
          {:error, :not_found} -> {:discard, :vault_deleted}
        end
    end
  end

  defp backfill_batch(user, vault, cursor) do
    limit = batch_size()

    {:ok, ids} =
      Repo.with_tenant(user.id, fn ->
        from(n in Note,
          where:
            n.vault_id == ^vault.id and n.kind == "note" and n.id > ^cursor and
              is_nil(n.crdt_head) and is_nil(n.deleted_at),
          order_by: [asc: n.id],
          select: n.id,
          limit: ^limit
        )
        |> Repo.all()
      end)

    # backfill_head/3 manages its own tenant scoping (load_doc + store_head), so
    # it is called outside the batch-select transaction, once per note.
    Enum.each(ids, fn id -> CrdtTransport.backfill_head(user, vault, id) end)

    # A full batch means more remain — re-enqueue the next cursor. Bind the whole
    # `if` (it yields the insert result or nil) so its value isn't a discarded
    # non-trivial return (:unmatched_returns).
    _ =
      if length(ids) == limit do
        %{"user_id" => user.id, "vault_id" => vault.id, "cursor" => List.last(ids)}
        |> __MODULE__.new()
        |> Oban.insert()
      end

    :ok
  end
end
