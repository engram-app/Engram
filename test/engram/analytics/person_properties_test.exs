defmodule Engram.Analytics.PersonPropertiesTest do
  use ExUnit.Case, async: true

  alias Engram.Analytics.PersonProperties
  alias Engram.Legal.Seeder

  # Identified analytics starts on the pinned version's effective_date. Pinning
  # it to a version with no date (effective at once) or a date that gives no
  # notice would start linking analytics to accounts without telling anyone.
  test "the pinned privacy version announces identified analytics with 30 days' notice" do
    version = PersonProperties.policy_version()
    meta = get_in(Seeder.version_meta(), ["privacy_policy", version])

    assert %{effective_date: %Date{} = effective} = meta
    assert Date.diff(effective, Date.from_iso8601!(version)) >= 30
  end
end
