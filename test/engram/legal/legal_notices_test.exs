defmodule Engram.Legal.LegalNoticesTest do
  use Engram.DataCase, async: false

  alias Engram.LegalFixtures
  alias Engram.Legal.VersionCache
  alias Engram.Onboarding

  setup do
    prev_enabled = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)
    LegalFixtures.insert_version(version: "2026-05-19")
    LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
    LegalFixtures.reset_version_cache()

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev_enabled)
      LegalFixtures.reset_version_cache()
    end)

    user = insert(:user, onboarding_profile: %{})
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})
    %{user: user}
  end

  defp publish(attrs) do
    LegalFixtures.insert_version(attrs)
    LegalFixtures.reset_version_cache()
  end

  test "no notices when the user is on every current version", %{user: user} do
    assert Onboarding.legal_notices(user) == []
    assert Onboarding.status(user).legal_notices == []
  end

  test "a notice-only privacy change with a future effective date is a notice", %{user: user} do
    publish(
      document: "privacy_policy",
      version: "2026-10-12",
      material: false,
      effective_date: ~D[2099-01-01],
      changelog: "Analytics linked to your account."
    )

    assert [notice] = Onboarding.legal_notices(user)
    assert notice.document == "privacy_policy"
    assert notice.version == "2026-10-12"
    assert notice.material == false
    assert notice.effective_date == ~D[2099-01-01]
    assert notice.changelog == "Analytics linked to your account."
    assert notice.url == "https://engram.page/privacy"
    assert Onboarding.status(user).legal_notices == [notice]
  end

  test "terms come before privacy when both are pending", %{user: user} do
    publish(
      document: "privacy_policy",
      version: "2026-10-12",
      material: false,
      effective_date: ~D[2099-01-01]
    )

    publish(version: "2026-10-12", material: true, effective_date: ~D[2099-01-01])

    assert ["terms_of_service", "privacy_policy"] ==
             Enum.map(Onboarding.legal_notices(user), & &1.document)
  end

  test "no notice once the effective date has arrived", %{user: user} do
    publish(
      document: "privacy_policy",
      version: "2026-10-12",
      material: false,
      effective_date: Date.utc_today()
    )

    assert Onboarding.legal_notices(user) == []
  end

  test "no notice for a version effective immediately (nil date)", %{user: user} do
    publish(
      document: "privacy_policy",
      version: "2026-10-12",
      material: false,
      effective_date: nil
    )

    assert Onboarding.legal_notices(user) == []
  end

  test "no notice once the user accepted the new version", %{user: user} do
    publish(
      document: "privacy_policy",
      version: "2026-10-12",
      material: false,
      effective_date: ~D[2099-01-01]
    )

    {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-10-12", "h", %{})
    assert Onboarding.legal_notices(user) == []
  end

  test "self-host (billing off) never has notices", %{user: user} do
    publish(
      document: "privacy_policy",
      version: "2026-10-12",
      material: false,
      effective_date: ~D[2099-01-01]
    )

    Application.put_env(:engram, :billing_enabled, false)
    assert Onboarding.legal_notices(user) == []
  end

  describe "VersionCache.required_floor/2" do
    test "the floor moves on the effective date without a cache reset" do
      publish(version: "2026-10-12", material: true, effective_date: ~D[2026-11-11])

      assert VersionCache.required_floor("terms_of_service", ~D[2026-11-10]) == "2026-05-19"
      assert VersionCache.required_floor("terms_of_service", ~D[2026-11-11]) == "2026-10-12"
    end
  end
end
