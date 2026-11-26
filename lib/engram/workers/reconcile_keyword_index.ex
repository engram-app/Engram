defmodule Engram.Workers.ReconcileKeywordIndex do
  @moduledoc """
  Keeps the kwsearch keyword index equal to Postgres with no operator step
  (search storage roadmap P2 tasks 3 and 5): the first bulk load of existing
  notes, every reload after an index change, and the drift and orphan
  repair. All of it through the bulk endpoint
  (`Engram.KeywordStore.Tantivy.Bulk`), never through `keyword_feed` (F2).

  ## Version stamp + reconcile

  The walk's target is `"<kwsearch epoch>:<@version>"`. kwsearch starts a new
  epoch for a new index and after a feed gap (rows it never applied were
  trimmed), and stays `rebuilding` (not serving) until told the epoch is
  loaded. `@version` is bumped here when the docs a note produces change. A
  target the stored cursor has not finished is a FULL walk: every user, every
  note with chunk rows plus every note kwsearch lists. Once it ends, a
  rebuilding kwsearch is told (`Client.rebuilt/1`).

  After that, a DIFF walk runs daily: per user, kwsearch's per-note doc count
  (`Client.notes/3`) against the note's chunk rows in Postgres. Only notes
  that differ are pushed: a note kwsearch lacks or holds wrongly is re-read
  and pushed whole; a note kwsearch holds that Postgres no longer has (gone
  or trashed) is pushed with an empty point set, which is the Tantivy orphan
  pass (index docs vs chunk rows).

  ## Pace and safety

  `@users_per_run` users per run, by user id after a persisted cursor
  (`Engram.Maintenance.Cursor`), chained every #{60} s while a walk is open;
  the hourly cron restarts a lost chain. A user mid-DEK-rotation, a kwsearch
  error or a refused batch stops the run where it is (the cursor names the
  last finished user), so a walk never reports done with a user missing.

  A no-op unless the feed is written (`Engram.KeywordStore.feed?/0`, off by
  default) and `:keyword_reconcile` is not false (kill switch, default on).
  It never changes what searches read.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: Engram.Jobs.unique(__MODULE__)

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Crypto.RotationGate
  alias Engram.KeywordStore
  alias Engram.KeywordStore.Tantivy.Bulk
  alias Engram.KeywordStore.Tantivy.Client
  alias Engram.Logger.Metadata
  alias Engram.Maintenance.Cursor
  alias Engram.Notes.{Chunk, Note}
  alias Engram.Repo
  alias Engram.ServiceConfig

  require Logger

  # Bump when the docs a note produces change shape (not for tokenizer
  # changes: those re-upsert through the resparse and the feed).
  @version 1
  @cursor "keyword_reconcile"
  @users_per_run 25
  @notes_per_read 200
  @notes_page 10_000
  @every_s 60
  @diff_every_s 86_400

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @doc "False while the `:keyword_reconcile` kill switch is off."
  @spec enabled?() :: boolean()
  def enabled?, do: ServiceConfig.get(:keyword_reconcile, true) != false

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    with true <- KeywordStore.feed?() and enabled?(),
         {:ok, epoch} <- Client.epoch() do
      result = run(epoch, System.system_time(:second))
      _ = if result == :more, do: {:ok, _} = %{} |> new(schedule_in: @every_s) |> Oban.insert()
      {:ok, result}
    else
      _off_or_unreachable -> :ok
    end
  end

  @doc """
  One run against kwsearch at `epoch` (`Client.epoch/0`): `:more` while the
  walk has users left, `:done` when this run finished it, `:idle` when there
  was nothing due, `:halted` when it stopped on an error.
  """
  @spec run(%{id: String.t(), rebuilding: boolean()}, integer()) ::
          :more | :done | :idle | :halted
  def run(epoch, now) do
    target = "#{epoch.id}:#{@version}"
    cursor = Cursor.get(@cursor) || %{}

    case walk(cursor, target, now) do
      :idle ->
        # A finished full load whose `rebuilt` call failed: say it again.
        _ = if epoch.rebuilding and cursor["mode"] == "full", do: Client.rebuilt(epoch.id)
        :idle

      walk ->
        step(walk, epoch, now)
    end
  end

  defp walk(cursor, target, now) do
    cond do
      cursor["target"] != target -> %{"target" => target, "mode" => "full"}
      is_nil(cursor["done_at"]) -> cursor
      now - cursor["done_at"] >= @diff_every_s -> %{"target" => target, "mode" => "diff"}
      true -> :idle
    end
  end

  defp step(walk, epoch, now) do
    users = next_users(walk["after"], @users_per_run)

    walked =
      Enum.reduce_while(users, walk, fn user_id, walk ->
        case sync_user(user_id, walk["mode"]) do
          :ok ->
            walk = Map.put(walk, "after", user_id)
            :ok = Cursor.put(@cursor, walk)
            {:cont, walk}

          {:error, reason} ->
            Logger.warning(
              "keyword reconcile halted",
              Metadata.with_category(:warning, :search,
                user_id: user_id,
                reason: Metadata.safe_reason(reason)
              )
            )

            {:halt, :halted}
        end
      end)

    cond do
      walked == :halted ->
        :halted

      length(users) == @users_per_run ->
        :more

      true ->
        :ok = Cursor.put(@cursor, Map.merge(walk, %{"done_at" => now, "after" => nil}))
        _ = if walk["mode"] == "full" and epoch.rebuilding, do: Client.rebuilt(epoch.id)
        :done
    end
  end

  # `users` carries no RLS (Engram.Backfill.TenantScan): the id walk needs
  # no tenant. A soft-deleted account holds no index (its points were dropped).
  defp next_users(after_id, limit) do
    from(u in User, where: is_nil(u.deleted_at), order_by: u.id, limit: ^limit, select: u.id)
    |> then(fn q -> if after_id, do: where(q, [u], u.id > ^after_id), else: q end)
    |> Repo.all()
  end

  @doc """
  Brings one user's kwsearch docs to Postgres: `"full"` pushes every note
  with chunk rows and every note kwsearch holds, `"diff"` only notes whose
  doc counts differ (orphans included).
  """
  @spec sync_user(String.t(), String.t()) :: :ok | {:error, term()}
  def sync_user(user_id, mode) do
    with %User{} = user <- Repo.get(User, user_id) || :gone,
         :ok <- RotationGate.check(to_string(user_id)),
         {:ok, index} <- listing(to_string(user_id), nil, %{}) do
      pg = note_counts(user_id)

      user_id
      |> candidates(mode, pg, index)
      |> Enum.chunk_every(@notes_per_read)
      |> Enum.reduce_while(:ok, fn ids, :ok ->
        vaults = Map.new(ids, &{&1, index |> Map.get(&1, {nil, 0}) |> elem(0)})

        case Bulk.push(user, ids, vaults) do
          {:ok, _counts} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      :gone -> :ok
      {:error, _} = error -> error
    end
  end

  defp candidates(_user_id, "full", pg, index),
    do: Enum.uniq(for({id, n} <- pg, n > 0, do: id) ++ Map.keys(index))

  # ponytail: counts only, so an equal-count drift (same chunk count, other
  # terms) waits for a version bump or the note's next edit; compare point
  # ids if one shows up.
  defp candidates(_user_id, "diff", pg, index) do
    from_pg = for {id, n} <- pg, n != index |> Map.get(id, {nil, 0}) |> elem(1), do: id
    from_index = for {id, _} <- index, not Map.has_key?(pg, id), do: id
    from_pg ++ from_index
  end

  # kwsearch's notes of the user: %{note_id => {vault_id, doc_count}}.
  defp listing(user_id, after_id, acc) do
    with {:ok, page} <- Client.notes(user_id, after_id, @notes_page) do
      acc = Enum.reduce(page, acc, fn {n, v, c}, acc -> Map.put(acc, n, {v, c}) end)

      if length(page) == @notes_page,
        do: listing(user_id, page |> List.last() |> elem(0), acc),
        else: {:ok, acc}
    end
  end

  # Live notes and their chunk rows with a point: %{note_id => count}.
  defp note_counts(user_id) do
    {:ok, counts} =
      Repo.with_tenant(user_id, fn ->
        from(n in Note,
          left_join: c in Chunk,
          on: c.note_id == n.id and not is_nil(c.qdrant_point_id),
          where: n.user_id == ^user_id and n.kind == "note" and is_nil(n.deleted_at),
          group_by: n.id,
          select: {n.id, count(c.qdrant_point_id)}
        )
        |> Repo.all()
        |> Map.new()
      end)

    counts
  end
end
