defmodule Engram.SchemaEnumValuesTest do
  # One source of truth per enum-like text column, ahead of its DB CHECK.
  use ExUnit.Case, async: true

  alias Engram.Accounts.User
  alias Engram.Logs.PersistPolicy
  alias Engram.Notes.Note

  test "the value lists" do
    assert User.roles() == ~w(admin member operator)
    assert Note.parse_statuses() == ~w(ok degraded)
    assert Note.index_tiers() == ~w(floor floor_paid)
    assert PersistPolicy.levels() == ~w(debug info warn error other)
  end

  test "a note's parse_status outside the list is refused" do
    attrs = %{kind: "note", parse_status: "broken"}
    refute Note.changeset(%Note{}, attrs).errors[:parse_status] == nil

    assert Note.changeset(%Note{}, %{attrs | parse_status: "degraded"}).errors[:parse_status] ==
             nil
  end

  test "every level metric_level/1 returns is in levels/0" do
    for level <- ["debug", "warn", "FATAL", "", nil, 7] do
      assert PersistPolicy.metric_level(level) in PersistPolicy.levels()
    end
  end
end
