defmodule Engram.Workers.TrimKeywordFeedTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.ServiceConfig
  alias Engram.Workers.TrimKeywordFeed

  @now ~U[2026-11-26 12:00:00Z]

  setup do
    %{user: insert(:user)}
  end

  # A feed row inserted `age_s` before @now; returns its {xid, seq}.
  defp row(user, age_s) do
    %{rows: [[x, s]]} =
      Repo.query!(
        "INSERT INTO keyword_feed (user_id, op, inserted_at) VALUES ($1, 5, $2) RETURNING xid::text, seq",
        [Ecto.UUID.dump!(to_string(user.id)), DateTime.add(@now, -age_s, :second)]
      )

    {String.to_integer(x), s}
  end

  defp left, do: Repo.query!("SELECT seq FROM keyword_feed ORDER BY seq").rows |> List.flatten()

  defp horizon do
    case Repo.query!("SELECT xid::text, seq FROM keyword_feed_horizon WHERE id = 1").rows do
      [[x, s]] -> {String.to_integer(x), s}
      [] -> nil
    end
  end

  test "an applied row goes after the grace period; a fresh or unapplied one stays", %{user: u} do
    applied = row(u, 3_600)
    {_, fresh_applied} = row(u, 60)
    {_, unapplied} = row(u, 3_600)

    # Cursor at the second row (the sandbox is one transaction, so all three
    # share an xid and order by seq): the third is not applied yet.
    {cx, _} = applied
    stats = TrimKeywordFeed.trim(@now, {cx, fresh_applied})

    assert left() == [fresh_applied, unapplied]
    assert stats.applied == 1 and stats.unapplied == 0
    assert horizon() == applied
  end

  test "a row past the maximum age goes even with a stuck cursor, and moves the horizon",
       %{user: u} do
    expired = row(u, 49 * 3_600)
    {_, kept} = row(u, 3_600)

    stats = TrimKeywordFeed.trim(@now, {0, 0})

    assert left() == [kept]
    assert stats.expired == 1 and stats.unapplied == 1
    assert horizon() == expired
    assert stats.oldest_age_s == 3_600
  end

  test "kwsearch unreachable (no cursor): only the maximum age trims", %{user: u} do
    _ = row(u, 49 * 3_600)
    {_, young} = row(u, 3_600)

    assert %{expired: 1, applied: 0} = TrimKeywordFeed.trim(@now, nil)
    assert left() == [young]
  end

  test "the horizon never moves backwards", %{user: u} do
    first = row(u, 49 * 3_600)
    _ = TrimKeywordFeed.trim(@now, {0, 0})
    Repo.query!("UPDATE keyword_feed_horizon SET seq = seq + 1000")
    bumped = horizon()

    _ = row(u, 49 * 3_600)
    _ = TrimKeywordFeed.trim(@now, {0, 0})
    assert horizon() == bumped and bumped > first
  end

  test "the deletion log is kept for snapshot retention + 7 days", %{user: u} do
    for days <- [38, 36] do
      Repo.query!(
        "INSERT INTO keyword_deletions (user_id, op, inserted_at) VALUES ($1, 5, $2)",
        [Ecto.UUID.dump!(to_string(u.id)), DateTime.add(@now, -days * 86_400, :second)]
      )
    end

    assert %{deletions: 1} = TrimKeywordFeed.trim(@now, nil)
    assert [[1]] = Repo.query!("SELECT count(*) FROM keyword_deletions").rows
  end

  test "the maximum age is config (F2 is not confirmed): 24 h trims a 25 h row", %{user: u} do
    ServiceConfig.put_override(:kwsearch, feed_max_age_h: 24)
    _ = row(u, 25 * 3_600)
    assert %{expired: 1} = TrimKeywordFeed.trim(@now, nil)
  end

  test "no feed and no rows: perform is a no-op and schedules nothing" do
    assert :ok = perform_job(TrimKeywordFeed, %{})
    refute_enqueued(worker: TrimKeywordFeed)
  end

  # Review #14: rows left after the feed is rolled back to off are trimmed
  # all the same (the hashed corpus never stays in RDS with no end date).
  test "feed off but rows left: perform still trims them", %{user: u} do
    Repo.query!(
      "INSERT INTO keyword_feed (user_id, op, inserted_at) VALUES ($1, 5, now() - interval '49 hours')",
      [Ecto.UUID.dump!(to_string(u.id))]
    )

    assert {:ok, %{expired: 1}} = perform_job(TrimKeywordFeed, %{})
    assert left() == []
  end

  # Review #9: the trim's DELETEs reach rows only through `maintenance_all`;
  # a missing policy would delete 0 rows with no error.
  test "as engram_maintenance the trim deletes the expected rows", %{user: u} do
    old = row(u, 49 * 3_600)
    {_, young} = row(u, 60)

    assert {:error, {stats, rows, horizon}} =
             Repo.transaction(fn ->
               Repo.query!("SET LOCAL ROLE engram_maintenance")
               stats = TrimKeywordFeed.trim(@now, nil)
               Repo.rollback({stats, left(), horizon()})
             end)

    assert stats.expired == 1 and rows == [young] and horizon == old
  end

  test "configured: perform trims (kwsearch unreachable) and chains the next run", %{user: u} do
    ServiceConfig.put_override(:keyword_feed, true)

    ServiceConfig.put_override(:kwsearch,
      url: "http://localhost:1",
      allow_http: true,
      token_keys: ["k"],
      timeout_ms: 200
    )

    ServiceConfig.put_override(:kwsearch_req_options, plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

    # perform/1 trims against the real clock, not @now.
    Repo.query!(
      "INSERT INTO keyword_feed (user_id, op, inserted_at) VALUES ($1, 5, now() - interval '49 hours')",
      [Ecto.UUID.dump!(to_string(u.id))]
    )

    assert {:ok, %{expired: 1}} = perform_job(TrimKeywordFeed, %{})
    assert_enqueued(worker: TrimKeywordFeed)
  end
end
