defmodule Engram.DataMigrations.IndexVersions do
  @moduledoc """
  Every note indexed with the current chunker, keyword encoding and embed
  model. `ReconcileEmbeddings` does the rebuilding (see
  `docs/context/index-version-self-heal.md`); this only decides when no
  content-current note is left on an old version, so the reconcile cron can
  stop scanning for them. The name carries the three versions: bumping any
  of them is a new, not-done migration.

  The versions are `Engram.Rebuild.target_versions/0`: the build's while
  `INDEX_REBUILD=on`, else the newest completed pass (`newest_completed/1`),
  never below the pinned pre-v5 versions. A stamp bump past the pins renames nothing and
  rebuilds nothing until the switch is `on`, which reopens the migration.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations
  alias Engram.Indexing
  alias Engram.Notes.Note
  alias Engram.Rebuild
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @impl true
  def name, do: name(Rebuild.target_versions())

  # The pass for `{chunker, keyword}` under the current embed model.
  defp name(versions), do: prefix(versions) <> (Indexing.embed_model() || "none")

  @doc """
  The newest `{chunker, keyword}` pass that has completed, under ANY embed
  model, capped at `build` (a rollback build older than the pass keeps its
  own); nil when none has. Every content-current note held at least those
  versions when it closed. One real row wins (tuple order), never a mix of
  two rows' components. The model is left out because it has its own stale
  term (`stale_dynamic/1`). Rows whose pass is open again (a `version/0` bump
  that found work) do not count. Read by `Rebuild.target_versions/0`, so
  `off` keeps stamping the last completed pass after the next chunker or
  keyword bump.
  """
  @spec newest_completed({pos_integer(), pos_integer()}) :: {pos_integer(), pos_integer()} | nil
  def newest_completed({build_chunker, build_keyword}) do
    from(e in DataMigrations.Entry,
      where: like(e.name, "index_versions:%") and not is_nil(e.completed_at),
      select: e.name
    )
    |> Repo.all()
    |> Enum.flat_map(fn name ->
      case Regex.run(~r/^index_versions:chunker=(\d+),keyword=(\d+),model=/, name) do
        [_, c, k] ->
          [{min(String.to_integer(c), build_chunker), min(String.to_integer(k), build_keyword)}]

        nil ->
          []
      end
    end)
    |> Enum.max(fn -> nil end)
  end

  defp prefix({chunker, keyword}),
    do: "index_versions:chunker=#{chunker},keyword=#{keyword},model="

  # Bumping this reopens the pass. `newest_completed/1` does not filter on
  # it, but once the bumped pass finds work the runner reopens the SAME row
  # (`note_open/2` clears `completed_at`), so `off` falls back to the next
  # older completed pass, or the pins, until it closes again. Stamps can
  # then only be lower than the data, never higher.
  @impl true
  def version, do: 1

  @spec done?() :: boolean()
  def done?, do: done?(Rebuild.target_versions())

  @doc """
  Whether the pass for `versions` (`{chunker, keyword}`) under the current
  embed model and this migration version has completed. `Rebuild.holding?/0`
  asks about the BUILD's versions: under a budget halt `target_versions/0`
  falls back to the newest completed pass, which is done by definition.
  """
  @spec done?({pos_integer(), pos_integer()}) :: boolean()
  def done?(versions), do: DataMigrations.done?(name(versions), version())

  # Content-stale notes are excluded: the live sweep embeds them, which
  # stamps current versions. Counting them would hold this open on every
  # install that is being written to. The cooldown filter is NOT applied: a
  # stale note inside a cooldown still needs its rebuild.
  @impl true
  def run_pass do
    versions = Rebuild.target_versions()

    stale =
      content_current_notes()
      |> where(^dynamic([n], ^stale_dynamic(versions) or ^keyword_stale_dynamic(versions)))
      |> select(1)
      |> DataMigrations.any_row?()

    if stale, do: :more, else: :done
  end

  @doc """
  Notes the index sweeps consider: kind note, not deleted, in a live vault.
  Bound `as: :note`. Shared with `ReconcileEmbeddings` so the done check and
  the sweeps can never disagree on which notes count.

  "Live vault" is an anti-join (no soft-deleted vault holds the note), not
  an inner join on live vaults: `notes.vault_id` is a NOT NULL foreign key,
  so the two select the same notes, but an inner join lets the planner drive
  the loop from the user's vaults and scan a per-vault notes index for each
  (`notes_recent_index (user_id, vault_id, updated_at, id)`), filtering an
  id window against every note of the vault. Prod, 2026-11-02: 445 ms and
  669 cold reads for a 5-id window. An anti-join keeps `notes` the outer
  side.

  `ids` (an id window) reads the window's rows by primary key first
  (`IdWindows.by_id/2`) and applies every predicate to those rows, so a
  windowed sweep never walks a user- or vault-leading index.
  ReconcileEmbeddingsIndexPlanTest pins it.

  Under a tenant's RLS the two forms differ for a note whose vault the
  tenant cannot see (another owner's): the inner join dropped it, the
  anti-join keeps it. No such note exists while every vault has one owner;
  shared/team vaults (#2389) must revisit this.
  """
  @spec live_notes([Ecto.UUID.t()] | nil) :: Ecto.Query.t()
  def live_notes(ids \\ nil) do
    ids
    |> notes()
    |> where([n], n.kind == "note" and is_nil(n.deleted_at))
    |> where(
      [n],
      not exists(
        from(v in Vault,
          where: v.id == parent_as(:note).vault_id and not is_nil(v.deleted_at),
          select: 1
        )
      )
    )
  end

  # The kind filter repeats `live_notes/1`'s so NotesScopeLintTest sees this
  # `from` scoped; the window form applies it to the probed rows.
  defp notes(nil), do: from(n in Note, as: :note, where: n.kind == "note")
  defp notes(ids), do: IdWindows.by_id(notes(nil), ids)

  @doc "`live_notes/1` already indexed at their current content."
  @spec content_current_notes([Ecto.UUID.t()] | nil) :: Ecto.Query.t()
  def content_current_notes(ids \\ nil) do
    where(live_notes(ids), [n], n.embed_hash == n.content_hash)
  end

  @doc """
  Notes on an older chunker, or with dense vectors from another embed model.
  A chunker newer than this build counts as current (forward compatible).
  `{chunker, keyword}` defaults to `Rebuild.target_versions/0`.
  """
  def stale_dynamic({chunker, _keyword} \\ Rebuild.target_versions()) do
    # `<`, not `!=`: a stamp from a NEWER release is current. A rollback would
    # otherwise rebuild every note a newer chunker indexed, and the roll
    # forward would rebuild them all again.
    chunker_stale = dynamic([n], is_nil(n.chunker_version) or n.chunker_version < ^chunker)

    case model_unkeepable() do
      # The build cannot name its model: model tracking is off.
      nil ->
        chunker_stale

      unkeepable ->
        # `not is_nil` first: on a sparse-only note `dense = content` is NULL,
        # and the keyword sweep negates this predicate, where NOT (NULL)
        # silently drops the row. Every term here must be TRUE or FALSE.
        dynamic(
          [n],
          ^chunker_stale or
            (not is_nil(n.dense_indexed_hash) and not is_nil(n.content_hash) and
               n.dense_indexed_hash == n.content_hash and
               (is_nil(n.embed_model) or ^unkeepable))
        )
    end
  end

  # A non-null `embed_model` the note may not keep, as `EmbedNote.version_stale?/2`
  # decides it: per plan (`Engram.EmbedModels.acceptable/1`, by the owner's
  # plan), else not the build's model. nil: tracking off.
  defp model_unkeepable do
    cond do
      Engram.EmbedModels.per_plan?() ->
        free_ok = Engram.EmbedModels.acceptable(:free)
        paid_ok = Engram.EmbedModels.acceptable(:paid)
        paid = owner_paid()

        dynamic(
          [n],
          (exists(paid) and n.embed_model not in ^paid_ok) or
            (not exists(paid) and n.embed_model not in ^free_ok)
        )

      model = Indexing.embed_model() ->
        dynamic([n], n.embed_model != ^model)

      true ->
        nil
    end
  end

  @doc """
  Correlated subquery: the `:note`-bound row's owner has an entitled paid
  plan (`Billing.paid?/1` in SQL). `subscriptions.status` DEFAULTS to
  "trialing" and `tier` accepts "free", so both filters are load-bearing.
  """
  def owner_paid do
    from(s in Engram.Billing.Subscription,
      where:
        s.user_id == parent_as(:note).user_id and
          s.status in ^Engram.Billing.entitled_statuses() and
          s.tier in ["starter", "pro"],
      select: 1
    )
  end

  @doc """
  Notes whose keyword vectors predate the target keyword version (the pin
  until `INDEX_REBUILD=on`, then `KeywordIndex.version/0`). A newer stamp
  counts as current, for the same rollback reason as the chunker.
  `{chunker, keyword}` defaults to `Rebuild.target_versions/0`.
  """
  def keyword_stale_dynamic({_chunker, version} \\ Rebuild.target_versions()) do
    dynamic([n], is_nil(n.keyword_version) or n.keyword_version < ^version)
  end
end
