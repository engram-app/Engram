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

  alias Engram.DataMigrations
  alias Engram.Indexing
  alias Engram.Notes.Note
  alias Engram.Rebuild
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @impl true
  def name, do: prefix(Rebuild.target_versions()) <> (Indexing.embed_model() || "none")

  @doc """
  The newest `{chunker, keyword}` pass that has completed, under ANY embed
  model and ledger `version/0`, each capped at `build` (a rollback build
  older than the pass keeps its own); nil when none has. Every content-current
  note held at least those versions when it closed. The model is left out
  because it has its own stale term (`stale_dynamic/1`), and the ledger
  version because a bump that reopens the pass does not unmake what the old
  one proved. Read by `Rebuild.target_versions/0`, so `off` keeps stamping the
  last completed pass after the next chunker or keyword bump.
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

  # Bumping this reopens the pass; `newest_completed/1` ignores it on purpose.
  @impl true
  def version, do: 1

  @spec done?() :: boolean()
  def done?, do: DataMigrations.done?(name(), version())

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
  """
  @spec live_notes() :: Ecto.Query.t()
  def live_notes do
    from(n in Note, as: :note)
    |> join(:inner, [n], v in Vault, on: v.id == n.vault_id and is_nil(v.deleted_at))
    |> where([n], n.kind == "note" and is_nil(n.deleted_at))
  end

  @doc "`live_notes/0` already indexed at their current content."
  @spec content_current_notes() :: Ecto.Query.t()
  def content_current_notes do
    where(live_notes(), [n], n.embed_hash == n.content_hash)
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
