defmodule Engram.Abuse.OriginStatsTest do
  use Engram.DataCase, async: true

  alias Engram.Abuse.OriginStats

  describe "record/2" do
    test "stamps a new row on first call" do
      user = insert(:user)

      :ok = OriginStats.record(user.id, "Engram-Obsidian/0.5.0")

      {total, by_class} = OriginStats.day_totals(user.id, Date.utc_today())
      assert total == 1
      assert by_class["plugin"] == 1
    end

    test "increments via on_conflict on repeat calls (no read-modify-write race)" do
      user = insert(:user)

      for _ <- 1..5, do: OriginStats.record(user.id, "Engram-Obsidian/0.5.0")

      {total, by_class} = OriginStats.day_totals(user.id, Date.utc_today())
      assert total == 5
      assert by_class["plugin"] == 5
    end

    test "tracks distinct classes in separate rows" do
      user = insert(:user)

      OriginStats.record(user.id, "Engram-Obsidian/0.5.0")
      OriginStats.record(user.id, "Engram-Web/0.5.155")
      OriginStats.record(user.id, "Engram-Obsidian/0.5.0")
      OriginStats.record(user.id, "curl/7.81")

      {total, by_class} = OriginStats.day_totals(user.id, Date.utc_today())
      assert total == 4
      assert by_class["plugin"] == 2
      assert by_class["web_spa"] == 1
      assert by_class["unknown"] == 1
    end

    test "nil user-agent classifies as :unknown" do
      user = insert(:user)
      :ok = OriginStats.record(user.id, nil)

      {1, %{"unknown" => 1}} = OriginStats.day_totals(user.id, Date.utc_today())
    end
  end

  describe "summary/2" do
    test "returns rows ordered by day desc then count desc" do
      user = insert(:user)
      OriginStats.record(user.id, "Engram-Obsidian/0.5.0")
      OriginStats.record(user.id, "Engram-Obsidian/0.5.0")
      OriginStats.record(user.id, "Engram-Web/0.5.155")

      rows = OriginStats.summary(user.id, 7)

      assert length(rows) == 2
      assert hd(rows).day == Date.utc_today()
      # plugin (count 2) before web_spa (count 1) on the same day
      assert hd(rows).class == "plugin"
    end

    test "filters by day window" do
      user = insert(:user)
      OriginStats.record(user.id, "Engram-Obsidian/0.5.0")

      # Plant a row from 30 days ago
      old_day = Date.add(Date.utc_today(), -30)
      now = DateTime.utc_now()

      Engram.Repo.insert_all(
        OriginStats.Row,
        [
          %{
            user_id: user.id,
            day: old_day,
            fingerprint_class: "plugin",
            request_count: 99,
            created_at: now,
            updated_at: now
          }
        ],
        skip_tenant_check: true
      )

      assert length(OriginStats.summary(user.id, 7)) == 1
      assert length(OriginStats.summary(user.id, 60)) == 2
    end
  end

  describe "users_exceeding_cap/2" do
    test "returns users over the cap for N consecutive days" do
      heavy = insert(:user)
      light = insert(:user)

      now = DateTime.utc_now()
      today = Date.utc_today()
      days = [today, Date.add(today, -1), Date.add(today, -2)]

      # Heavy user: 11k on each of last 3 days
      rows_heavy =
        for d <- days do
          %{
            user_id: heavy.id,
            day: d,
            fingerprint_class: "unknown",
            request_count: 11_000,
            created_at: now,
            updated_at: now
          }
        end

      # Light user: 1k on each
      rows_light =
        for d <- days do
          %{
            user_id: light.id,
            day: d,
            fingerprint_class: "plugin",
            request_count: 1_000,
            created_at: now,
            updated_at: now
          }
        end

      Engram.Repo.insert_all(OriginStats.Row, rows_heavy ++ rows_light, skip_tenant_check: true)

      assert OriginStats.users_exceeding_cap(10_000, 3) == [heavy.id]
    end

    test "does NOT include users who exceeded on only 2 of 3 days" do
      user = insert(:user)
      now = DateTime.utc_now()
      today = Date.utc_today()

      rows = [
        %{
          user_id: user.id,
          day: today,
          fingerprint_class: "unknown",
          request_count: 20_000,
          created_at: now,
          updated_at: now
        },
        %{
          user_id: user.id,
          day: Date.add(today, -1),
          fingerprint_class: "unknown",
          request_count: 20_000,
          created_at: now,
          updated_at: now
        },
        # day -2 omitted entirely
        %{
          user_id: user.id,
          day: Date.add(today, -3),
          fingerprint_class: "unknown",
          request_count: 20_000,
          created_at: now,
          updated_at: now
        }
      ]

      Engram.Repo.insert_all(OriginStats.Row, rows, skip_tenant_check: true)

      assert OriginStats.users_exceeding_cap(10_000, 3) == []
    end
  end
end
