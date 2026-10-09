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
    :ets.update_counter(@table, key, 1, {key, 0})
    :ok
  rescue
    # Table absent (buffer not started yet / restarting): drop the count.
    ArgumentError -> :ok
  end

  @doc """
  Writes buffered counters to the table and resets them. `:all` (the buffer's
  timer and shutdown) or one user's id (tests flush only their own, so async
  tests never write another test's rows).

  The table has no RLS (see `rls_coverage_test`), so the buffer process can
  write rows for many users without a tenant set. Runs in the caller's process.
  A failed insert is logged and its counts dropped (a deleted user's FK would
  otherwise poison every later flush).
  """
  @spec flush(:all | Ecto.UUID.t()) :: :ok
  def flush(who \\ :all) do
    pattern = if who == :all, do: :_, else: who
    counts = :ets.select(@table, [{{{:_, pattern, :_}, :_}, [], [:"$_"]}])
    # take/2 per key: atomic read-and-delete, so concurrent increments between
    # the select and the take land in the take or in a fresh counter.
    rows = for {key, _} <- counts, [{_, n}] <- [:ets.take(@table, key)], do: row(key, n)

    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.each(&insert_chunk/1)
  rescue
    ArgumentError -> :ok
  end

  defp row({day, user_id, class}, n) do
    now = DateTime.utc_now()

    %{
      user_id: user_id,
      day: day,
      fingerprint_class: class,
      request_count: n,
      created_at: now,
      updated_at: now
    }
  end

  defp insert_chunk(rows) do
    Repo.insert_all(
      Row,
      rows,
      on_conflict:
        from(r in Row,
          update: [
            set: [
              request_count: fragment("? + EXCLUDED.request_count", r.request_count),
              updated_at: fragment("EXCLUDED.updated_at")
            ]
          ]
        ),
      conflict_target: [:user_id, :day, :fingerprint_class],
      skip_tenant_check: true
    )
  rescue
    e ->
      Logger.warning("origin stats flush dropped #{length(rows)} rows: #{Exception.message(e)}")
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
