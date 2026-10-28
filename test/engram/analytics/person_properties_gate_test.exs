defmodule Engram.Analytics.PersonPropertiesGateTest do
  use Engram.DataCase, async: false

  alias Engram.Analytics.PersonProperties
  alias Engram.Legal.TermsVersion

  setup do
    Engram.Legal.Seeder.seed()
    :ok
  end

  defp policy_effective_on(date) do
    Repo.update_all(
      from(v in TermsVersion, where: v.document == "privacy_policy" and v.version == "2026-10-12"),
      [set: [effective_date: date]],
      skip_tenant_check: true
    )
  end

  defp accepted(attrs \\ []) do
    user = insert(:user, attrs)

    insert(:agreement,
      user: user,
      document: "privacy_policy",
      version: PersonProperties.policy_version()
    )

    user
  end

  defp ids(query),
    do: Repo.cross_tenant(fn -> Repo.maintenance().all(query) end) |> Enum.map(& &1.id)

  describe "before the policy's effective date" do
    setup do
      policy_effective_on(Date.add(Date.utc_today(), 5))
      :ok
    end

    test "a user who accepted it may be identified; one who did not may not" do
      yes = accepted()
      no = insert(:user)

      assert PersonProperties.may_identify?(yes)
      refute PersonProperties.may_identify?(no)
    end

    test "an acceptance of a different privacy version does not count" do
      user = insert(:user)
      insert(:agreement, user: user, document: "privacy_policy", version: "2025-01-01")
      refute PersonProperties.may_identify?(user)
    end

    test "the batch scope holds exactly the accepted, live, non-opted-out users" do
      yes = accepted()
      _no = insert(:user)
      _opted_out = accepted(analytics_opt_out_at: DateTime.utc_now())
      _deleted = accepted(deleted_at: DateTime.utc_now())

      assert ids(PersonProperties.identifiable_users()) == [yes.id]
      assert [{id, _traits}] = PersonProperties.by_user(:identifiable)
      assert id == yes.id
      assert PersonProperties.gated_count() == 1
    end

    test "DailySnapshot's own read still covers every trackable user" do
      accepted()
      insert(:user)
      assert length(PersonProperties.by_user()) == 2
    end
  end

  test "once the policy is in effect everyone trackable is identifiable" do
    policy_effective_on(Date.add(Date.utc_today(), -1))
    a = insert(:user)
    b = accepted()

    assert Enum.sort(ids(PersonProperties.identifiable_users())) == Enum.sort([a.id, b.id])
    assert PersonProperties.may_identify?(a)
    assert PersonProperties.gated_count() == 0
  end
end
