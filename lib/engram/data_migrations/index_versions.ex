defmodule Engram.DataMigrations.IndexVersions do
  @moduledoc """
  Every note indexed with the current chunker, keyword encoding and embed
  model. `ReconcileEmbeddings` does the rebuilding (see
  `docs/context/index-version-self-heal.md`); this only decides when no
  content-current note is left on an old version, so the reconcile cron can
  stop scanning for them. The name carries the three versions: bumping any
  of them is a new, not-done migration.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.DataMigrations
  alias Engram.Indexing
  alias Engram.KeywordIndex
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Vaults.Vault

  @impl true
  def name,
    do:
      "index_versions:chunker=#{Markdown.chunker_version()},keyword=#{KeywordIndex.version()}," <>
        "model=#{Indexing.embed_model() || "none"}"

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
    stale =
      DataMigrations.any_row?(fn _repo ->
        from(n in Note, as: :note)
        |> join(:inner, [n], v in Vault, on: v.id == n.vault_id and is_nil(v.deleted_at))
        |> where([n], n.kind == "note" and is_nil(n.deleted_at))
        |> where([n], not is_nil(n.embed_hash) and n.embed_hash == n.content_hash)
        |> where(^dynamic([n], ^stale_dynamic() or ^keyword_stale_dynamic()))
        |> select(1)
      end)

    if stale, do: :more, else: :done
  end

  @doc "Notes on an older chunker, or with dense vectors from another embed model."
  def stale_dynamic do
    chunker = Markdown.chunker_version()
    chunker_stale = dynamic([n], is_nil(n.chunker_version) or n.chunker_version != ^chunker)

    case Indexing.embed_model() do
      # The build cannot name its model: model tracking is off.
      nil ->
        chunker_stale

      model ->
        # `not is_nil` first: on a sparse-only note `dense = content` is NULL,
        # and the keyword sweep negates this predicate, where NOT (NULL)
        # silently drops the row. Every term here must be TRUE or FALSE.
        dynamic(
          [n],
          ^chunker_stale or
            (not is_nil(n.dense_indexed_hash) and not is_nil(n.content_hash) and
               n.dense_indexed_hash == n.content_hash and
               (is_nil(n.embed_model) or n.embed_model != ^model))
        )
    end
  end

  @doc "Notes whose keyword vectors predate `KeywordIndex.version/0`."
  def keyword_stale_dynamic do
    version = KeywordIndex.version()
    dynamic([n], is_nil(n.keyword_version) or n.keyword_version != ^version)
  end
end
