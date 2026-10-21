defmodule Engram.RedundantIndexesTest do
  # Indexes dropped by the 2026-10-20 audit as dead or redundant, and the
  # index each one's lookups use instead. Every write pays for an index;
  # these served nothing another index did not.
  use Engram.DataCase, async: true

  alias Engram.QueryPlan

  @dropped [
    # No predicate on fm_* in Postgres (fm filtering runs in Qdrant): their
    # prod scans were the planner picking any (user_id, vault_id, ...) index.
    "notes_user_id_vault_id_fm_timestamp_index",
    "notes_user_id_vault_id_fm_created_index",
    # Tombstone lookups by path have notes_vault_path_tombstone_index.
    "idx_notes_user_deleted",
    # Left prefixes of a wider index on the same table.
    "idx_attachments_user",
    "user_limit_overrides_user_id_index",
    # user_code is UNIQUE: at most one row to filter on status.
    "device_authorizations_pending_user_code_index"
  ]

  test "the dead and redundant indexes are gone" do
    %{rows: rows} =
      Repo.query!("SELECT indexname FROM pg_indexes WHERE schemaname = 'public'")

    present = MapSet.new(rows, &hd/1)
    assert Enum.filter(@dropped, &MapSet.member?(present, &1)) == []
  end

  defp plan(sql, table), do: QueryPlan.generic_plan(sql, analyze: [table], bitmapscan: false)

  test "user-wide attachment lookups use the wider user-leading index" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    for _ <- 1..200, do: insert(:attachment, user: insert(:user), vault: vault)

    sql = "SELECT id FROM attachments WHERE user_id = $1"

    assert plan(sql, "attachments") =~
             "attachments_user_id_vault_id_basename_hmac_path_length_index"
  end

  test "override lookups by user use the unique (user_id, key) index" do
    sql = "SELECT id FROM user_limit_overrides WHERE user_id = $1"
    assert plan(sql, "user_limit_overrides") =~ "user_limit_overrides_user_id_key_index"
  end

  test "pending device codes are found by the unique user_code index" do
    sql =
      "SELECT id FROM device_authorizations WHERE user_code = $1 AND status = 'pending' " <>
        "AND expires_at > $2"

    assert plan(sql, "device_authorizations") =~ "device_authorizations_user_code_index"
  end
end
