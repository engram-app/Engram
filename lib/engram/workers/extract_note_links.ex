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

  alias Engram.Accounts
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Logger.DecryptFailure
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"note_id" => note_id}}) do
    case Engram.Notes.fetch_note_for_worker(note_id) do
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
        case Crypto.maybe_decrypt_note_fields(note, user) do
          {:ok, decrypted} ->
            :ok =
              Links.replace_links(user, vault, note.id, Parser.extract(decrypted.content || ""))

            :ok

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
  Leading-edge debounced job (~2s, `LINK_EXTRACT_DELAY_SECONDS` via app env).
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
end
