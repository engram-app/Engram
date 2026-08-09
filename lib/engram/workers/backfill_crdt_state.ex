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

  Legacy rows are passed over (#1341). `Crypto.encrypt_crdt_state/3` binds the
  AAD to the row id unconditionally, but `decrypt_crdt_state/2` picks its AAD
  from the row's `dek_version`, so seeding a `dek_version = 1` row writes a
  ciphertext nothing can read back — and `CrdtPersistence.bind/3` treats an
  unreadable state as fail-loud, so the note stops opening entirely. Run
  `AadRebind` for those users first; the next backfill run then seeds them.
  Every batch logs the count it passed over, so a quiet drain is not mistaken
  for a complete one.

  Enqueue post-deploy via release rpc (no Mix in the release — plain function):

      docker exec engram-saas /app/bin/engram rpc 'Engram.Workers.BackfillCrdtState.enqueue_all()'
  """

  # No `unique`: a cursor worker re-enqueues its own successor mid-run, which
  # collides with `:incomplete` uniqueness and would drop the successor, killing
  # the loop after one batch. The is_nil predicate already makes the work
  # idempotent. Same reasoning as BackfillCrdtHead.
  use Oban.Worker, queue: :crypto_backfill, max_attempts: 5

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtBridge, Note}
  alias Engram.Repo
  alias Engram.Vaults

  require Logger

  @default_batch_size 100
  @start_cursor "00000000-0000-0000-0000-000000000000"

  # Config-overridable so a test can exercise the cursor re-enqueue loop without
  # inserting @default_batch_size+1 notes. Prod uses the default.
  defp batch_size,
    do: Application.get_env(:engram, :crdt_state_backfill_batch_size, @default_batch_size)

  @doc "Enqueue one job per (user, vault) that still has a NULL-crdt_state note. Returns the count."
  @spec enqueue_all() :: non_neg_integer()
  def enqueue_all do
    pairs =
      from(n in Note,
        where:
          n.kind == "note" and is_nil(n.crdt_state_ciphertext) and is_nil(n.deleted_at) and
            n.dek_version >= ^Crypto.row_version_aad_bound(),
        group_by: [n.user_id, n.vault_id],
        select: {n.user_id, n.vault_id}
      )
      |> Repo.all(skip_tenant_check: true)

    Enum.each(pairs, fn {user_id, vault_id} ->
      %{"user_id" => user_id, "vault_id" => vault_id, "cursor" => @start_cursor}
      |> __MODULE__.new()
      |> Oban.insert()
    end)

    length(pairs)
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
              is_nil(n.crdt_state_ciphertext) and is_nil(n.deleted_at) and
              n.dek_version >= ^Crypto.row_version_aad_bound(),
          order_by: [asc: n.id],
          select: n.id,
          limit: ^limit
        )
        |> Repo.all()
      end)

    Enum.each(ids, fn id -> seed_note(user, id) end)

    log_legacy_skipped(user, vault)

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

  # #1341. The batch query passes over legacy (`dek_version = 1`) rows, so the
  # drain can report "done" while notes are still NULL-state. Say so, with the
  # remedy, rather than letting the operator infer completeness from silence.
  # `AadRebind` migrates them; they seed on the run after that.
  defp log_legacy_skipped(user, vault) do
    {:ok, count} =
      Repo.with_tenant(user.id, fn ->
        from(n in Note,
          where:
            n.vault_id == ^vault.id and n.kind == "note" and
              is_nil(n.crdt_state_ciphertext) and is_nil(n.deleted_at) and
              n.dek_version < ^Crypto.row_version_aad_bound(),
          select: count(n.id)
        )
        |> Repo.one()
      end)

    if count > 0 do
      Logger.warning(
        "crdt_state backfill skipped legacy rows vault_id=#{vault.id} count=#{count} " <>
          "remedy=run AadRebind for this user, then re-run the backfill",
        Metadata.with_category(:warning, :sync, vault_id: vault.id)
      )
    end

    :ok
  end

  # Never raises: a single unseedable note (undecryptable content, a codec
  # rejection) must not fail the batch and strand every note after it. Log and
  # move on — the note keeps its NULL state and is picked up by a later run.
  defp seed_note(user, note_id) do
    {:ok, _} =
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

    :ok
  end

  defp do_seed(user, note_id, raw_note) do
    with {:ok, note} <- Crypto.maybe_decrypt_note_fields(raw_note, user),
         {:ok, %{state: state}} <- CrdtBridge.merge_plaintext(nil, note.content || ""),
         {:ok, {ct, nonce}} <- Crypto.encrypt_crdt_state(state, user, note_id) do
      # Re-assert is_nil in the UPDATE: the read above and this write are not
      # atomic, so a note that gained state in between must still be left alone.
      # Representation only — content/content_hash/version/seq are untouched.
      Repo.update_all(
        from(n in Note,
          where: n.id == ^note_id and n.kind == "note" and is_nil(n.crdt_state_ciphertext)
        ),
        set: [crdt_state_ciphertext: ct, crdt_state_nonce: nonce]
      )

      :ok
    else
      err ->
        Logger.warning(
          "crdt_state backfill skipped note_id=#{note_id} reason=#{inspect(err)}",
          Metadata.with_category(:warning, :sync, note_id: note_id)
        )

        :ok
    end
  end
end
