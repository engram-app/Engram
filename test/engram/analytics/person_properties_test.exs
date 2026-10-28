defmodule Engram.Analytics.PersonPropertiesTest do
  use ExUnit.Case, async: true

  alias Engram.Analytics.PersonProperties
  alias Engram.Legal.Seeder

  import ExUnit.CaptureLog

  # Identified analytics starts on the pinned version's effective_date. Pinning
  # it to a version with no date (effective at once) or a date that gives no
  # notice would start linking analytics to accounts without telling anyone.
  test "the pinned privacy version announces identified analytics with 30 days' notice" do
    version = PersonProperties.policy_version()
    meta = get_in(Seeder.version_meta(), ["privacy_policy", version])

    assert %{effective_date: %Date{} = effective} = meta
    assert Date.diff(effective, Date.from_iso8601!(version)) >= 30
  end

  # This case has no sandbox checkout, so the policy lookup's DB read raises:
  # a real failure, not a stub. Identifying traits must be held back.
  describe "shareable_traits/1 when the policy lookup raises" do
    test "holds back email and name, still sends the rest, and logs the exception module" do
      traits = %{email: "a@example.com", name: "A", plan: "pro", vault_count: 2}

      log =
        capture_log(fn ->
          assert PersonProperties.shareable_traits(traits) == %{plan: "pro", vault_count: 2}
        end)

      assert log =~ "policy lookup failed"
      refute log =~ "a@example.com"
    end

    test "drops string-keyed email and name too" do
      traits = %{"email" => "a@example.com", "name" => "A", "plan" => "pro"}

      capture_log(fn ->
        assert PersonProperties.shareable_traits(traits) == %{"plan" => "pro"}
      end)
    end
  end
end
