defmodule Engram.UsageMetersFillfactorTest do
  # usage_meters is one hot row per user, updated on every note create and
  # delete and on activity stamps. A counter update changes no indexed
  # column, so it can be HOT (in place, no index entries) whenever its page
  # has room: fillfactor 80 keeps that room. Prod was already about 92% HOT
  # (2026-10-20 audit); the misses are pages filled to 100%.
  use Engram.DataCase, async: true

  alias Engram.UsageMeters

  test "the table keeps 20% of each page free" do
    %{rows: [[opts]]} =
      Repo.query!("SELECT reloptions FROM pg_class WHERE relname = 'usage_meters'")

    assert "fillfactor=80" in (opts || [])
  end

  test "a note-count increment is a HOT update" do
    user = insert(:user)
    :ok = UsageMeters.inc_notes_count(user.id, 1)

    hot = fn ->
      %{rows: [[n]]} =
        Repo.query!(
          "SELECT n_tup_hot_upd FROM pg_stat_xact_user_tables WHERE relname = 'usage_meters'"
        )

      n
    end

    before = hot.()
    :ok = UsageMeters.inc_notes_count(user.id, 1)
    assert hot.() == before + 1
  end
end
