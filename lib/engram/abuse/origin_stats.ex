defmodule Engram.Abuse.OriginStats do
  @moduledoc """
  Pricing v2 §E — per-user daily counters keyed by request-origin class.

  Powers two consumers:

    1. Mix task `mix engram.abuse.account_origin` — per-account breakdown for
       manual review.
    2. `Engram.Workers.OriginAbuseSweep` cron — fires telemetry when a Pro
       account exceeds fair-use thresholds for 3 consecutive days.

  Telemetry-only at launch per work-order §E decision. No request-layer
  throttling, no auto-suspend. Ops reviews the alert, contacts the customer.
  """

  import Ecto.Query
  alias Engram.Abuse.OriginClassifier
  alias Engram.Repo

  require Logger

  defmodule Row do
    use Ecto.Schema

    @primary_key false
    schema "client_origin_stats" do
      field :user_id, Ecto.UUID
      field :day, :date
      field :fingerprint_class, :string
      field :request_count, :integer, default: 0
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end
  end

  @table __MODULE__.Buffer
  @chunk 5_000

  @doc """
  Records one request from a user, classifying the user-agent and bumping an
  in-memory counter keyed by `{day, user_id, class}`. Makes zero queries; the
  `OriginStats.Buffer` process flushes the counters to `client_origin_stats`
  every 30s (readers lag by up to that).

  Returns `:ok` always (best-effort instrumentation; never raises).
  """
  @spec record(Ecto.UUID.t(), String.t() | nil) :: :ok
  def record(user_id, user_agent) when is_binary(user_id) do
    class = OriginClassifier.classify(user_agent) |> Atom.to_string()
    key = {Date.utc_today(), user_id, class}

    _ = :ets.update_counter(@table, key, 1, {key, 0})
    :ok
  rescue
    # Table absent (buffer not started yet / restarting): drop the count rather
    # than fail the caller's MCP request. A rescue, not a whereis check, so a
    # buffer dying between check and update can't raise into the request.
    ArgumentError -> :ok
  end

  @doc """
  Writes buffered counters to the table and resets them. `:all` (the buffer's
  timer and shutdown), or a user id / list of ids (tests flush only their own,
  so async tests never write another test's rows).

  The table has no RLS (see `rls_coverage_test`), so the buffer process can
  write rows for many users without a tenant set. Runs in the caller's process.

  Each chunk is ONE statement that joins the buffered values to `users`, so a
  deleted user's counts (FK `ON DELETE CASCADE`) are skipped without failing
  anyone else's. A chunk that still fails (DB down) is logged and dropped.
  """
  @spec flush(:all | Ecto.UUID.t() | [Ecto.UUID.t()]) :: :ok
  def flush(who \\ :all) do
    if :ets.whereis(@table) == :undefined do
      :ok
    else
      keys = for {{_, uid, _} = key, _} <- :ets.tab2list(@table), wanted?(who, uid), do: key
      # take/2 per key: atomic read-and-delete, so concurrent increments between
      # the listing and the take land in the take or in a fresh counter.
      rows = for key <- keys, [{_, n}] <- [:ets.take(@table, key)], do: row(key, n)

      rows
      |> Enum.chunk_every(@chunk)
      |> Enum.each(&insert_chunk/1)
    end
  end

  defp wanted?(:all, _), do: true
  defp wanted?(ids, uid) when is_list(ids), do: uid in ids
  defp wanted?(id, uid), do: id == uid

  defp row({day, user_id, class}, n), do: {Ecto.UUID.dump!(user_id), day, class, n}

  @upsert """
  INSERT INTO client_origin_stats (user_id, day, fingerprint_class, request_count, created_at, updated_at)
  SELECT v.user_id, v.day, v.class, v.n, $5, $5
  FROM unnest($1::uuid[], $2::date[], $3::text[], $4::bigint[]) AS v(user_id, day, class, n)
  JOIN users u ON u.id = v.user_id
  ON CONFLICT (user_id, day, fingerprint_class)
  DO UPDATE SET request_count = client_origin_stats.request_count + EXCLUDED.request_count,
                updated_at = EXCLUDED.updated_at
  """

  defp insert_chunk(rows) do
    uids = Enum.map(rows, &elem(&1, 0))
    days = Enum.map(rows, &elem(&1, 1))
    classes = Enum.map(rows, &elem(&1, 2))
    ns = Enum.map(rows, &elem(&1, 3))
    now = NaiveDateTime.utc_now()
    _ = Repo.query!(@upsert, [uids, days, classes, ns, now])
    :ok
  rescue
    e ->
      Logger.warning("origin stats flush dropped #{length(rows)} rows: #{Exception.message(e)}")
  catch
    :exit, reason ->
      Logger.warning("origin stats flush dropped #{length(rows)} rows: exit #{inspect(reason)}")
  end

  @doc false
  def table, do: @table

  @doc """
  Returns a list of `{day, class, count}` for the user over the last `days`,
  ordered by `day` desc then `count` desc.
  """
  @spec summary(Ecto.UUID.t(), pos_integer()) :: [
          %{day: Date.t(), class: String.t(), count: integer()}
        ]
  def summary(user_id, days) when is_binary(user_id) and is_integer(days) and days > 0 do
    cutoff = Date.add(Date.utc_today(), -days + 1)

    Repo.all(
      from(r in Row,
        where: r.user_id == ^user_id and r.day >= ^cutoff,
        order_by: [desc: r.day, desc: r.request_count],
        select: %{day: r.day, class: r.fingerprint_class, count: r.request_count}
      ),
      skip_tenant_check: true
    )
  end

  @doc """
  Returns `{total, by_class}` for a single day. `by_class` is a map of
  class-string to count.
  """
  @spec day_totals(Ecto.UUID.t(), Date.t()) :: {integer(), %{String.t() => integer()}}
  def day_totals(user_id, %Date{} = day) do
    rows =
      Repo.all(
        from(r in Row,
          where: r.user_id == ^user_id and r.day == ^day,
          select: {r.fingerprint_class, r.request_count}
        ),
        skip_tenant_check: true
      )

    by_class = Map.new(rows)
    total = by_class |> Map.values() |> Enum.sum()
    {total, by_class}
  end

  @doc """
  Returns user_ids whose total daily request count exceeded `cap` on
  EACH of the last `consecutive` days (UTC).
  """
  @spec users_exceeding_cap(pos_integer(), pos_integer()) :: [Ecto.UUID.t()]
  def users_exceeding_cap(cap, consecutive)
      when is_integer(cap) and is_integer(consecutive) and consecutive > 0 do
    days = for offset <- 0..(consecutive - 1), do: Date.add(Date.utc_today(), -offset)
    earliest = Enum.min(days, Date)

    candidates =
      Repo.all(
        from(r in Row,
          where: r.day >= ^earliest,
          group_by: [r.user_id, r.day],
          having: sum(r.request_count) > ^cap,
          select: {r.user_id, r.day}
        ),
        skip_tenant_check: true
      )

    needed = MapSet.new(days)

    candidates
    |> Enum.group_by(fn {uid, _} -> uid end, fn {_, day} -> day end)
    |> Enum.filter(fn {_uid, hit_days} -> MapSet.subset?(needed, MapSet.new(hit_days)) end)
    |> Enum.map(fn {uid, _} -> uid end)
  end
end
