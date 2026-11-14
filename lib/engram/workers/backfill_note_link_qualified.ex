defmodule Engram.Workers.BackfillNoteLinkQualified do
  @moduledoc """
  The `NoteLinkQualified` backfill (O(1) folder rename plan S4.6,
  Engram#2523): one fleet-wide chain that walks `note_links` in primary-key
  windows (`Engram.Backfill.IdWindows` through `PacedChain`) and sets
  `qualified` (`Engram.Links.qualified?/1` of the decrypted target) on every
  row still NULL. Started by `Engram.DataMigrations.NoteLinkQualified`.

  ## Pace

  A hop fixes at most `NoteLinkQualified.max_rows/0` rows (default 3,000) or
  works 30 s, at most `writes_per_s/0` rows a second (default 150), 250 ms
  between 200-id windows, then schedules its successor 45 s out with its
  cursor in the args (`:crdt_backfill`, concurrency 1). The pressure gate
  (`Throttle.pressure/0`) holds a hop 45 s, writing nothing.

  ## A window

  One probe of the window's NULL rows by primary key (`stale_query/1`),
  read-only. Then, per tenant, one transaction under `lock_timeout = '2s'`
  and `statement_timeout = '5s'`: `FOR NO KEY UPDATE SKIP LOCKED` of that
  tenant's rows (a row a writer holds is left, never waited on) and one
  UPDATE per value (`id = ANY`, primary key only) that only fills a NULL (`write_query/2`). No
  compare-and-set on the ciphertext: a row's target text never changes in
  place (an extraction deletes and re-inserts; a DEK rotation re-encrypts
  the same text), so a classification stays right.

  ## Done

  As `BackfillNoteNames`: a walk that fixed rows starts a new one; a clean
  walk closes the ledger while every node writes the column
  (`NoteLinkQualified.fleet_ready?/1`); a walk that only left rows (an owner
  mid rotation) stops and the next waits a day. The kill switch is read
  before every window.
  """
  use Oban.Worker,
    queue: :crdt_backfill,
    priority: 3,
    max_attempts: 5,
    unique: Engram.Jobs.unique(__MODULE__)

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Backfill.{IdWindows, PacedChain, Throttle}
  alias Engram.Crypto
  alias Engram.DataMigrations
  alias Engram.DataMigrations.NoteLinkQualified
  alias Engram.Links
  alias Engram.Links.NoteLink
  alias Engram.Logger.Metadata
  alias Engram.Repo

  require Logger

  @batch_size 200
  @budget_ms 30_000
  @pace_s 45

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    cond do
      not NoteLinkQualified.enabled?() ->
        :ok

      reason = Throttle.pressure() ->
        {:ok, _} = Oban.insert(new(args, schedule_in: @pace_s))
        Throttle.log_pass("note_link_qualified", written: 0, held: reason, elapsed_ms: 0)

      true ->
        case hop(args, max_rows: NoteLinkQualified.max_rows()) do
          {:next, next} ->
            {:ok, _} = Oban.insert(new(next, schedule_in: @pace_s))
            :ok

          _done_or_stopped ->
            :ok
        end
    end
  end

  @doc """
  One hop from `args` (`%{}` starts a walk). `{:next, args}`, `:done` (ledger
  closed) or `:stopped`. Options (tests): `:max_rows`, `:writes_per_s`,
  `:batch_size`, `:budget_ms`, `:pause_ms`, `:fleet`, `:clock`, `:sleep`.
  """
  @spec hop(map(), keyword()) :: {:next, map()} | :done | :stopped
  def hop(args, opts \\ []) do
    fleet = Keyword.get(opts, :fleet, [])
    walk_start? = is_nil(args["from"])

    if walk_start? and not NoteLinkQualified.fleet_ready?(fleet),
      do: :stopped,
      else: do_hop(args, opts, fleet)
  end

  defp do_hop(args, opts, fleet) do
    clock = Keyword.get(opts, :clock, &Throttle.now_ms/0)
    started = clock.()
    max_rows = Keyword.get(opts, :max_rows, NoteLinkQualified.max_rows())
    deadline = PacedChain.deadline(Keyword.get(opts, :budget_ms, @budget_ms))

    st = %{
      walk_fixed: args["fixed"] == true,
      walk_left: args["left"] == true,
      hop_fixed: 0,
      windows: 0
    }

    step = fn ids, ctx, st ->
      {fixed, left} = heal_window(ids, ctx)

      %{
        st
        | hop_fixed: st.hop_fixed + fixed,
          windows: st.windows + 1,
          walk_fixed: st.walk_fixed or fixed > 0,
          walk_left: st.walk_left or left
      }
    end

    {result, st} =
      case PacedChain.walk(NoteLink, decode(args["from"]), st, step,
             stop?: fn st -> st.hop_fixed >= max_rows or PacedChain.past?(deadline) end,
             continue?: &NoteLinkQualified.enabled?/0,
             pause_ms: Keyword.get(opts, :pause_ms, PacedChain.pause_ms()),
             writes: & &1.hop_fixed,
             writes_per_s: Keyword.get(opts, :writes_per_s, NoteLinkQualified.writes_per_s()),
             started_ms: started,
             clock: clock,
             sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
             batch_size: Keyword.get(opts, :batch_size, @batch_size),
             fun_in_tenant: false
           ) do
        {:aborted, st} -> {:stopped, st}
        {:stopped, at, st} -> {{:next, args(at, st)}, st}
        {:walked, st} -> finish(st, fleet)
      end

    Throttle.log_pass("note_link_qualified",
      written: st.hop_fixed,
      held: :none,
      elapsed_ms: clock.() - started,
      result: if(match?({:next, _}, result), do: :next, else: result),
      windows: st.windows,
      walk_fixed: st.walk_fixed,
      walk_left: st.walk_left
    )

    result
  end

  defp finish(%{walk_fixed: true} = st, _fleet),
    do: {{:next, %{"from" => nil, "fixed" => false, "left" => false}}, st}

  defp finish(%{walk_left: true} = st, _fleet) do
    :ok = NoteLinkQualified.walked(0)
    {:stopped, st}
  end

  defp finish(st, fleet) do
    if NoteLinkQualified.fleet_ready?(fleet) do
      :ok = DataMigrations.mark_done(NoteLinkQualified.name(), NoteLinkQualified.version())
      {:done, st}
    else
      {:stopped, st}
    end
  end

  defp args(at, st),
    do: %{"from" => encode(at), "fixed" => st.walk_fixed, "left" => st.walk_left}

  defp encode({user_id, after_id}), do: [user_id, after_id]
  defp decode([user_id, after_id]), do: {user_id, after_id}
  defp decode(nil), do: nil

  @doc """
  Classifies the NULL rows among `ids`: one read-only probe, then one
  transaction per tenant (the owner's on the per-user walk, the maintenance
  pool's on the fleet walk). Returns `{written, left?}`: `left?` when a row
  was held by another writer or its owner's key could not load yet.
  """
  @spec heal_window([Ecto.UUID.t()], IdWindows.ctx()) :: {non_neg_integer(), boolean()}
  def heal_window(ids, %{repo: repo, user_id: user_id}) do
    {:ok, stale} = in_tx(repo, user_id, fn -> repo.all(stale_query(ids)) end)

    stale
    |> Enum.group_by(& &1.user_id)
    |> Enum.reduce({0, false}, fn {owner, rows}, {written, left} ->
      case classify(owner, rows) do
        {:later, reason} ->
          deferred(owner, length(rows), reason)
          {written, true}

        quals ->
          {:ok, {n, held?}} = in_tx(repo, user_id || owner, fn -> write(repo, rows, quals) end)
          {written + n, left or held?}
      end
    end)
  end

  # The fleet walk (`user_id` nil, maintenance pool) opens a plain
  # transaction; a per-user walk the owner's tenant. Both bounded.
  defp in_tx(repo, user_id, fun) do
    run = fn ->
      _ = repo.query!("SET LOCAL lock_timeout = '2s'", [])
      _ = repo.query!("SET LOCAL statement_timeout = '5s'", [])
      fun.()
    end

    if repo == Repo, do: Repo.with_tenant(user_id, run), else: repo.transaction(run)
  end

  @doc false
  # The window's rows still NULL, read by primary key (`IdWindows.by_id/2`).
  # Public for the plan test.
  @spec stale_query([Ecto.UUID.t()]) :: Ecto.Query.t()
  def stale_query(ids) do
    from(l in NoteLink,
      where: is_nil(l.qualified),
      select: %{
        id: l.id,
        user_id: l.user_id,
        dek_version: l.dek_version,
        target_text_ciphertext: l.target_text_ciphertext,
        target_text_nonce: l.target_text_nonce
      }
    )
    |> IdWindows.by_id(ids)
  end

  # Per row `qualified?/1` of its target, or `{:later, reason}` for the whole
  # owner. A target that cannot be read (or an owner who can never be read)
  # is `true`: S5 then queues a rewrite rather than skip a link that may
  # need one.
  defp classify(owner, rows) do
    case Crypto.walk_dek(Repo.get(User, owner)) do
      {:ok, dek} ->
        Enum.map(rows, fn row ->
          case Links.decrypt_target(row, dek) do
            nil -> true
            target -> Links.qualified?(target)
          end
        end)

      {:park, reason} ->
        parked(owner, length(rows), reason)
        List.duplicate(true, length(rows))

      {:later, _reason} = later ->
        later
    end
  end

  # `{written, held?}`: rows a concurrent writer holds are skipped.
  defp write(repo, rows, quals) do
    ids = Enum.map(rows, & &1.id)

    unheld =
      from(l in NoteLink,
        where: l.id in ^ids,
        lock: "FOR NO KEY UPDATE SKIP LOCKED",
        select: l.id
      )
      |> repo.all()
      |> MapSet.new()

    written =
      rows
      |> Enum.zip(quals)
      |> Enum.filter(fn {row, _q} -> MapSet.member?(unheld, row.id) end)
      |> Enum.group_by(fn {_row, q} -> q end, fn {row, _q} -> row.id end)
      |> Enum.map(fn {q, ids} -> ids |> write_query(q) |> repo.update_all([]) |> elem(0) end)
      |> Enum.sum()

    {written, MapSet.size(unheld) < length(rows)}
  end

  @doc false
  # Sets `qualified` to `value` on `ids`, only where still NULL: one
  # statement per value, `id = ANY` so it reads the primary key only (an
  # `UPDATE ... FROM unnest(...)` join planned a bitmap scan of the
  # tenant's whole `note_links`). Public for the plan test.
  @spec write_query([Ecto.UUID.t()], boolean()) :: Ecto.Query.t()
  def write_query(ids, value) when is_boolean(value) do
    from(l in NoteLink,
      where: l.id in ^ids and is_nil(l.qualified),
      update: [set: [qualified: ^value]]
    )
  end

  defp parked(owner, count, reason) do
    Logger.warning(
      "note link qualified backfill: owner key unreadable, rows classified qualified",
      Metadata.with_category(:warning, :crypto,
        user_id: owner,
        reason_label: reason,
        total_count: count
      )
    )
  end

  defp deferred(owner, count, reason) do
    Logger.warning(
      "note link qualified backfill: owner key unavailable, rows deferred",
      Metadata.with_category(:warning, :crypto,
        user_id: owner,
        reason_label: reason,
        total_count: count
      )
    )
  end
end
