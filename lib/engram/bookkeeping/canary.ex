defmodule Engram.Bookkeeping.Canary do
  @moduledoc """
  Hourly random-sample proof that the database-kept bookkeeping holds.

  The trigger-closed invariants (derived `notes` keys, the `note_bodies`
  copy, the `note_index_state` row and its chunk counters) are kept by
  database triggers for every writer of every release, so nothing walks the
  table to re-check them. This is the tripwire that replaces the walk: it
  reads a small random sample, runs the checks the old nightly re-verify ran
  (the same predicates, `NoteSplit.unfixed/0`, `NoteSplit.drift_ids/2`,
  `NoteIndexState.drifted/2`) with the deep compare allowed because it is a
  few hundred rows, and reports COUNTS only (never a note id or content).

  Sample: `@points` random positions between the smallest and largest note
  id, `@per_point` consecutive ids from each (a primary-key range read, no
  scan). A random position, not a random uuid, because ids are time-ordered
  (v7): a random 128-bit value would land past the newest note. The ids
  cluster by creation time around each position, so this is a tripwire for
  systematic drift (a disabled trigger, a bad deploy), not a proof of zero:
  with 4,800 sampled rows a day, drift in 0.1% of rows is seen with ~99%
  probability, drift in 0.01% with ~38%.

  `body_drift` compares each `notes` body column with its `note_bodies` copy.
  It is meaningful only while `notes` still carries the body columns: once
  the R8 contract (#2402) drops them there is nothing to compare, and the
  invariant reads 0 by construction; remove it with that contract.

  Telemetry (`Engram.PromEx.Reliability`):
    * `[:engram, :bookkeeping, :drift]` `%{count: n}` tagged `:invariant`,
      one event per invariant per run (0 included):
      `engram_prom_ex_reliability_bookkeeping_drift_total`.
    * `[:engram, :bookkeeping, :canary_rows]` `%{count: n}`: rows checked
      (`engram_prom_ex_reliability_bookkeeping_canary_rows_total`).
    * `[:engram, :bookkeeping, :canary_ran]` `%{unix: s}`: when the run
      finished (`engram_prom_ex_reliability_bookkeeping_canary_last_run_unix`,
      a gauge). The dead-man signal: a canary that stops running must not
      look healthy.

  Scope follows `TenantScan.pool/0`: one fleet sample on the maintenance pool
  (SaaS), else a share of the sample per user inside that user's tenant
  (self-host).
  """

  import Ecto.Query

  alias Engram.Backfill.TenantScan
  alias Engram.DataMigrations.NoteIndexState
  alias Engram.DataMigrations.NoteSplit
  alias Engram.Logger.Metadata
  alias Engram.Repo

  require Logger

  @points 20
  @per_point 10

  @invariants [:note_split, :body_drift, :state_missing, :counters_drift]

  @doc "The invariant tags the canary reports, in a stable order."
  @spec invariants() :: [invariant(), ...]
  def invariants, do: @invariants

  @type invariant :: :note_split | :body_drift | :state_missing | :counters_drift
  @type report :: %{checked: non_neg_integer(), drift: %{invariant() => non_neg_integer()}}

  @doc """
  One canary run: sample, check, emit telemetry, log counts. Returns the
  report. `:points` / `:per_point` shrink the sample (tests).
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    points = Keyword.get(opts, :points, @points)
    per_point = Keyword.get(opts, :per_point, @per_point)

    report =
      scoped(points, fn repo, user_id, share ->
        ids = sample(repo, user_id, share, per_point)
        {length(ids), check(repo, ids)}
      end)
      |> Enum.reduce(%{checked: 0, drift: zero()}, fn {n, drift}, acc ->
        %{checked: acc.checked + n, drift: Map.merge(acc.drift, drift, fn _, a, b -> a + b end)}
      end)

    emit(report)
    report
  end

  defp zero, do: Map.new(@invariants, &{&1, 0})

  # The checks of the removed nightly re-verifies, on `ids` only.
  defp check(_repo, []), do: zero()

  defp check(repo, ids) do
    {drifted, missing} = NoteIndexState.drifted(repo, Enum.map(ids, &Ecto.UUID.dump!/1))

    %{
      note_split: length(NoteSplit.unfixed_ids(repo, ids)),
      body_drift: length(NoteSplit.drift_ids(repo, ids)),
      state_missing: missing,
      counters_drift: length(drifted)
    }
  end

  # ---- sampling ------------------------------------------------------------

  # `fun.(repo, user_id | nil, points)` once on the fleet, or once per user in
  # that user's tenant with an equal share of the points. The users with the
  # most share are not favoured: `Enum.shuffle/1` bounds the work to `points`
  # users.
  defp scoped(points, fun) do
    case TenantScan.pool() do
      {:fleet, repo} ->
        [fun.(repo, nil, points)]

      :per_user ->
        users = TenantScan.user_ids() |> Enum.shuffle() |> Enum.take(points)
        share = max(div(points, max(length(users), 1)), 1)
        Enum.map(users, fn uid -> Repo.with_tenant!(uid, fn -> fun.(Repo, uid, share) end) end)
    end
  end

  defp sample(repo, user_id, points, per_point) do
    with lo when is_binary(lo) <- edge(repo, user_id, :asc),
         hi when is_binary(hi) <- edge(repo, user_id, :desc) do
      {lo, hi} = {to_int(lo), to_int(hi)}

      # The smallest id is always a position, so a table of at most `per_point`
      # notes is checked whole.
      positions = [lo | for(_ <- 2..points//1, do: lo + :rand.uniform(hi - lo + 1) - 1)]

      positions
      |> Enum.flat_map(&from_point(repo, user_id, &1, per_point))
      |> Enum.uniq()
    else
      nil -> []
    end
  end

  defp edge(repo, user_id, dir) do
    from(n in "notes", order_by: [{^dir, n.id}], limit: 1, select: type(n.id, Ecto.UUID))
    |> scope(user_id)
    |> repo.one()
  end

  defp from_point(repo, user_id, at, per_point) do
    from(n in "notes",
      where: n.id >= type(^from_int(at), Ecto.UUID),
      order_by: n.id,
      limit: ^per_point,
      select: type(n.id, Ecto.UUID)
    )
    |> scope(user_id)
    |> repo.all()
  end

  defp scope(query, nil), do: query
  defp scope(query, user_id), do: where(query, [n], n.user_id == type(^user_id, Ecto.UUID))

  defp to_int(id), do: Ecto.UUID.dump!(id) |> then(fn <<n::128>> -> n end)
  defp from_int(n), do: Ecto.UUID.load!(<<n::128>>)

  # ---- reporting -----------------------------------------------------------

  defp emit(%{checked: checked, drift: drift}) do
    :telemetry.execute([:engram, :bookkeeping, :canary_rows], %{count: checked}, %{})

    :telemetry.execute(
      [:engram, :bookkeeping, :canary_ran],
      %{unix: System.system_time(:second)},
      %{}
    )

    for {invariant, n} <- drift,
        do:
          :telemetry.execute([:engram, :bookkeeping, :drift], %{count: n}, %{invariant: invariant})

    found = for {invariant, n} <- drift, n > 0, do: {invariant, n}

    if found == [] do
      Logger.info(
        "bookkeeping canary clean",
        Metadata.with_category(:info, :oban, checked: checked)
      )
    else
      Logger.warning(
        "bookkeeping canary found drift (counts only)",
        Metadata.with_category(:warning, :oban, [checked: checked] ++ found)
      )
    end
  end
end
