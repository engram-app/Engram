defmodule Engram.Onboarding.ActionTest do
  use Engram.DataCase, async: true

  alias Engram.Onboarding.Action

  # synthetic bigint; not persisted, no FK enforcement on changeset alone
  @user_id 12_345

  test "accepts every enum value" do
    for action <- [
          "tour_offered_taken",
          "tour_offered_skipped",
          "tour_completed",
          "first_vault_created",
          "plugin_connected",
          "ai_connected"
        ] do
      assert Action.changeset(%Action{}, %{user_id: @user_id, action: action}).valid?
    end
  end

  test "rejects unknown action" do
    cs = Action.changeset(%Action{}, %{user_id: @user_id, action: "bogus"})
    refute cs.valid?
    assert {"is invalid", _} = cs.errors[:action]
  end

  test "requires user_id and action" do
    cs = Action.changeset(%Action{}, %{})
    refute cs.valid?
    assert cs.errors[:user_id]
    assert cs.errors[:action]
  end
end
