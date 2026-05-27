defmodule Engram.OnboardingTest do
  use Engram.DataCase, async: false

  alias Engram.Onboarding
  alias Engram.Onboarding.Agreement
  alias Engram.Onboarding.TermsCache

  describe "accept_terms/3" do
    test "inserts an agreement row for the user and version" do
      user = insert(:user)

      {:ok, %Agreement{} = agreement} =
        Onboarding.accept_terms(user, "2026-05-15", %{
          ip_address: "192.168.1.1",
          user_agent: "Mozilla/5.0"
        })

      assert agreement.user_id == user.id
      assert agreement.document == "terms_of_service"
      assert agreement.version == "2026-05-15"
      assert agreement.ip_address == "192.168.1.1"
      assert agreement.user_agent == "Mozilla/5.0"
      assert agreement.accepted_at != nil
    end

    test "allows the same user to accept multiple versions" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-01-01", %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      rows =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.all(Agreement)
        end)
        |> elem(1)

      assert length(rows) == 2
    end

    test "rejects empty version" do
      user = insert(:user)
      assert {:error, %Ecto.Changeset{}} = Onboarding.accept_terms(user, "", %{})
    end

    test "re-accepting the same version updates the row instead of duplicating" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{ip_address: "1.1.1.1"})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{ip_address: "2.2.2.2"})

      {:ok, rows} =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.all(Agreement)
        end)

      assert length(rows) == 1
      assert hd(rows).ip_address == "2.2.2.2"
    end
  end

  describe "status/1 when billing is disabled (self-host)" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      prev_version = Application.get_env(:engram, :current_tos_version)
      Application.put_env(:engram, :billing_enabled, false)
      Application.put_env(:engram, :current_tos_version, "2026-05-15")

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
        Application.put_env(:engram, :current_tos_version, prev_version)
      end)

      :ok
    end

    test "returns enabled=false and next_step=done regardless of state" do
      user = insert(:user)
      assert %{enabled: false, next_step: :done} = Onboarding.status(user)
    end
  end

  describe "status/1 when billing is enabled" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      prev_version = Application.get_env(:engram, :current_tos_version)
      prev_min = Application.get_env(:engram, :min_required_tos_version)
      Application.put_env(:engram, :billing_enabled, true)
      Application.put_env(:engram, :current_tos_version, "2026-05-15")
      # Default min_required tracks current here so the pre-existing tests keep
      # their original "accepted >= current" semantics.
      Application.put_env(:engram, :min_required_tos_version, "2026-05-15")

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
        Application.put_env(:engram, :current_tos_version, prev_version)
        Application.put_env(:engram, :min_required_tos_version, prev_min)
      end)

      :ok
    end

    test "next_step=agreement when user has no agreement and no subscription" do
      user = insert(:user)

      assert %{
               enabled: true,
               terms_ok: false,
               subscription_ok: false,
               current_tos_version: "2026-05-15",
               next_step: :agreement
             } = Onboarding.status(user)
    end

    test "next_step=billing when terms accepted but no subscription" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      assert %{terms_ok: true, subscription_ok: false, next_step: :billing} =
               Onboarding.status(user)
    end

    test "next_step=done when terms accepted and active subscription exists" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")

      assert %{terms_ok: true, subscription_ok: true, next_step: :done} =
               Onboarding.status(user)
    end

    test "next_step=agreement when accepted version is older than current_tos_version" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2025-01-01", %{})
      insert(:subscription, user: user, status: "active")

      assert %{terms_ok: false, subscription_ok: true, next_step: :agreement} =
               Onboarding.status(user)
    end

    test "next_step=done when terms accepted and past_due subscription exists" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "past_due")

      assert %{terms_ok: true, subscription_ok: true, next_step: :done} =
               Onboarding.status(user)
    end

    test "caches a positive terms check so repeat calls skip the agreement query" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      # First call warms the cache.
      assert %{terms_ok: true} = Onboarding.status(user)

      {status, queries} =
        with_agreement_query_count(fn -> Onboarding.status(user) end)

      assert %{terms_ok: true} = status
      assert queries == 0
    end

    test "does not cache a negative terms check (re-queries until accepted)" do
      user = insert(:user)

      assert %{terms_ok: false} = Onboarding.status(user)

      {status, queries} =
        with_agreement_query_count(fn -> Onboarding.status(user) end)

      assert %{terms_ok: false} = status
      assert queries >= 1
    end

    test "degrades to a DB read when the terms cache is unavailable" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      # Drop the cache owner (and its table). accepted?/2 must report not-cached
      # (false) rather than raise, and status/1 must still read the DB and work.
      :ok = Supervisor.terminate_child(Engram.Supervisor, TermsCache)
      on_exit(fn -> Supervisor.restart_child(Engram.Supervisor, TermsCache) end)

      assert TermsCache.accepted?(user.id, "2026-05-15") == false
      assert :ok = TermsCache.mark_accepted(user.id, "2026-05-15")
      assert %{terms_ok: true} = Onboarding.status(user)
    end
  end

  describe "accept_terms/6 + min_required gate" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      prev_current = Application.get_env(:engram, :current_tos_version)
      prev_min = Application.get_env(:engram, :min_required_tos_version)
      prev_priv = Application.get_env(:engram, :current_privacy_version)
      Application.put_env(:engram, :billing_enabled, true)

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
        Application.put_env(:engram, :current_tos_version, prev_current)
        Application.put_env(:engram, :min_required_tos_version, prev_min)
        Application.put_env(:engram, :current_privacy_version, prev_priv)
      end)

      :ok
    end

    test "terms_accepted? true when accepted >= min_required even if below current" do
      Application.put_env(:engram, :min_required_tos_version, "2026-05-19")
      Application.put_env(:engram, :current_tos_version, "2026-06-01")

      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h_tos", "2026-05-19", "h_priv", %{})

      assert Onboarding.status(user).terms_ok
    end

    test "terms_accepted? false when accepted below min_required" do
      Application.put_env(:engram, :min_required_tos_version, "2026-06-01")
      Application.put_env(:engram, :current_tos_version, "2026-06-01")

      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h_tos", "2026-05-19", "h_priv", %{})

      refute Onboarding.status(user).terms_ok
    end

    test "accept_terms stores content_hash and writes a privacy_policy row" do
      Application.put_env(:engram, :min_required_tos_version, "2026-05-19")
      Application.put_env(:engram, :current_tos_version, "2026-05-19")

      user = insert(:user)

      {:ok, %Agreement{} = tos} =
        Onboarding.accept_terms(user, "2026-05-19", "h_tos", "2026-05-19", "h_priv", %{
          ip_address: "10.0.0.1",
          user_agent: "UA"
        })

      assert tos.document == "terms_of_service"
      assert tos.content_hash == "h_tos"

      {:ok, rows} =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.all(Agreement)
        end)

      privacy = Enum.find(rows, &(&1.document == "privacy_policy"))
      assert privacy
      assert privacy.version == "2026-05-19"
      assert privacy.content_hash == "h_priv"
    end

    test "status returns current_privacy_version" do
      Application.put_env(:engram, :min_required_tos_version, "2026-05-19")
      Application.put_env(:engram, :current_tos_version, "2026-05-19")
      Application.put_env(:engram, :current_privacy_version, "2026-05-19")

      user = insert(:user)

      assert Onboarding.status(user).current_privacy_version == "2026-05-19"
    end
  end

  describe "computed floor gate + terms_notice" do
    setup do
      Engram.Legal.VersionCache.invalidate_all()
      Application.put_env(:engram, :billing_enabled, true)
      on_exit(fn -> Engram.Legal.VersionCache.invalidate_all() end)
      :ok
    end

    test "terms_ok true and no notice when accepted == current, effective now" do
      Engram.LegalFixtures.insert_version(version: "2026-05-19", material: true, effective_date: nil)
      Engram.LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
      Engram.Legal.VersionCache.invalidate_all()
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})

      status = Onboarding.status(user)
      assert status.terms_ok
      refute Map.has_key?(status, :terms_notice) and status.terms_notice != nil
    end

    test "notice present but terms_ok still true during the window (new material version, future effective_date)" do
      Engram.LegalFixtures.insert_version(version: "2026-05-19", material: true, effective_date: nil)
      Engram.LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})

      Engram.LegalFixtures.insert_version(version: "2026-06-01", material: true, effective_date: ~D[2099-01-01])
      Engram.Legal.VersionCache.invalidate_all()

      status = Onboarding.status(user)
      assert status.terms_ok
      assert status.terms_notice.version == "2026-06-01"
      assert status.terms_notice.effective_date == ~D[2099-01-01]
    end

    test "terms_ok false once the new material version is effective and unaccepted" do
      Engram.LegalFixtures.insert_version(version: "2026-05-19", material: true, effective_date: nil)
      Engram.LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})

      Engram.LegalFixtures.insert_version(version: "2026-06-01", material: true, effective_date: ~D[2000-01-01])
      Engram.Legal.VersionCache.invalidate_all()

      refute Onboarding.status(user).terms_ok
    end
  end

  defp with_agreement_query_count(fun) do
    # Scope to this test's pid: telemetry handlers run in the emitting process,
    # so without this a concurrent async test could leak into the count.
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:engram, :repo, :query],
      fn _event, _measurements, %{source: source}, _config ->
        if source == "user_agreements" and self() == test_pid,
          do: Agent.update(counter, &(&1 + 1))
      end,
      nil
    )

    try do
      result = fun.()
      {result, Agent.get(counter, & &1)}
    after
      :telemetry.detach(handler_id)
      Agent.stop(counter)
    end
  end
end
