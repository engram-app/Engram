defmodule Engram.Workers.RebuildDryRun do
  @moduledoc """
  The v5 rebuild dry run (`INDEX_REBUILD=dry_run`, plan Task 16.1): plans
  every note the pass would rebuild (content current, behind this build's
  chunker or keyword version) into `rebuild_manifest`, then seals: pins
  each vault's `avgdl` and sets the ledger budget (`Rebuild.seal/0`).

  Never calls Voyage or Qdrant: `Indexing.rebuild_estimate/2` parses, caps
  and fingerprints locally.

  Two kinds of job, one worker:

    * the coordinator (`%{}`), queued by `ReconcileEmbeddings` each tick
      while the mode is `dry_run` and no budget is sealed. It queues one
      planner job per user that has none yet, and seals once every planner
      job has finished and the mode is still `dry_run`.
    * a planner (`%{"user_id" => id}`): plans that user's notes one at a
      time. A completed planner is never queued again for that user.

  Every planner re-checks the mode per page and cancels once it leaves
  `dry_run`. A note is planned behind a dead-man row (`Rebuild.put_pending/2`):
  if planning it kills the node, the row stays pending and no later run
  plans it again, so one note cannot crash-loop the queue. Notes the embed
  crash guard has charged a death to are skipped too.
  """
  use Oban.Worker,
    # :events, not :maintenance: that queue runs the cron workers only
    # (ObanQueueConfigTest). Planners run at the lowest priority, behind
    # every other events job.
    queue: :events,
    max_attempts: 3,
    # Coordinators share the nil `user_id` key, so one runs at a time.
    unique: [
      period: :infinity,
      keys: [:user_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

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
  @running ~w(available scheduled executing retryable)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    if Rebuild.mode() == :dry_run, do: plan_user(user_id), else: {:cancel, :not_dry_run}
  end

  def perform(%Oban.Job{id: id}) do
    if Rebuild.mode() == :dry_run, do: coordinate(id), else: :ok
  end

  defp coordinate(self_id) do
    queued = MapSet.new(planner_user_ids())
    missing = Enum.reject(TenantScan.user_ids(), &MapSet.member?(queued, &1))

    _ =
      missing
      |> Enum.map(&new(%{user_id: &1}, priority: 9))
      |> Enum.chunk_every(500)
      |> Enum.each(&Oban.insert_all/1)

    if missing == [] and not planners_running?(self_id), do: seal(), else: :ok
  end

  defp seal do
    case Rebuild.seal() do
      {:ok, budget} ->
        Logger.info(
          "rebuild_dry_run: sealed",
          Metadata.with_category(:info, :oban, budget_tokens: budget, skipped_count: pending())
        )

        :ok

      # Left unsealed: `Rebuild.seal/0` logged the v5 layout warning.
      {:error, reason} when reason in [:not_dry_run, :v5_layout_off] ->
        :ok
    end
  end

  # Users with a planner job that has not been discarded or cancelled.
  defp planner_user_ids do
    from(j in Oban.Job,
      where:
        j.worker == ^inspect(__MODULE__) and j.state not in ["discarded", "cancelled"] and
          fragment("? \\? 'user_id'", j.args),
      select: fragment("?->>'user_id'", j.args)
    )
    |> Repo.all()
  end

  defp planners_running?(self_id) do
    from(j in Oban.Job,
      where:
        j.worker == ^inspect(__MODULE__) and j.state in @running and j.id != ^self_id and
          fragment("? \\? 'user_id'", j.args),
      select: 1,
      limit: 1
    )
    |> Repo.one()
    |> Kernel.==(1)
  end

  # Dead-man rows still pending: notes whose planning crashed.
  defp pending do
    Rebuild.each_tenant(fn repo ->
      repo.aggregate(from(m in Manifest, where: is_nil(m.planned_at)), :count)
    end)
    |> Enum.sum()
  end

  defp plan_user(user_id) do
    case Accounts.get_user_with_subscription(user_id) do
      nil -> :ok
      user -> plan_pages(user, Rebuild.build_versions(), nil)
    end
  end

  defp plan_pages(user, versions, after_id) do
    if Rebuild.mode() == :dry_run do
      notes = Repo.with_tenant!(user.id, fn -> Repo.all(page_query(versions, after_id)) end)
      Enum.each(notes, &plan_note(user, &1))

      # Keyset on id, not the manifest anti-join alone: a note that failed to
      # decrypt or plan keeps a pending row and must not head every page.
      if length(notes) < @page,
        do: :ok,
        else: plan_pages(user, versions, List.last(notes).id)
    else
      {:cancel, :not_dry_run}
    end
  end

  # One note at a time: decrypted, planned and written before the next is
  # touched, behind its dead-man row.
  defp plan_note(user, note) do
    :ok = Rebuild.put_pending(user.id, note)

    with {:ok, note} <- Crypto.maybe_decrypt_note_fields(note, user),
         {:ok, est} <- Indexing.rebuild_estimate(note, user) do
      Rebuild.put_manifest(user.id, [
        Map.merge(est, %{
          note_id: note.id,
          vault_id: note.vault_id,
          model: Engram.EmbedModels.doc_model(user)
        })
      ])
    else
      # Left pending: counted as skipped at the seal, estimated at 0 by
      # `Rebuild.check_note/2`.
      {:error, _reason} -> :ok
    end
  end

  # The note set the pass rebuilds, at the BUILD's versions (not the switch's
  # gated ones), minus what the manifest already holds (planned or pending)
  # and minus notes the embed crash guard charged a death to. RLS scopes it.
  defp page_query(versions, after_id) do
    IndexVersions.content_current_notes()
    |> where(
      ^dynamic(
        [n],
        ^IndexVersions.stale_dynamic(versions) or ^IndexVersions.keyword_stale_dynamic(versions)
      )
    )
    |> where([n], is_nil(n.embed_crashes) or n.embed_crashes == 0)
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
