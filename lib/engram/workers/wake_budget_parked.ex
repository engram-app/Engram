defmodule Engram.Workers.WakeBudgetParked do
  @moduledoc """
  Wakes a user's notes parked on the Free embed bucket, at the moment the
  bucket can pay for one (R6).

  A budget-parked note waits with no clock (`EmbedNote.parked_until_edited/0`).
  The bucket refills linearly (`Engram.UsageMeters`), so when it will hold
  enough is computable: `schedule/3` puts one job per user at that time,
  from the park itself (inside the park's transaction) and from this job
  when notes are still parked after a wake. Before, the reconcile sweep read
  every parked user's bucket every 5 minutes; it still calls `wake/2` as the
  backstop (every 3 h), so a lost job costs a delay, never a stuck note.

  The wake is first fit by age (`embed_budget_parked_at`): oldest first, and
  a note that does not fit is skipped so smaller ones behind it still wake.
  The oldest note, if skipped, also wakes with whatever is left as its cap
  (`budget_cap`) once that covers its next chunk (`embed_budget_next`): it
  embeds what fits and parks the rest, so it cannot starve, and no pass runs
  to embed nothing.

  One job per user at a time: `schedule/3` moves a pending job EARLIER
  (`LEAST`) rather than inserting a second, with a plain UPDATE then INSERT,
  never Oban's unique insert (its advisory lock would be held to the end of
  the park's transaction). Two parks racing past the UPDATE insert two jobs;
  the second wakes nothing and stops. Idempotent: a wake re-reads the bucket
  and the parked notes, and an unmetered user (paid, self-host) wakes
  everything and schedules nothing.

  On `events`, the queue for follow-ups a user's action triggers. A rolling
  deploy's old node lacks the worker and fails the job; Oban retries it onto
  a new node, and the sweep's backstop wake covers the release meanwhile.
  """
  use Oban.Worker, queue: :events, max_attempts: 5

  import Ecto.Query

  alias Engram.Billing
  alias Engram.DataMigrations.IndexVersions
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.UsageMeters
  alias Engram.Workers.EmbedNote

  # Parked notes read per wake (`:wake_budget_page` overrides it in tests).
  @wake_page 500

  # A parked note's next chunk when its park did not record one.
  @unknown_next_chunk 512

  # When a page of 500 leaves notes that would fit now: the next page.
  @next_page_seconds 60

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(1)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Engram.Accounts.get_user_with_subscription(user_id) do
      nil -> :ok
      user -> wake(user, backoff_until())
    end
  end

  @doc """
  Schedules `user`'s wake for when the bucket can pay for `need` tokens
  (a park's need, or its next chunk if smaller). Run it inside the park's
  transaction. Nothing for an unmetered user.
  """
  @spec schedule_park(map(), pos_integer() | nil, pos_integer() | nil) :: :ok
  def schedule_park(user, need, next) do
    case capacity(user) do
      nil -> :ok
      cap -> schedule_for(user.id, min(need || 1, next || @unknown_next_chunk), cap)
    end
  end

  @doc """
  Wakes the parked notes that fit what `user`'s bucket holds now (first fit
  by age, see the moduledoc), queues their embeds, and schedules the next
  wake if any stay parked. Also the reconcile sweep's backstop.
  """
  @spec wake(map(), DateTime.t()) :: :ok
  def wake(user, backoff_until) do
    budget = spendable(user)

    # An empty bucket wakes nothing; with its wake already scheduled there is
    # nothing to compute either, so skip the tenant transaction and the
    # queue read (the backstop sweep calls this for every parked user).
    if is_integer(budget) and budget <= 0 and pending?(user.id),
      do: :ok,
      else: wake(user, budget, backoff_until)
  end

  defp wake(user, budget, backoff_until) do
    {woken, left, waiting, full_page?} =
      Repo.with_tenant!(user.id, fn ->
        candidates =
          from(n in IndexVersions.live_notes(),
            where: n.embed_budget_parked == true,
            order_by: [asc_nulls_last: n.embed_budget_parked_at, asc: n.id],
            limit: ^page_size(),
            select: {n.id, n.embed_budget_need, n.embed_budget_next}
          )
          |> Repo.all()

        {woken, left} = fit(candidates, budget)
        ids = Enum.map(woken, &elem(&1, 0))

        _ =
          if ids != [] do
            Repo.update_all(from(n in Note, where: n.kind == "note" and n.id in ^ids),
              set: [embed_budget_parked: nil, embed_retry_after: backoff_until]
            )
          end

        waiting = Enum.reject(candidates, &List.keymember?(woken, elem(&1, 0), 0))
        {woken, left, waiting, length(candidates) == page_size()}
      end)

    caps = Map.new(woken)
    fresh = EmbedNote.reject_already_queued(Map.keys(caps), EmbedNote.backfill_priority())

    _ =
      Oban.insert_all(
        Enum.map(fresh, fn id ->
          EmbedNote.new_debounced(id, user.id,
            priority: EmbedNote.backfill_priority(),
            budget_cap: caps[id]
          )
        end)
      )

    # A full page may hide more parked notes past it: the next page goes
    # next (an upgrade wakes a backlog in pages).
    # Only when the whole page woke (or nothing is metered): a page that
    # stayed parked waits for the bucket like any other, or a Free backlog
    # past 500 notes would re-read 500 rows every minute.
    if full_page? and (waiting == [] or left == :unmetered),
      do: schedule(user.id, DateTime.add(DateTime.utc_now(), @next_page_seconds, :second)),
      else: reschedule(user, left, waiting)
  end

  defp page_size, do: Application.get_env(:engram, :wake_budget_page, @wake_page)

  defp backoff_until,
    do:
      DateTime.add(
        DateTime.utc_now(),
        Engram.Workers.ReconcileEmbeddings.backoff_seconds(),
        :second
      )

  # Nothing left parked, or an unmetered bucket: no clock to wait for.
  # Otherwise the next wake is when what is left after this wake's passes
  # covers the smallest parked need, or the oldest's next chunk (the soonest
  # `fit/2` wakes anything).
  defp reschedule(_user, :unmetered, _waiting), do: :ok
  defp reschedule(_user, _left, []), do: :ok

  defp reschedule(user, left, [{_, _, head_next} | _] = waiting) do
    need = Enum.min([head_next || @unknown_next_chunk | Enum.map(waiting, &(elem(&1, 1) || 1))])

    case capacity(user) do
      nil ->
        :ok

      # Nothing parked can ever fit (every need and the oldest's next chunk
      # exceed the whole bucket, e.g. a tiny override): no clock to wait
      # for. An edit (a new need) or a raised cap re-parks and reschedules.
      cap when need > cap ->
        :ok

      cap ->
        schedule_for(user.id, need, cap, left)
    end
  end

  defp schedule_for(user_id, need, cap, available \\ nil) do
    available = available || UsageMeters.bucket_available(user_id, cap)
    now = DateTime.utc_now()

    # Never past a full bucket: a need above the capacity never fits, and
    # the head's partial wake starts once the bucket is full.
    at =
      UsageMeters.bucket_ready_at(available, min(need, cap), cap, now) ||
        DateTime.add(now, @next_page_seconds, :second)

    schedule(user_id, at)
  end

  defp pending?(user_id), do: Repo.exists?(pending_query(user_id))

  # Not started (`Jobs.pending_states/0`): a running wake schedules its own
  # successor.
  defp pending_query(user_id) do
    from(j in Oban.Job,
      where:
        j.worker == ^inspect(__MODULE__) and j.state in ^Engram.Jobs.pending_states() and
          fragment("? @> ?", j.args, type(^%{"user_id" => user_id}, :map))
    )
  end

  @doc """
  Puts `user_id`'s wake at `at`, or moves a pending one earlier. Plain UPDATE
  then INSERT: safe inside a caller's transaction (see the moduledoc).
  """
  @spec schedule(Ecto.UUID.t(), DateTime.t()) :: :ok
  def schedule(user_id, %DateTime{} = at) do
    {moved, _} =
      user_id
      |> pending_query()
      |> update([j], set: [scheduled_at: fragment("LEAST(?, ?)", j.scheduled_at, ^at)])
      |> Repo.update_all([])

    _ = if moved == 0, do: {:ok, _} = Oban.insert(new(%{user_id: user_id}, scheduled_at: at))
    :ok
  end

  # The bucket's capacity, or nil when unmetered (paid, self-host, a -1 override).
  defp capacity(user) do
    case Billing.effective_limit(user, :embed_token_bucket) do
      cap when is_integer(cap) and cap > 0 -> cap
      _ -> nil
    end
  end

  # What the bucket holds now, or `:unmetered`.
  defp spendable(user) do
    case Billing.effective_limit(user, :embed_token_bucket) do
      cap when is_integer(cap) and cap >= 0 -> UsageMeters.bucket_available(user.id, cap)
      _ -> :unmetered
    end
  end

  @doc false
  # `candidates` (`{id, need, next_chunk}`, oldest first) to wake as
  # `{id, budget_cap}`: every one whose need fits what is left, first fit, cap
  # nil; then the oldest, if it was skipped and what is left covers its next
  # chunk, capped at that remainder. Below that its pass would embed nothing.
  def fitting(candidates, available), do: candidates |> fit(available) |> elem(0)

  # `fitting/2` and what is left in the bucket after it.
  defp fit(candidates, :unmetered), do: {Enum.map(candidates, &{elem(&1, 0), nil}), :unmetered}

  defp fit([], available), do: {[], available}

  defp fit([{head, _, head_next} | _] = candidates, available) do
    # Parked by an older release, need unknown: wake it once anything is left;
    # its pass records the real need.
    {fits, left} =
      Enum.reduce(candidates, {[], available}, fn {id, need, _next}, {fits, left} ->
        need = need || 1
        if need <= left, do: {[{id, nil} | fits], left - need}, else: {fits, left}
      end)

    fits = Enum.reverse(fits)

    if left > 0 and left >= (head_next || @unknown_next_chunk) and
         not List.keymember?(fits, head, 0),
       do: {[{head, left} | fits], 0},
       else: {fits, max(left, 0)}
  end
end
