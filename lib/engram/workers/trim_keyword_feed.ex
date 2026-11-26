defmodule Engram.Workers.TrimKeywordFeed do
  @moduledoc """
  Keeps the hashed keyword corpus out of the database (security F2/F8): the
  `keyword_feed` outbox is trimmed minutes after kwsearch applies it, and
  never kept past a hard maximum age, whatever a stuck consumer says.

  Each run, as the maintenance role (`Repo.maintenance/0`):

    1. rows at or below kwsearch's applied cursor (`GET /cursor`) and older
       than `:feed_trim_grace_min` (10) go;
    2. rows older than `:feed_max_age_h` go regardless; those above the cursor
       (all of them when kwsearch is unreachable) were never applied, and
       their count is emitted as `unapplied`;
       `keyword_feed_horizon` then moves to the highest `(xid, seq)` ever
       trimmed: a kwsearch whose cursor is below it (stuck, or restored from
       an old snapshot) reads that as a gap and reports not up until a rebuild;
    3. `keyword_deletions` rows older than `:snapshot_retention_days` (30)
       plus 7 days go (a restored snapshot needs every delete since it);
    4. the age of the oldest feed row is emitted (alert at half the maximum).

  `:feed_max_age_h` defaults to 48. That horizon is the roadmap's
  RECOMMENDED F2 design and is NOT yet confirmed by the owner: it is a config
  value so the decision changes no code. A restore older than it rebuilds
  through the bulk path (P2 part 2), never through the feed.

  Does nothing unless the Tantivy keyword store is configured (self-host and
  the default config write no feed rows). Where it is, each run schedules
  the next one #{div(300, 60)} minutes out; the hourly cron entry restarts
  the chain if a run was lost.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 240, states: [:available, :scheduled]]

  alias Engram.KeywordStore.Tantivy
  alias Engram.KeywordStore.Tantivy.Client
  alias Engram.Maintenance.Prune
  alias Engram.Repo

  @every_s 300
  @batch 10_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Tantivy.configured?() do
      result =
        Repo.maintenance_only("TrimKeywordFeed", "keyword_feed would read 0 rows", fn ->
          {:ok, trim(DateTime.utc_now(), applied_cursor())}
        end)

      _ = %{} |> new(schedule_in: @every_s) |> Oban.insert()
      result
    else
      :ok
    end
  end

  @doc false
  # `cursor` nil: kwsearch unreachable, so nothing counts as applied.
  def trim(now, cursor) do
    cfg = Engram.ServiceConfig.get(:kwsearch, [])
    grace = DateTime.add(now, -Keyword.get(cfg, :feed_trim_grace_min, 10) * 60, :second)
    max_age = DateTime.add(now, -Keyword.get(cfg, :feed_max_age_h, 48) * 3600, :second)

    log_cutoff =
      DateTime.add(now, -(Keyword.get(cfg, :snapshot_retention_days, 30) + 7) * 86_400, :second)

    cursor = cursor || {0, 0}
    {cx, cs} = cursor
    repo = Repo.maintenance()

    applied =
      batched(
        repo,
        """
        DELETE FROM keyword_feed WHERE seq IN (
          SELECT seq FROM keyword_feed
          WHERE (xid, seq) <= ($1::text::xid8, $2) AND inserted_at < $3
          ORDER BY xid, seq LIMIT #{@batch})
        RETURNING xid::text, seq
        """,
        [Integer.to_string(cx), cs, grace]
      )

    # Past the maximum age: gone even if kwsearch never applied them.
    expired =
      batched(
        repo,
        """
        DELETE FROM keyword_feed WHERE seq IN (
          SELECT seq FROM keyword_feed WHERE inserted_at < $1
          ORDER BY inserted_at LIMIT #{@batch})
        RETURNING xid::text, seq
        """,
        [max_age]
      )

    # The horizon is the highest (xid, seq) ever trimmed, applied or not: a
    # node whose cursor is below it (stuck, or restored from an old
    # snapshot) is missing rows the feed no longer holds.
    applied
    |> Kernel.++(expired)
    |> Enum.max(fn -> nil end)
    |> horizon(repo)

    logged =
      batched(
        repo,
        """
        DELETE FROM keyword_deletions WHERE seq IN (
          SELECT seq FROM keyword_deletions WHERE inserted_at < $1
          ORDER BY inserted_at LIMIT #{@batch})
        RETURNING xid::text, seq
        """,
        [log_cutoff]
      )

    %{rows: [[oldest]]} =
      repo.query!(
        "SELECT coalesce(extract(epoch FROM $1::timestamptz - min(inserted_at)), 0)::bigint FROM keyword_feed",
        [now]
      )

    stats = %{
      applied: length(applied),
      expired: length(expired),
      unapplied: Enum.count(expired, &(&1 > cursor)),
      deletions: length(logged),
      oldest_age_s: oldest
    }

    :telemetry.execute([:engram, :keyword_feed, :trim], stats, %{})
    stats
  end

  # One bounded DELETE repeated while a batch comes back full, at most
  # `Prune.max_batches/0` per run (`Prune.batched/3`'s loop), keeping every
  # deleted `{xid, seq}` (the horizon needs them).
  defp batched(repo, sql, params, left \\ Prune.max_batches(), acc \\ [])

  defp batched(_repo, _sql, _params, 0, acc), do: acc

  defp batched(repo, sql, params, left, acc) do
    rows = for [x, s] <- repo.query!(sql, params).rows, do: {String.to_integer(x), s}
    acc = rows ++ acc
    if length(rows) >= @batch, do: batched(repo, sql, params, left - 1, acc), else: acc
  end

  defp horizon(nil, _repo), do: :ok

  defp horizon({x, s}, repo) do
    repo.query!(
      """
      INSERT INTO keyword_feed_horizon (id, xid, seq, updated_at) VALUES (1, $1::text::xid8, $2, now())
      ON CONFLICT (id) DO UPDATE SET xid = EXCLUDED.xid, seq = EXCLUDED.seq, updated_at = now()
      WHERE (keyword_feed_horizon.xid, keyword_feed_horizon.seq) < (EXCLUDED.xid, EXCLUDED.seq)
      """,
      [Integer.to_string(x), s]
    )

    :ok
  end

  defp applied_cursor do
    case Client.cursor() do
      {:ok, cursor} -> cursor
      {:error, _} -> nil
    end
  end
end
