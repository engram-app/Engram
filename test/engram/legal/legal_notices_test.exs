defmodule Engram.Legal.LegalNoticesTest do
  use Engram.DataCase, async: false

  alias Engram.Legal.VersionCache
  alias Engram.LegalFixtures
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

  # Nothing has changed for an account that never accepted a version: a
  # signup agrees to the current text, then sees the pending change as a
  # banner in the app.
  test "a signup that never accepted anything gets no notice" do
    publish(
      document: "privacy_policy",
      version: "2026-10-12",
      material: false,
      effective_date: ~D[2099-01-01]
    )

    publish(version: "2026-10-12", material: true, effective_date: ~D[2099-01-01])

    signup = insert(:user, onboarding_profile: %{})
    assert Onboarding.legal_notices(signup) == []
    assert Onboarding.status(signup).legal_notices == []
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

  test "a later silent wording fix does not hide a pending material change", %{user: user} do
    publish(
      version: "2026-11-01",
      material: true,
      effective_date: ~D[2099-01-01],
      changelog: "Big change."
    )

    publish(version: "2026-11-05", material: false, effective_date: nil, changelog: "Typo.")

    assert [%{version: "2026-11-01", changelog: "Big change."}] = Onboarding.legal_notices(user)
  end

  test "a material change stays listed once effective, so the accept page can show it", %{
    user: user
  } do
    publish(version: "2026-10-12", material: true, effective_date: Date.add(Date.utc_today(), -1))

    assert [%{version: "2026-10-12", material: true}] = Onboarding.legal_notices(user)
    refute Onboarding.status(user).terms_ok
  end

  describe "material privacy changes" do
    test "block once effective, like the Terms", %{user: user} do
      publish(
        document: "privacy_policy",
        version: "2026-10-12",
        material: true,
        effective_date: Date.add(Date.utc_today(), -1)
      )

      refute Onboarding.status(user).terms_ok
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-10-12", "h", %{})
      assert Onboarding.status(user).terms_ok
    end

    test "do not block before their effective date", %{user: user} do
      publish(
        document: "privacy_policy",
        version: "2026-10-12",
        material: true,
        effective_date: ~D[2099-01-01]
      )

      assert Onboarding.status(user).terms_ok
    end

    test "a baseline privacy version (no effective date) never blocks an older acceptance" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})

      publish(
        document: "privacy_policy",
        version: "2026-06-20",
        material: true,
        effective_date: nil
      )

      assert Onboarding.status(user).terms_ok
    end
  end

  describe "VersionCache.required_floor/2" do
    test "the floor moves on the effective date without a cache reset" do
      publish(version: "2026-10-12", material: true, effective_date: ~D[2026-11-11])

      assert VersionCache.required_floor("terms_of_service", ~D[2026-11-10]) == "2026-05-19"
      assert VersionCache.required_floor("terms_of_service", ~D[2026-11-11]) == "2026-10-12"
      assert VersionCache.required_floor("terms_of_service", ~D[2026-11-11]) == "2026-10-12"
    end

    test "the version list is really cached (structs in the value store fine)" do
      VersionCache.versions("terms_of_service")
      assert {:ok, [_ | _]} = Engram.Cache.get(:legal_version, {:versions, "terms_of_service"})
    end

    test "one cache entry per document, not one per day" do
      for d <- [~D[2026-11-09], ~D[2026-11-10], ~D[2026-11-11]],
          do: VersionCache.required_floor("terms_of_service", d)

      entries =
        :ets.tab2list(Engram.Cache.Registry.table(:legal_version))
        |> Enum.filter(&match?({{:floor, "terms_of_service"}, _, _}, &1))

      assert length(entries) == 1
    end
  end
end
