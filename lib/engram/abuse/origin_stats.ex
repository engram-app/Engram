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

  @doc """
  Records one request from a user, classifying the user-agent and bumping
  the per-day per-class counter. Idempotent under concurrency via
  `on_conflict: [inc:]`.

  Returns `:ok` always (best-effort instrumentation; never raises).
  """
  @spec record(integer(), String.t() | nil) :: :ok
  def record(user_id, user_agent) when is_binary(user_id) do
    class = OriginClassifier.classify(user_agent) |> Atom.to_string()
    today = Date.utc_today()
    now = DateTime.utc_now()

    {_, _} =
      Repo.insert_all(
        Row,
        [
          %{
            user_id: user_id,
            day: today,
            fingerprint_class: class,
            request_count: 1,
            created_at: now,
            updated_at: now
          }
        ],
        on_conflict: [inc: [request_count: 1], set: [updated_at: now]],
        conflict_target: [:user_id, :day, :fingerprint_class],
        skip_tenant_check: true
      )

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Returns a list of `{day, class, count}` for the user over the last `days`,
  ordered by `day` desc then `count` desc.
  """
  @spec summary(integer(), pos_integer()) :: [
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
  @spec day_totals(integer(), Date.t()) :: {integer(), %{String.t() => integer()}}
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
  @spec users_exceeding_cap(pos_integer(), pos_integer()) :: [integer()]
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
