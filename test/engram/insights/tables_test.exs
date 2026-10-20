defmodule Engram.Insights.TablesTest do
  use Engram.DataCase, async: true

  alias Engram.Analytics.Event
  alias Engram.Insights.RoleChange
  alias Engram.Insights.UserDailyMetric
  alias Engram.Insights.VaultDailyMetric

  defp count(schema), do: Repo.aggregate(schema, :count)

  test "every insights row goes with the user it is about" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    today = Date.utc_today()

    Repo.insert!(%Event{user_id: user.id, event: "note_created", props: %{"surface" => "web"}})
    Repo.insert!(%UserDailyMetric{user_id: user.id, date: today, plan: "free"})

    Repo.insert!(
      %VaultDailyMetric{vault_id: vault.id, user_id: user.id, date: today, notes: 3},
      skip_tenant_check: true
    )

    Repo.insert!(%RoleChange{target_user_id: user.id, action: "grant_operator", scope: "platform"})

    Repo.delete!(user, skip_tenant_check: true)

    assert count(Event) == 0
    assert count(UserDailyMetric) == 0
    assert count(VaultDailyMetric) == 0
    assert count(RoleChange) == 0
  end

  # An objection covers what was already recorded, not only what comes next:
  # withdrawing it later must not bring the old history back.
  test "opting out deletes the user's events and snapshots, and they stay gone" do
    user = insert(:user)
    other = insert(:user)
    vault = insert(:vault, user: user)
    today = Date.utc_today()

    for u <- [user, other] do
      Repo.insert!(%Event{user_id: u.id, event: "note_created", props: %{}})
      Repo.insert!(%UserDailyMetric{user_id: u.id, date: today, plan: "free"})
    end

    Repo.insert!(
      %VaultDailyMetric{vault_id: vault.id, user_id: user.id, date: today, notes: 3},
      skip_tenant_check: true
    )

    {:ok, opted} = Engram.Accounts.set_analytics_opt_out(user)
    {:ok, _} = Engram.Accounts.clear_analytics_opt_out(opted)

    assert Repo.all(from(e in Event, select: e.user_id)) == [other.id]
    assert Repo.all(from(m in UserDailyMetric, select: m.user_id)) == [other.id]
    assert count(VaultDailyMetric) == 0
  end

  test "an anonymous event has no user" do
    event = Repo.insert!(%Event{event: "account_deleted", props: %{"plan" => "free"}})
    assert %Event{user_id: nil, props: %{"plan" => "free"}} = Repo.reload!(event)
    assert %DateTime{} = Repo.reload!(event).inserted_at
  end

  test "one snapshot per user per day" do
    user = insert(:user)
    today = Date.utc_today()
    Repo.insert!(%UserDailyMetric{user_id: user.id, date: today})

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%UserDailyMetric{user_id: user.id, date: today})
    end
  end

  test "an operator grant made from the console keeps its log row when the actor is deleted" do
    actor = insert(:user)
    target = insert(:user)

    row =
      Repo.insert!(%RoleChange{
        actor_id: actor.id,
        target_user_id: target.id,
        action: "grant_operator",
        scope: "platform"
      })

    Repo.delete!(actor, skip_tenant_check: true)
    assert %RoleChange{actor_id: nil} = Repo.reload!(row)
  end
end
