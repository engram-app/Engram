defmodule Engram.Workers.BackfillCrdtState do
  @moduledoc """
  Seed `notes.crdt_state` from `notes.content` for rows where it is still NULL.

  ## Why this exists

  Migration `20260706210000_clear_crdt_state_id_keying_cutover_migrate` ran
  `UPDATE notes SET crdt_state_ciphertext = NULL, crdt_state_nonce = NULL` for
  EVERY note, on the documented premise that each note would "re-seed cleanly
  from `notes.content` on next bind". `CrdtPersistence.bind/3` did exactly that,
  via `seed_from_content`.

  That seed has been removed: it made the SERVER a third writer of note content,
  which is the shape of the "which copy is authoritative" bug class. But
  removing it strands every note not written since that cutover — such a note now
  binds to an EMPTY doc, and an empty doc is indistinguishable from a note whose
  body the user genuinely deleted.

  `CrdtCheckpoint.ensure_projection_safe/2` stops the empty doc being
  materialized back over the body, so nothing is destroyed on close. But the
  read side is still wrong: the note opens BLANK, and the first character typed
  gives the doc real state, at which point the checkpoint legitimately
  materializes that one character over the whole body.

  So the guard alone is not sufficient — the data has to be repaired. This
  worker is that repair. It is a pure representation backfill: it writes only
  `crdt_state_*`, never `content`, `content_hash`, `version`, or `seq`.

  ## Shape

  Per (user, vault): walks notes whose `crdt_state_ciphertext` is still NULL,
  cursor-batched, re-enqueuing itself until the vault is drained. Mirrors
  `BackfillCrdtHead`.

  Idempotent: the `is_nil(crdt_state_ciphertext)` predicate drops any note
  already seeded, and the UPDATE re-asserts it, so a note that gains state
  mid-run (a concurrent write, a room checkpoint) is never overwritten. That
  matters — re-seeding a live note would discard its CRDT history.

  A NULL-state note with rows in `crdt_update_log` is never seeded (selected
  nor written). Its real state is that un-checkpointed tail, which bind replays
  onto an empty doc; a snapshot seeded from content would be a second,
  unrelated Yjs lineage that bind unions with the tail. Tail replay serves
  those notes, and the next checkpoint writes their state.

  Legacy rows are migrated, not skipped (#1341). `Crypto.encrypt_crdt_state/3`
  binds the AAD to the row id unconditionally while `decrypt_crdt_state/2` picks
  its AAD from the row's `dek_version`, so seeding a `dek_version = 1` row writes
  a ciphertext nothing can read back — and `CrdtPersistence.bind/3` is fail-loud,
  so the note stops opening at all. Skipping is no better: a NULL-state note
  opens blank, which is the very failure above. So the row is rebound in place
  via `AadRebind.rebind_note/2` and then seeded, in one tenant transaction.

  After each seed the note's resident room, if any, is evicted so the next
  bind loads the seeded state. Eviction goes through `:global`, so before each
  seed the job checks it is connected to every node that can host a room
  (`Engram.Cluster.Readiness.rooms_reachable?/1`). The first miss ends the
  batch: the rest of its rows are left for the next pass.

  Driven by the `Engram.DataMigrations.CrdtStateSeed` data migration
  (`enqueue_missing/0`), never by hand.
  """

  # No `unique`: a cursor worker re-enqueues its own successor mid-run, which
  # collides with `:incomplete` uniqueness and would drop the successor, killing
  # the loop after one batch. The is_nil predicate already makes the work
  # idempotent. Same reasoning as BackfillCrdtHead.
  use Oban.Worker, queue: :crypto_backfill, max_attempts: 5

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Backfill.TenantScan
  alias Engram.Cluster.Readiness
  alias Engram.Crypto
  alias Engram.Crypto.AadRebind
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtBridge, CrdtRegistry, CrdtUpdateLog, Note}
  alias Engram.Repo
  alias Engram.Vaults
  alias Engram.Vaults.Vault

  require Logger

  @default_batch_size 100
  @start_cursor "00000000-0000-0000-0000-000000000000"

  # 60 min, the Lifeline `rescue_after` ceiling. This walks every row it
  # owns, and none of the long queues (crypto_backfill/export/cleanup) is
  # user-facing — a slot held here costs nothing, while a kill mid-rotation
  # costs a lot. Finite is the point, not tight. See #1496.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(60)

  # Config-overridable so a test can exercise the cursor re-enqueue loop without
  # inserting @default_batch_size+1 notes. Prod uses the default.
  defp batch_size,
    do: Application.get_env(:engram, :crdt_state_backfill_batch_size, @default_batch_size)

  @doc """
  Enqueue one job per (user, vault) in a live vault holding a seedable note
  (`seedable/0`; the worker discards a deleted vault's jobs). Returns the
  count; zero means nothing the worker could seed is left.
  """
  @spec enqueue_missing() :: non_neg_integer()
  def enqueue_missing do
    # Per-user inside each tenant's RLS context. A single cross-tenant read
    # with `skip_tenant_check: true` returns zero rows on prod under FORCE ROW
    # LEVEL SECURITY and enqueues nothing while reporting success (#1349).
    pairs =
      TenantScan.flat_map_users(fn user_id ->
        from(n in seedable(),
          join: v in Vault,
          on: v.id == n.vault_id and is_nil(v.deleted_at),
          where: n.user_id == ^user_id,
          distinct: true,
          select: n.vault_id
        )
        |> Repo.all()
        |> Enum.map(&{user_id, &1})
      end)

    Enum.each(pairs, fn {user_id, vault_id} ->
      %{"user_id" => user_id, "vault_id" => vault_id, "cursor" => @start_cursor}
      |> __MODULE__.new()
      |> Oban.insert()
    end)

    length(pairs)
  end

  @doc "Notes this worker seeds: live, NULL state, and no un-checkpointed tail."
  @spec seedable() :: Ecto.Query.t()
  def seedable do
    from(n in Note,
      as: :note,
      where: n.kind == "note" and is_nil(n.crdt_state_ciphertext) and is_nil(n.deleted_at),
      where:
        not exists(from(l in CrdtUpdateLog, where: l.note_id == parent_as(:note).id, select: 1))
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id} = args}) do
    cursor = args["cursor"] || @start_cursor

    # Gate DEK-touching work during a per-user rotation window: this worker both
    # decrypts content and encrypts the new state, either of which can
    # transiently fail mid-rotation. Parity with BackfillCrdtHead.
    case RotationGate.check(user_id) do
      {:error, :rotation_in_progress} -> {:snooze, 60}
      {:error, :user_not_found} -> {:discard, :user_deleted}
      :ok -> run(user_id, vault_id, cursor)
    end
  end

  # Every seed evicts the note's resident room (seed_note/2), through `:global`.
  # In a split fleet this job runs on the worker and rooms live on web nodes;
  # partitioned, `terminate_room/1` finds nothing, and an open EMPTY room would
  # survive the seed and start a second lineage on its next edit. So this is
  # checked before EVERY seed, and the first miss ends the batch: nothing more
  # is written and no successor is enqueued. `CrdtStateSeed` stays open and
  # re-enqueues from the start on its next pass. A single node hosts its own
  # rooms and always proceeds.
  defp rooms_reachable?(vault_id) do
    # Test seam only, like HealthController's :cluster_readiness_opts.
    opts = Application.get_env(:engram, :crdt_room_reach_opts, [])

    if Readiness.rooms_reachable?(opts) do
      true
    else
      Logger.warning(
        "crdt_state backfill stopped: CRDT rooms not reachable on every node",
        Metadata.with_category(:warning, :sync, vault_id: vault_id)
      )

      false
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
        from(n in seedable(),
          where: n.vault_id == ^vault.id and n.id > ^cursor,
          order_by: [asc: n.id],
          select: n.id,
          limit: ^limit
        )
        |> Repo.all()
      end)

    finished =
      Enum.reduce_while(ids, true, fn id, true ->
        if rooms_reachable?(vault.id) do
          :ok = seed_note(user, id)
          {:cont, true}
        else
          {:halt, false}
        end
      end)

    # A full batch means more remain — re-enqueue the next cursor. Bind the whole
    # `if` (it yields the insert result or nil) so its value isn't a discarded
    # non-trivial return (:unmatched_returns).
    _ =
      if finished and length(ids) == limit do
        %{"user_id" => user.id, "vault_id" => vault.id, "cursor" => List.last(ids)}
        |> __MODULE__.new()
        |> Oban.insert()
      end

    :ok
  end

  # Never raises: a single unseedable note (undecryptable content, a codec
  # rejection) must not fail the batch and strand every note after it. Log and
  # move on — the note keeps its NULL state and is picked up by a later run.
  defp seed_note(user, note_id) do
    {:ok, result} =
      Repo.with_tenant(user.id, fn ->
        case Repo.get(Note, note_id) do
          %Note{crdt_state_ciphertext: nil} = raw_note ->
            do_seed(user, note_id, raw_note)

          # Either the note was deleted mid-run, or it RACED — gained state
          # between the batch select and here (a concurrent write, a room
          # checkpoint). That state is newer than anything we would derive from
          # content, so leave it.
          _ ->
            :ok
        end
      end)

    # After COMMIT, so a replacement room binds the seeded row. A room bound
    # before the seed holds an EMPTY doc (the row had no state and no tail);
    # left resident, its first edit would append a tail on that empty lineage
    # on top of the seeded snapshot, and the next bind unions the two.
    # terminate_room/1 brutal-kills, skipping the unbind checkpoint, so the
    # empty doc is never written back. Same write-then-evict shape as
    # `EngramWeb.CrdtChannel`'s genesis seed (#1409).
    _ = if result == :seeded, do: CrdtRegistry.terminate_room(note_id)

    :ok
  end

  # #1341. A legacy row cannot simply be seeded: `Crypto.encrypt_crdt_state/3`
  # binds the AAD unconditionally while `decrypt_crdt_state/2` picks its AAD from
  # `dek_version`, so seeding a v1 row writes a snapshot nothing can read back --
  # and `CrdtPersistence.bind/3` is fail-loud, so the note stops opening at all.
  #
  # Skipping the row is not the safe alternative it looks like: a NULL-state note
  # opens BLANK (see the moduledoc), and the first keystroke lets the checkpoint
  # materialize that keystroke over the whole body. So migrate it instead --
  # `AadRebind.rebind_note/2` is the same rebind the operator task performs,
  # fenced on the row still being legacy, and we are already inside this note's
  # tenant transaction so the read and the write cannot race.
  #
  # A row that will not decrypt is left for the operator: `seed_note/2` logs it
  # and moves on, exactly as it does for any other unseedable note.
  defp migrate_legacy_row(user, %Note{} = raw_note) do
    if legacy?(raw_note) do
      do_migrate_legacy_row(user, raw_note)
    else
      {:ok, raw_note}
    end
  end

  defp legacy?(%Note{dek_version: v}) when is_integer(v),
    do: v < Crypto.row_version_aad_bound()

  # Unknown version reads as legacy everywhere else (Crypto.decrypt_aad/3's
  # catch-all, CrdtCheckpoint.legacy_row?/1), so it does here too.
  defp legacy?(_note), do: true

  defp do_migrate_legacy_row(user, %Note{} = raw_note) do
    with {:ok, dek} <- Crypto.get_dek(user),
         :ok <- AadRebind.rebind_note(raw_note, dek) do
      reread(raw_note.id)
    else
      # `:stale` means a concurrent migration won the fence. Re-read: whatever is
      # there now is at least as migrated as what we would have written.
      :stale -> reread(raw_note.id)
      {:error, reason} -> {:error, {:legacy_rebind_failed, reason}}
    end
  end

  # The row can vanish between the rebind and the re-read (vault purge). Return
  # an error tuple, never `{:ok, nil}` — `maybe_decrypt_note_fields/2` has no nil
  # clause, so a nil here would raise a FunctionClauseError straight through
  # `seed_note/2`'s never-raise contract and strand the rest of the vault behind
  # a cursor that never advances.
  defp reread(note_id) do
    case Repo.get(Note, note_id) do
      %Note{} = fresh -> {:ok, fresh}
      nil -> {:error, :note_vanished}
    end
  end

  # Re-asserts `seedable/0` in the UPDATE: the read in seed_note/2 and this
  # write are not atomic, so a note that gained state or a tail in between is
  # left alone. Representation only: content/content_hash/version/seq are
  # untouched. Returns the row count. Caller must be inside the note owner's
  # `Repo.with_tenant/2`. Public only as a test seam for that fence.
  @doc false
  @spec write_seed(Ecto.UUID.t(), binary(), binary()) :: non_neg_integer()
  def write_seed(note_id, ct, nonce) do
    {count, _} =
      Repo.update_all(
        from(n in seedable(), where: n.id == ^note_id),
        set: [crdt_state_ciphertext: ct, crdt_state_nonce: nonce]
      )

    count
  end

  defp do_seed(user, note_id, raw_note) do
    with {:ok, raw_note} <- migrate_legacy_row(user, raw_note),
         {:ok, note} <- Crypto.maybe_decrypt_note_fields(raw_note, user),
         {:ok, %{state: state}} <- CrdtBridge.merge_plaintext(nil, note.content || ""),
         {:ok, {ct, nonce}} <- Crypto.encrypt_crdt_state(state, user, note_id) do
      case write_seed(note_id, ct, nonce) do
        1 -> :seeded
        0 -> :ok
      end
    else
      err ->
        Logger.warning(
          "crdt_state backfill skipped note_id=#{note_id} reason=#{Metadata.safe_reason(err)}",
          Metadata.with_category(:warning, :sync, note_id: note_id)
        )

        :ok
    end
  end
end
