defmodule Engram.Workers.RefreshKeywordVectors do
  @moduledoc """
  Oban worker: rebuild one note's keyword (sparse) vectors in place via
  `Indexing.resparse_note/2`. No embedder call and no Voyage spend. Enqueued
  per note by `ReconcileEmbeddings` after a tokenizer change.

  Reads the same decrypted `notes.content` facade the embed pipeline indexed
  from, so its chunks fingerprint-match the stored points.

  Also enqueued by `ReconcileEmbeddings` for every note whose
  `keyword_version` is behind the target (`Engram.Rebuild.target_versions/0`), so a keyword
  encoding change heals itself with no operator step. Success stamps the
  version.

  Named apart from its predecessor `ResparseNote` on purpose: during a rolling
  deploy, nodes on the previous release share the `embed` queue, and their
  `ResparseNote` still re-embedded unmatched notes. A worker name they do not
  have makes them fail the job harmlessly instead of billing Voyage.

  It never re-embeds. Points it cannot match keep their old keyword vector:
  on a stale `chunker_version` the chunker rebuild owns them, on a current
  one the next edit does. The note is stamped either way, so the sweep does
  not re-select it every backoff window; see
  `docs/context/index-version-self-heal.md`.

  Paced by `Engram.Rebuild.qdrant_pace/1` in every mode: a keyword bump
  rewrites every point in place, and each rewrite leaves a dead copy until
  the optimizer vacuums the segment, so an unpaced sweep can fill the disk
  into strict mode's write refusal. A gated job snoozes, longer each time it
  is gated again (`Engram.Rebuild.gate_snooze/1`); no Voyage cost, so no
  token bucket.

  ## Kill switch

  `:keyword_refresh` (runtime override; else env `KEYWORD_REFRESH`, default
  true) set to false stops the
  sweep queueing and makes every queued job snooze 300 s before any
  Qdrant call. Back on, the snoozed jobs and the next sweep resume with no
  operator step. A user's edit (`EmbedNote`) never reads it. See
  `docs/context/index-version-self-heal.md`.
  """
  use Oban.Worker,
    queue: :embed,
    max_attempts: 5,
    unique: [period: 3600, keys: [:note_id], states: [:available, :scheduled]]

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Indexing
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vector.Qdrant
  alias Engram.Workers.BackgroundPriority

  require Logger

  # Long, so a paused backlog of thousands is a few wakeups a second fleet-wide,
  # not hundreds; still short enough that "back on" resumes within minutes.
  @paused_snooze 300

  @doc "False while the `:keyword_refresh` kill switch is off."
  @spec enabled?() :: boolean()
  def enabled?, do: Engram.ServiceConfig.get(:keyword_refresh, true) != false

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    :ok = BackgroundPriority.demote()

    with :ok <- if(enabled?(), do: :ok, else: {:snooze, @paused_snooze}),
         :ok <- Engram.Rebuild.qdrant_pace(job),
         {:ok, note} <- Engram.Notes.fetch_note_for_worker_job(args),
         :ok <- RotationGate.check(note.user_id),
         user = Engram.Accounts.get_user!(note.user_id),
         {:ok, note} <- Crypto.maybe_decrypt_note_fields(note, user),
         {:ok, _updated, unmatched} <- Indexing.resparse_note(note, user) do
      if unmatched > 0, do: log_unmatched(note, unmatched)
      stamp_keyword_version(note)
    else
      {:snooze, _} = snooze -> snooze
      {:discard, _} = discard -> discard
      {:error, :rotation_in_progress} -> {:snooze, 60}
      {:error, :qdrant_backpressure} -> Qdrant.backpressure_snooze(:refused)
      {:error, :qdrant_wait_timeout} -> Qdrant.wait_timeout_snooze()
      {:error, :user_not_found} -> {:discard, :user_deleted}
      {:error, _} = err -> err
    end
  end

  # Every point now carries the current keyword encoding, so the note leaves
  # ReconcileEmbeddings' keyword sweep. Stamped with the TARGET version (the
  # pin before `INDEX_REBUILD=on`), as `EmbedNote` stamps: the v5 pass must
  # still re-encode it with the pinned avgdl. Guarded on the content it read: an edit
  # that landed meanwhile is EmbedNote's to index (and stamp). And on the
  # stamp it read, as EmbedNote's (#2216 L1): a DEK rotation's flip or a
  # payload-drift heal NULLs it while our resparse encoded under the retired
  # filter key, and stamping over that NULL would keep those vectors for good.
  defp stamp_keyword_version(note) do
    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.update_all(
          from(n in Note,
            where:
              n.kind == "note" and n.id == ^note.id and n.content_hash == ^note.content_hash and
                fragment(
                  "? IS NOT DISTINCT FROM ?",
                  n.keyword_version,
                  type(^note.keyword_version, :integer)
                )
          ),
          set: [keyword_version: elem(Engram.Rebuild.target_versions(), 1)]
        )
      end)

    :ok
  end

  # Never a re-embed from here. A point resparse cannot match keeps its old
  # keyword vector. On a stale-chunker note it is a legacy row (no
  # fingerprint) or a v1 chunk holding a base64 blob v2 strips, and the
  # chunker rebuild owns it. On a current chunker only an edit (EmbedNote's
  # full pass) rebuilds it. Re-embedding here turned the automatic keyword
  # sweep into a corpus-wide Voyage bill and, over a spent Free budget, a
  # sparse-only pass that drops the note's dense points.
  #
  # The note is stamped either way: a resparse of unchanged content finds the
  # same unmatched points every time, so leaving it unstamped only re-selected
  # it every backoff window (671 notes in prod, twice an hour, each pass
  # rewriting the matched points and logging an oban warning). Info, once per
  # note per keyword bump, still shipped to Loki as the tripwire for a
  # matching bug (#2320 was one), with `stale_chunker` saying which case.
  defp log_unmatched(note, unmatched) do
    Logger.info(
      "resparse left unmatched points",
      Metadata.with_category(:info, :search,
        note_id: note.id,
        count: unmatched,
        stale_chunker: stale_chunker?(note.chunker_version)
      )
      |> Metadata.ship_to_loki()
    )
  end

  # Only an OLDER (or missing) stamp is the chunker rebuild's. A newer one,
  # after a rollback, is left alone by the rebuild. Against
  # `Rebuild.target_versions/0`, as every version check.
  defp stale_chunker?(v), do: Engram.Rebuild.behind?(v, elem(Engram.Rebuild.target_versions(), 0))
end
