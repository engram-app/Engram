defmodule Engram.DataMigrations.NameTerms do
  @moduledoc """
  Backfill of `name_terms` (O(1) folder rename plan, S1;
  `Engram.Search.NameTerms`): every live note and folder whose terms were
  not written for its current name (the `notes_name_terms_stale` /
  `folders_name_terms_stale` predicate: never written, written under an
  older stamp version, renamed or rotated since, restored).

  A pass does no healing itself. It starts the paced chain
  (`Engram.Workers.BackfillNameTerms`) when none is in flight and a stale
  ref exists, and is done when no chain is in flight and no stale ref is
  left: one `LIMIT 1` probe per table, served by the stale partial indexes
  (O(1) in the table, empty in steady state).

  The search leg does NOT wait for this ledger: a ref without terms is only
  not found by the leg yet. After done, a previous-release writer's drift is
  healed by `Engram.Bookkeeping.Drain` through the same indexes
  (`run_pass(user_ids: ...)`). Zero operator steps; not re-verified.

  Kill switch `enabled?/0` = service override `name_terms_backfill`,
  default on. Pace (`Engram.Workers.BackfillNameTerms`): at most
  `name_terms_backfill_max_rows` refs a hop (default #{1_000}) and
  `name_terms_backfill_writes_per_s` refs a second (default #{150}).
  """
  @behaviour Engram.DataMigration

  import Ecto.Query, only: [from: 2, subquery: 1]

  alias Engram.Backfill.{TenantScan, Throttle}
  alias Engram.DataMigrations
  alias Engram.Folders.Folder
  alias Engram.Maintenance.Cursor
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Search.NameTerms
  alias Engram.Workers.BackfillNameTerms

  @impl true
  def name, do: "name_terms"

  @impl true
  def version, do: NameTerms.version()

  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:name_terms_backfill, true) == true

  # 150 refs/s: each ref is one non-HOT `notes`/`folders` UPDATE (an entry
  # in every index) plus up to 32 `name_terms` inserts. At 150 that is at most
  # about 4,800 posting rows a second, a quarter of the unthrottled ~600 refs/s
  # that the 2026-11-01 swap shape matched, and ~214k refs (prod: ~170k notes,
  # ~44k folders) take about 24 min. 1,000 refs a hop: under the ceiling a
  # hop writes for ~7 s, and a walk is ~214 hops, well inside the chain's 500.
  @max_rows 1_000
  @writes_per_s 150

  @doc "Refs a chain hop heals at most: the `name_terms_backfill_max_rows` override."
  @spec max_rows() :: pos_integer()
  def max_rows, do: Throttle.positive(:name_terms_backfill_max_rows, @max_rows)

  @doc "Refs a hop heals a second at most: the `name_terms_backfill_writes_per_s` override."
  @spec writes_per_s() :: pos_integer()
  def writes_per_s, do: Throttle.positive(:name_terms_backfill_writes_per_s, @writes_per_s)

  @doc "True once every live note and folder has current terms."
  def done?, do: DataMigrations.done?(name(), version())

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # `user_ids:` heals those users inline (the drain's repair).
  def run_pass(opts) do
    case Keyword.fetch(opts, :user_ids) do
      {:ok, user_ids} ->
        fixed =
          for user_id <- user_ids, schema <- [Note, Folder], reduce: 0 do
            n -> n + NameTerms.heal_user(schema, user_id)
          end

        if fixed == 0, do: :done, else: {:more, rows: fixed}

      :error ->
        chain()
    end
  end

  defp chain do
    cond do
      DataMigrations.jobs_in_flight?(BackfillNameTerms) ->
        {:more, chain: 1}

      not stale?() ->
        :done

      fruitless_walk?() ->
        :done

      true ->
        {:ok, _} = Oban.insert(BackfillNameTerms.start())
        {:more, chain: 1}
    end
  end

  @last_walk "name_terms:last_walk"
  @retry_after_s 86_400

  @doc "Records a complete chain walk (`BackfillNameTerms`) and how many refs it fixed."
  @spec walked(non_neg_integer()) :: :ok
  def walked(fixed) do
    Cursor.put(@last_walk, %{"fixed" => fixed, "at" => DateTime.to_iso8601(DateTime.utc_now())})
  end

  # The last complete walk fixed nothing and is under a day old: what is
  # still stale was written after it, or was deferred on a transient key
  # error (`Crypto.key_outcome/1` `:later`). Close the ledger and leave it
  # to the drain, which only runs once the ledger is done and retries those
  # users' stale rows each tick.
  defp fruitless_walk? do
    with %{"fixed" => 0, "at" => at} <- Cursor.get(@last_walk),
         {:ok, at, _} <- DateTime.from_iso8601(at) do
      DateTime.diff(DateTime.utc_now(), at) < @retry_after_s
    else
      _ -> false
    end
  end

  @left_cap 1_000

  @doc """
  Stale refs left, counted up to #{@left_cap} per table on the stale partial
  indexes (a bounded read, for the chain's pass line), or `:unknown` on a
  per-user pool (counting would be one query per user).
  """
  @spec left() :: non_neg_integer() | :unknown
  def left do
    case TenantScan.pool() do
      {:fleet, repo} ->
        for schema <- [Note, Folder], reduce: 0 do
          n ->
            capped = from(r in NameTerms.stale_query(schema), select: 1, limit: @left_cap)
            n + repo.aggregate(subquery(capped), :count)
        end

      :per_user ->
        :unknown
    end
  end

  # One `LIMIT 1` probe per table on its stale partial index.
  defp stale?, do: Enum.any?([Note, Folder], &stale?/1)

  defp stale?(schema) do
    probe = fn repo, query -> repo.exists?(query) end
    query = NameTerms.stale_query(schema)

    case TenantScan.pool() do
      {:fleet, repo} ->
        probe.(repo, query)

      :per_user ->
        TenantScan.user_ids()
        |> Enum.any?(fn uid ->
          {:ok, found?} =
            Repo.with_tenant(uid, fn ->
              probe.(Repo, from(r in query, where: r.user_id == ^uid))
            end)

          found?
        end)
    end
  end
end
