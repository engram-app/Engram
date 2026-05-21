defmodule Engram.Repo.Migrations.UserLimitOverridesBackfillTest do
  @moduledoc """
  Pin the user_overrides → user_limit_overrides backfill SQL embedded in the
  20260521013947_create_user_limit_overrides migration. The migration itself
  ran once in the test DB setup and dropped user_overrides; we recreate the
  legacy table inside a test transaction (rolled back by DataCase) to exercise
  the same SQL against synthetic legacy rows.
  """
  use Engram.DataCase, async: false

  alias Engram.Billing.UserLimitOverride
  alias Engram.Repo

  @backfill_sql """
  INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by, set_at)
  SELECT o.user_id,
         k.key,
         jsonb_build_object('v', o.overrides -> k.key),
         COALESCE(o.reason, 'pre-v2 override'),
         'backfill:2026-05-20',
         o.created_at
  FROM legacy_user_overrides o
  CROSS JOIN LATERAL jsonb_object_keys(o.overrides) AS k(key)
  WHERE o.overrides -> k.key IS NOT NULL
  """

  setup do
    Repo.query!("DROP TABLE IF EXISTS legacy_user_overrides")

    Repo.query!("""
    CREATE TABLE legacy_user_overrides (
      user_id BIGINT NOT NULL,
      overrides JSONB NOT NULL,
      reason TEXT,
      created_at TIMESTAMP NOT NULL DEFAULT NOW()
    )
    """)

    :ok
  end

  defp run_backfill, do: Repo.query!(@backfill_sql)

  # Postgrex binds `$N::jsonb` parameters as JSON-string scalars rather than
  # parsing the text into a JSONB object — defeats jsonb_object_keys. Inline
  # the literal directly; safe here because overrides_map is test-controlled.
  defp seed_legacy(user_id, overrides_map, opts \\ []) do
    json = Jason.encode!(overrides_map) |> String.replace("'", "''")
    reason_sql = if r = opts[:reason], do: "'#{r}'", else: "NULL"

    Repo.query!(
      "INSERT INTO legacy_user_overrides (user_id, overrides, reason) " <>
        "VALUES (#{user_id}, '#{json}'::jsonb, #{reason_sql})"
    )
  end

  describe "backfill SQL" do
    test "fans out a single multi-key blob into one row per key" do
      user = insert(:user)
      seed_legacy(user.id, %{"vaults_cap" => 3, "notes_cap" => 500}, reason: "ops")

      run_backfill()

      rows =
        UserLimitOverride
        |> Repo.all()
        |> Enum.filter(&(&1.user_id == user.id))

      assert length(rows) == 2

      by_key = Map.new(rows, &{&1.key, &1})
      assert by_key["vaults_cap"].value == %{"v" => 3}
      assert by_key["notes_cap"].value == %{"v" => 500}
      assert by_key["vaults_cap"].reason == "ops"
      assert by_key["vaults_cap"].set_by == "backfill:2026-05-20"
    end

    test "wraps each value in {\"v\": ...} envelope" do
      user = insert(:user)
      seed_legacy(user.id, %{"reranker_enabled" => true, "starred_quota" => 0})

      run_backfill()

      rows =
        UserLimitOverride
        |> Repo.all()
        |> Enum.filter(&(&1.user_id == user.id))

      values = Enum.into(rows, %{}, &{&1.key, &1.value})
      assert values["reranker_enabled"] == %{"v" => true}
      assert values["starred_quota"] == %{"v" => 0}
    end

    test "defaults reason to 'pre-v2 override' when legacy reason is NULL" do
      user = insert(:user)
      seed_legacy(user.id, %{"vaults_cap" => 5})

      run_backfill()

      row = Repo.get_by!(UserLimitOverride, user_id: user.id, key: "vaults_cap")
      assert row.reason == "pre-v2 override"
    end

    test "is a no-op when legacy table is empty" do
      run_backfill()
      assert Repo.aggregate(UserLimitOverride, :count) == 0
    end

    test "JSON null values are preserved as {\"v\": nil} (NOT skipped by WHERE filter)" do
      user = insert(:user)
      seed_legacy(user.id, %{"vaults_cap" => 5, "notes_cap" => nil})

      run_backfill()

      rows =
        UserLimitOverride
        |> Repo.all()
        |> Enum.filter(&(&1.user_id == user.id))

      values = Enum.into(rows, %{}, &{&1.key, &1.value})
      assert values["vaults_cap"] == %{"v" => 5}
      assert values["notes_cap"] == %{"v" => nil}
    end
  end
end
