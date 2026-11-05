defmodule Engram.Repo.UtcSessionTest do
  @moduledoc """
  Raw-SQL time writers and readers give the same instant whatever the
  session TimeZone, before AND after the `timestamp` -> `timestamptz`
  conversion (`Engram.Repo.Utc`).

  Every case runs twice under `SET LOCAL TimeZone = 'America/Los_Angeles'`
  (staging's server default): once on today's `timestamp` column, once with
  the column converted to `timestamptz` inside the same transaction, the way
  the conversion migration will. It all runs on a private one-connection
  dynamic repo and rolls back, so the ALTERs never reach another test and no
  other connection caches a plan against the converted type.

  Instants are read back with `extract(epoch FROM col)`, which counts a
  `timestamp` as UTC wall time and never reads the session TimeZone.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Engram.Factory

  alias Engram.Abuse.OriginStats
  alias Engram.Attachments.BulkUpdate
  alias Engram.Insights
  alias Engram.Logs.ClientLog
  alias Engram.Notes.BulkRename
  alias Engram.Repo
  alias Engram.UsageMeters
  alias Engram.Workers.ClientLogsPruner
  alias Engram.Workers.CrdtBloatSweep

  @la "America/Los_Angeles"

  setup do
    {:ok, pool} =
      Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 1, log: false)

    Repo.put_dynamic_repo(pool)

    # The pool is linked to the test process and goes down with it.
    on_exit(fn -> Repo.put_dynamic_repo(Repo) end)

    :ok
  end

  # `fun` runs in one transaction, session in LA, `cols` converted when
  # `type` is :timestamptz. Always rolled back.
  defp in_la(type, cols, fun) do
    {:error, :rolled_back} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL TimeZone = '#{@la}'")

        if type == :timestamptz do
          for {table, col} <- cols do
            Repo.query!(
              "ALTER TABLE #{table} ALTER COLUMN #{col} TYPE timestamptz USING #{col} AT TIME ZONE 'UTC'"
            )
          end
        end

        fun.()
        Repo.rollback(:rolled_back)
      end)
  end

  defp epoch!(table, col, id) do
    %{rows: [[s]]} =
      Repo.query!(
        "SELECT extract(epoch FROM #{col})::float8 FROM #{table} WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    s
  end

  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond) / 1_000_000

  defp assert_instant(got, %DateTime{} = want, slack_s) do
    assert abs(got - unix(want)) <= slack_s,
           "stored #{got}, want #{unix(want)} (off by #{got - unix(want)}s)"
  end

  for type <- [:timestamp, :timestamptz] do
    describe "#{type} column, session in #{@la}" do
      @type_ type

      test "OriginStats.flush stamps created_at/updated_at at now" do
        in_la(
          @type_,
          [{"client_origin_stats", "created_at"}, {"client_origin_stats", "updated_at"}],
          fn ->
            user = insert(:user)
            :ok = OriginStats.record(user.id, "Engram-Obsidian/0.5.0")
            before = DateTime.utc_now()
            OriginStats.flush(user.id)

            %{rows: [[c, u]]} =
              Repo.query!(
                "SELECT extract(epoch FROM created_at)::float8, extract(epoch FROM updated_at)::float8 FROM client_origin_stats WHERE user_id = $1",
                [Ecto.UUID.dump!(user.id)]
              )

            assert_instant(c, before, 5)
            assert_instant(u, before, 5)
          end
        )
      end

      test "UsageMeters.bucket_take stamps updated_at at `now`" do
        in_la(@type_, [{"usage_meters", "updated_at"}], fn ->
          user = insert(:user)
          now = ~U[2026-01-10 07:30:00.000000Z]
          {:ok, _} = UsageMeters.bucket_take(user.id, 1, 10, now: now)
          # Second take: the ON CONFLICT path.
          later = ~U[2026-01-10 09:45:00.000000Z]
          {:ok, _} = UsageMeters.bucket_take(user.id, 1, 10, now: later)

          %{rows: [[u]]} =
            Repo.query!(
              "SELECT extract(epoch FROM updated_at)::float8 FROM usage_meters WHERE user_id = $1",
              [Ecto.UUID.dump!(user.id)]
            )

          assert_instant(u, later, 0.001)
        end)
      end

      test "BulkRename.update! stamps updated_at with the cascade's stamp" do
        in_la(@type_, [{"notes", "updated_at"}], fn ->
          user = insert(:user)
          vault = insert(:vault, user: user)
          note = Engram.Fixtures.insert_note!(user, vault, %{path: "A/x.md", content: "x"})
          stamp = ~U[2026-01-10 07:30:00.123456Z]

          {:ok, :ok} =
            Repo.with_tenant(user.id, fn ->
              BulkRename.update!([{note.id, [path_length: 6]}], [:path_length], note.seq, stamp)
            end)

          assert_instant(epoch!("notes", "updated_at", note.id), stamp, 0.001)
        end)
      end

      test "Attachments.BulkUpdate.stamp_seqs! stamps updated_at at `now`" do
        in_la(@type_, [{"attachments", "updated_at"}], fn ->
          user = insert(:user)
          att = insert(:attachment, user: user, vault: insert(:vault, user: user))
          now = ~U[2026-01-10 07:30:00Z]

          {:ok, [_]} =
            Repo.with_tenant(att.user_id, fn ->
              BulkUpdate.stamp_seqs!([{att.id, att.seq + 1_000}], :touch, now)
            end)

          assert_instant(epoch!("attachments", "updated_at", att.id), now, 0.001)
        end)
      end

      test "ClientLogsPruner deletes only rows past retention" do
        in_la(@type_, [{"client_logs", "created_at"}], fn ->
          prev = Application.get_env(:engram, :client_logs_retention_days)
          Application.put_env(:engram, :client_logs_retention_days, 30)

          try do
            user = insert(:user)
            # 40 days old (gone) and 30 days minus 2 hours old (kept: an
            # 8-hour session-zone shift would delete it).
            for age_s <- [40 * 86_400, 30 * 86_400 - 7_200] do
              ts =
                DateTime.utc_now() |> DateTime.add(-age_s, :second) |> DateTime.truncate(:second)

              {1, _} =
                Repo.insert_all(ClientLog, [
                  %{
                    id: UUIDv7.generate(DateTime.to_unix(ts, :millisecond)),
                    user_id: user.id,
                    ts: ts,
                    level: "info",
                    category: "",
                    message: "x",
                    plugin_version: "",
                    platform: "",
                    created_at: ts
                  }
                ])
            end

            assert {:ok, 1} = ClientLogsPruner.perform(%Oban.Job{args: %{}})
            assert Repo.one(from(l in "client_logs", select: count(l.id))) == 1
          after
            if is_nil(prev),
              do: Application.delete_env(:engram, :client_logs_retention_days),
              else: Application.put_env(:engram, :client_logs_retention_days, prev)
          end
        end)
      end

      test "CrdtBloatSweep binds its window against notes.updated_at" do
        in_la(@type_, [{"notes", "updated_at"}], fn ->
          user = insert(:user)
          vault = insert(:vault, user: user)
          _ = Engram.Fixtures.insert_note!(user, vault, %{path: "b.md", content: "x"})

          assert %{notes: n} = CrdtBloatSweep.measure_and_emit()
          assert n >= 1
        end)
      end

      # Signed up 07:00 UTC (23:00 the day before in LA), active 20:00 UTC
      # the same UTC day: not a day-2 return. Read in LA, the signup date
      # moves back a day and the return counts.
      test "Insights funnel day2_return uses the UTC signup date" do
        in_la(@type_, [{"users", "created_at"}], fn ->
          day = Date.add(Date.utc_today(), -3)
          signup = DateTime.new!(day, ~T[07:00:00], "Etc/UTC")
          user = insert(:user, created_at: signup)
          event!(user.id, "surface_active", DateTime.new!(day, ~T[20:00:00], "Etc/UTC"))

          %{steps: steps} = Insights.report("funnel", :all, days: 30)
          assert step_count(steps, "day2_return") == 0
          assert step_count(steps, "signed_up") == 1
        end)
      end

      # Signed up 03:00 UTC on D (still D-1 in LA), paid 05:00 UTC on D+2:
      # a tenure of 2 UTC days, not 3.
      test "Insights converters tenure counts UTC days" do
        in_la(@type_, [{"users", "created_at"}], fn ->
          day = Date.add(Date.utc_today(), -10)
          user = insert(:user, created_at: DateTime.new!(day, ~T[03:00:00], "Etc/UTC"))
          paid = DateTime.new!(Date.add(day, 2), ~T[05:00:00], "Etc/UTC")
          event!(user.id, "payment_completed", paid, %{"amount_bucket" => "10"})

          assert %{converters: [%{tenure_days: 2}]} =
                   Insights.report("converters", :all, days: 30)
        end)
      end

      test "OAuth.granted_at falls back to the family's first inserted_at" do
        in_la(@type_, [{"oauth_refresh_tokens", "inserted_at"}], fn ->
          user = insert(:user)
          minted = ~U[2026-01-10 07:30:00.000000Z]
          rt = insert(:oauth_refresh_token, user_id: user.id, inserted_at: minted)

          got = Engram.OAuth.granted_at(%{"gid" => rt.family_id, "user_id" => user.id})
          assert DateTime.compare(got, minted) == :eq, "got #{inspect(got)}"
        end)
      end
    end
  end

  # Frontmatter keys' inserted_at is already timestamptz: Ecto's `ago/2`
  # bound a `timestamp` there, which the LA session read 8 hours late, so a
  # just-minted key looked an hour old.
  test "FrontmatterKeys.reap_unused keeps keys younger than min_age, in LA" do
    in_la(:timestamp, [], fn ->
      {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
      {:ok, dek} = Engram.Crypto.get_dek(user)
      {:ok, fk} = Engram.Crypto.dek_filter_key(user)
      names = Map.new(~w(a b), &{Engram.Vector.FilterId.key_hmac(fk, &1), &1})
      {_, 0} = Engram.Notes.FrontmatterKeys.resolve(user.id, dek, names)

      assert Engram.Notes.FrontmatterKeys.reap_unused(3_600) == 0
    end)
  end

  defp event!(user_id, event, at, props \\ %{}) do
    {1, _} =
      Repo.insert_all(Engram.Analytics.Event, [
        %{
          user_id: user_id,
          event: event,
          props: props,
          inserted_at: DateTime.add(at, 0, :microsecond)
        }
      ])
  end

  defp step_count(steps, name) do
    Enum.find_value(steps, 0, fn s -> if s.step == name, do: s.users end)
  end
end
