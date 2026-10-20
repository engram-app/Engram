defmodule Engram.Workers.RebuildDryRun do
  @moduledoc """
  The v5 rebuild dry run (`INDEX_REBUILD=dry_run`, plan Task 16.1): plans
  every note the pass would rebuild (content current, behind this build's
  chunker or keyword version) and writes its `rebuild_manifest` row, then
  pins each vault's `avgdl` and sets the ledger budget (`Rebuild.seal/0`).

  Never calls Voyage or Qdrant: `Indexing.rebuild_estimate/2` parses, caps
  and fingerprints locally. Queued by `ReconcileEmbeddings` while the mode is
  `dry_run`; a no-op in any other mode. Resumable: a note already in the
  manifest is skipped, so a run cut short by its timeout continues on the
  next tick, and only a run that reaches the end seals.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto
  alias Engram.DataMigrations.IndexVersions
  alias Engram.Indexing
  alias Engram.Logger.Metadata
  alias Engram.Rebuild
  alias Engram.Rebuild.Manifest
  alias Engram.Repo

  require Logger

  @page 200

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Rebuild.mode() == :dry_run, do: run(), else: :ok
  end

  defp run do
    versions = Rebuild.build_versions()

    {planned, skipped} =
      Enum.reduce(TenantScan.user_ids(), {0, 0}, fn user_id, {p, s} ->
        {up, us} = plan_user(user_id, versions)
        {p + up, s + us}
      end)

    {:ok, budget} = Rebuild.seal()

    Logger.info(
      "rebuild_dry_run: sealed",
      Metadata.with_category(:info, :search,
        total_count: planned,
        skipped_count: skipped,
        budget_tokens: budget
      )
    )

    :ok
  end

  # `{planned, skipped}` for one user, a page at a time.
  defp plan_user(user_id, versions) do
    case Accounts.get_user_with_subscription(user_id) do
      nil -> {0, 0}
      user -> plan_pages(user, versions, nil, {0, 0})
    end
  end

  defp plan_pages(user, versions, after_id, {p, s}) do
    notes = Repo.with_tenant!(user.id, fn -> Repo.all(page_query(versions, after_id)) end)

    {rows, skipped} =
      notes
      |> Crypto.decrypt_notes_batch(user)
      |> Enum.reduce({[], 0}, fn
        {:ok, note}, {rows, sk} ->
          case Indexing.rebuild_estimate(note, user) do
            {:ok, est} ->
              {[Map.merge(est, %{note_id: note.id, vault_id: note.vault_id}) | rows], sk}

            {:error, _reason} ->
              {rows, sk + 1}
          end

        {:error, _reason}, {rows, sk} ->
          {rows, sk + 1}
      end)

    :ok = Rebuild.put_manifest(user.id, rows)
    acc = {p + length(rows), s + skipped}

    # Keyset on id, not the manifest anti-join alone: a skipped note (no DEK,
    # a corrupt row) never enters the manifest and would head every page.
    if length(notes) < @page,
      do: acc,
      else: plan_pages(user, versions, List.last(notes).id, acc)
  end

  # The note set the pass rebuilds, at the BUILD's versions (not the switch's
  # gated ones), minus what the manifest already holds. RLS scopes it.
  defp page_query(versions, after_id) do
    IndexVersions.content_current_notes()
    |> where(
      ^dynamic(
        [n],
        ^IndexVersions.stale_dynamic(versions) or ^IndexVersions.keyword_stale_dynamic(versions)
      )
    )
    |> where(
      [n],
      not exists(from(m in Manifest, where: m.note_id == parent_as(:note).id, select: 1))
    )
    |> then(&if(after_id, do: where(&1, [n], n.id > ^after_id), else: &1))
    |> order_by([n], asc: n.id)
    |> limit(@page)
    |> select([n], n)
  end
end
