defmodule Engram.Workers.ExtractNoteLinks do
  @moduledoc """
  Oban worker: prompt `[[wikilink]]`/`![[embed]]` edge extraction, split off
  the embed pipeline (#648 latency pair, lever 1).

  Historically `note_links` rows were written only inside the indexing pass
  (`Indexing.index_note/2`), which rides EmbedNote's 30s trailing debounce and
  the Voyage budget gate — so a rename inside that window found no referrer
  edge and fell back to the +60s sweep. This job runs the cheap half only
  (regex parse + HMAC resolve + delete/insert; NO embedding, NO Qdrant) within
  ~#{2}s of content landing server-side. The embed pipeline is untouched and
  still re-runs `replace_links` later — that duplicate is idempotent, and
  `replace_links`' per-note advisory lock serializes the two writers.

  Leading-edge debounce: `new_debounced/1` schedules ~2s out and dedups per
  note over `[:available, :scheduled]` ONLY. The job reads CURRENT content at
  run time, so edits landing inside the window are covered by the pending run;
  an edit during an `:executing` run inserts a fresh job (states deliberately
  exclude `:executing`/`:retryable`). No trailing `replace:` — first-edit
  latency is the product requirement, and a run always extracts the newest
  content anyway, so there is nothing for a trailing reschedule to improve.

  Bulk callers (batch upsert) enqueue via `Oban.insert_all`, which ignores
  `unique` — duplicate jobs for one note converge (idempotent, serialized).
  Callers that want the debounce/coalescing guarantee MUST go through
  `new_debounced/1` — the `unique` opt lives only there, not on the `use`
  opts below, so a raw `new/1` call enqueues without dedup.

  `unique` is set per-call in `new_debounced/1`, not in the `use` opts below:
  Oban's compile-time linter (`Oban.Worker.__after_compile__/2`) unconditionally
  warns whenever a static `unique: [states: ...]` omits any of its `:incomplete`
  group (`suspended/available/scheduled/executing/retryable`) — which is exactly
  what excluding `:executing` (the whole point above) does, and there's no
  library escape hatch for that warning. Passing `unique:` as a `new/2` call-time
  opt (an officially documented pattern, see `Oban.Job.new/2` docs) carries the
  same runtime semantics without tripping that check — `--warnings-as-errors`
  gates `mix compile` in CI (`.github/workflows/verify.yml`).

  T3.2: args carry the note id only.
  """
  use Oban.Worker,
    queue: :indexing,
    max_attempts: 3

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Links
  alias Engram.Links.NoteLink
  alias Engram.Links.Parser
  alias Engram.Logger.DecryptFailure
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault
  alias Engram.Workers.RewriteNoteLinks

  @repair_window_seconds 600
  @start_cursor "00000000-0000-0000-0000-000000000000"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case Engram.Notes.fetch_note_for_worker(args["note_id"]) do
      {:discard, _reason} = discard ->
        discard

      {:ok, %Note{} = note} ->
        case RotationGate.check(note.user_id) do
          {:error, :rotation_in_progress} -> {:snooze, 60}
          {:error, :user_not_found} -> {:discard, :user_deleted}
          :ok -> extract(note)
        end
    end
  end

  defp extract(note) do
    user = Accounts.get_user!(note.user_id)

    # Missing vault = orphaned note (same rule as EmbedNote): nothing to do.
    case Repo.get(Vault, note.vault_id, skip_tenant_check: true) do
      nil ->
        {:discard, "vault #{note.vault_id} not found for note #{note.id}"}

      %Vault{} = vault ->
        # notes.content is the REST/search FACADE — since #1141 it's only
        # materialized from the CRDT doc at checkpoint, so it lags a live doc
        # write (same staleness class as #1159, see
        # `Engram.Notes.authoritative_content/2` moduledoc and
        # `NotesController.append/2`). A rewrite's `Rewriter.finish/4` writes
        # the correct edges immediately via the CRDT-projected content but
        # (deliberately) does not materialize the facade — reading it here
        # would re-derive stale edges on the very next extraction and clobber
        # what the rewrite just fixed. Decrypt first (still needed to recover
        # a legacy/no-crdt-state row's plaintext as the fallback base), then
        # resolve through the authority.
        with {:ok, decrypted} <- Crypto.maybe_decrypt_note_fields(note, user),
             {:ok, content} <- Engram.Notes.authoritative_content(user, decrypted) do
          :ok = Links.replace_links(user, vault, note.id, Parser.extract(content || ""))
          :ok = repair_rename_danglers(user, vault, note.id)
          :ok
        else
          {:error, reason} ->
            DecryptFailure.log("extract_links_decrypt_failed", reason,
              user_id: note.user_id,
              note_id: note.id
            )

            {:error, reason}
        end
    end
  end

  @doc """
  Leading-edge debounced job (~2s, `:link_extract_delay_seconds` app env key).
  """
  @spec new_debounced(binary()) :: Ecto.Changeset.t()
  def new_debounced(note_id) do
    new(%{note_id: note_id},
      schedule_in: extract_delay_seconds(),
      unique: [period: 60, keys: [:note_id], states: [:available, :scheduled]]
    )
  end

  defp extract_delay_seconds,
    do: Application.get_env(:engram, :link_extract_delay_seconds, 2)

  # #648 lever 2 — bind-time rename repair. A freshly-extracted edge that
  # lands DANGLING may be explained by a recent rename: the referrer's edge
  # simply didn't exist when RewriteNoteLinks walked (and, for arrivals later
  # than rename+60s, when its sweep re-walked). The durable evidence for
  # every rewriting rename origin (REST tombstone-backed, CRDT
  # ciphertext-backed, folder cascade, attachment move) is the original
  # oban_jobs row — retained 7 days by the Pruner, args already in the exact
  # T3.2 shape (ids + b64 HMACs/ciphertext). Re-enqueue those args verbatim
  # with the cursor reset and "sweep" => true:
  #   * "sweep" => true makes the repair chain terminate WITHOUT enqueueing
  #     another sweep (RewriteNoteLinks.maybe_enqueue_sweep/1) — one walk.
  #   * insert-time unique on [target_id, old_basename_hmac] over
  #     available/scheduled collapses concurrent repairs AND defers to the
  #     rename's own still-pending sweep (identical work, already scheduled).
  #     Chain successors insert via plain new/1 and are unaffected — this is
  #     a single-shot entry, not the self-re-enqueueing cursor-chain case the
  #     worker's no-unique rule exists for.
  # Loop-safety: a repair rewrite changes content → re-extraction produces
  # edges under the NEW basename hmac → no window match → terminates. A no-op
  # rewrite persists nothing → no re-extraction → no re-trigger.
  # Plugin/Obsidian-origin renames never enqueued a rewrite (one-rewriter
  # invariant) → no evidence row → correctly never repaired here.
  defp repair_rename_danglers(user, vault, source_note_id) do
    dangling_hmacs =
      Repo.all(
        from(l in NoteLink,
          where:
            l.source_note_id == ^source_note_id and l.user_id == ^user.id and
              l.vault_id == ^vault.id and is_nil(l.target_note_id) and
              is_nil(l.target_attachment_id),
          distinct: true,
          select: l.target_basename_hmac
        ),
        skip_tenant_check: true
      )

    Enum.each(dangling_hmacs, fn hmac ->
      case recent_rename_job_args(user.id, vault.id, Base.encode64(hmac)) do
        nil -> :ok
        args -> enqueue_repair(args)
      end
    end)

    :ok
  end

  # Newest rewrite-job row (ANY state — completed included) inside the window
  # whose old_basename_hmac matches the dangler. oban_jobs is not a tenant
  # table; user/vault are filtered as args. JSONB ->> precedent:
  # EmbedNote.existing_burst_start/1.
  defp recent_rename_job_args(user_id, vault_id, hmac_b64) do
    cutoff = DateTime.add(DateTime.utc_now(), -@repair_window_seconds, :second)

    Repo.one(
      from(j in Oban.Job,
        where: j.worker == "Engram.Workers.RewriteNoteLinks",
        where: j.inserted_at > ^cutoff,
        where: fragment("? ->> 'old_basename_hmac' = ?", j.args, ^hmac_b64),
        where: fragment("? ->> 'user_id' = ?", j.args, ^to_string(user_id)),
        where: fragment("? ->> 'vault_id' = ?", j.args, ^to_string(vault_id)),
        order_by: [desc: j.inserted_at],
        limit: 1,
        select: j.args
      )
    )
  end

  defp enqueue_repair(args) do
    :telemetry.execute([:engram, :links, :repair_enqueued], %{count: 1}, %{origin: :extract})

    args
    |> Map.put("cursor", @start_cursor)
    |> Map.put("sweep", true)
    |> RewriteNoteLinks.new(
      unique: [
        period: @repair_window_seconds,
        keys: [:target_id, :old_basename_hmac],
        states: [:available, :scheduled]
      ]
    )
    |> Engram.Notes.Enqueue.enqueue("rewrite_note_links")
  end
end
