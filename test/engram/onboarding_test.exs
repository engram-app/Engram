defmodule Engram.OnboardingTest do
  use Engram.DataCase, async: false

  alias Engram.Legal.VersionCache
  alias Engram.LegalFixtures
  alias Engram.Onboarding
  alias Engram.Onboarding.Agreement
  alias Engram.Onboarding.TermsCache

  describe "accept_terms/3" do
    test "inserts an agreement row for the user and version" do
      user = insert(:user, onboarding_profile: %{})

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
      user = insert(:user, onboarding_profile: %{})
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
      user = insert(:user, onboarding_profile: %{})
      assert {:error, %Ecto.Changeset{}} = Onboarding.accept_terms(user, "", %{})
    end

    test "re-accepting the same version updates the row instead of duplicating" do
      user = insert(:user, onboarding_profile: %{})
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

  describe "status/1 self-host wizard (billing_enabled=false)" do
    # `:billing_enabled` only gates the hosted-only steps (agreement + billing).
    # Profile + vault still gate in every mode — onboarding is universal.
    setup do
      prev_bill = Application.get_env(:engram, :billing_enabled)
      Application.put_env(:engram, :billing_enabled, false)
      on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev_bill) end)
      :ok
    end

    test "fresh user lands on :tools (agreement + billing skipped)" do
      user = insert(:user, onboarding_profile: %{})

      assert %{
               enabled: true,
               terms_ok: true,
               subscription_ok: true,
               profile_complete: false,
               has_vault: false,
               next_step: :tools
             } = Onboarding.status(user)
    end

    test "after :tools POST, next_step advances to :vault" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{tools: ["claude"]})

      assert %{profile_complete: false, next_step: :vault} = Onboarding.status(user)
    end

    test "profile complete with uses_obsidian=true → :done (no vault required)" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})

      assert %{enabled: true, profile_complete: true, next_step: :done} =
               Onboarding.status(user)
    end

    test "profile complete with uses_obsidian=false and no vault → :vault" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})

      assert %{enabled: true, profile_complete: true, has_vault: false, next_step: :vault} =
               Onboarding.status(user)
    end

    test "missing agreement does not block — self-host operator owns legal posture" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
      # Explicitly no Onboarding.accept_terms/3 call.
      assert %{terms_ok: true, next_step: :done} = Onboarding.status(user)
    end

    test "missing subscription does not block — self-host has no paywall" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
      # No insert(:subscription, ...) call.
      assert %{subscription_ok: true, next_step: :done} = Onboarding.status(user)
    end

    test "steps fresh user = [:tools, :vault]" do
      user = insert(:user, onboarding_profile: %{})
      assert %{steps: [:tools, :vault]} = Onboarding.status(user)
    end

    test "steps stays [:tools, :vault] regardless of profile.uses_obsidian" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
      assert %{steps: [:tools, :vault]} = Onboarding.status(user)

      user2 = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user2, %{uses_obsidian: false, tools: ["claude"]})
      assert %{steps: [:tools, :vault]} = Onboarding.status(user2)
    end
  end

  describe "status/1 when billing is enabled" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      Application.put_env(:engram, :billing_enabled, true)

      # Seed the canonical floor/current both at "2026-05-15" (material, effective
      # now) so an acceptance of "2026-05-15" satisfies the gate.
      LegalFixtures.insert_version(
        document: "terms_of_service",
        version: "2026-05-15",
        content_hash: "canonical",
        material: true,
        effective_date: nil
      )

      LegalFixtures.insert_version(
        document: "privacy_policy",
        version: "2026-05-15",
        content_hash: "p",
        material: true,
        effective_date: nil
      )

      VersionCache.invalidate_all()
      on_exit(&VersionCache.invalidate_all/0)

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
      end)

      :ok
    end

    test "next_step=agreement when user has no agreement and no subscription" do
      user = insert(:user, onboarding_profile: %{})

      assert %{
               enabled: true,
               terms_ok: false,
               subscription_ok: false,
               current_tos_version: "2026-05-15",
               next_step: :agreement
             } = Onboarding.status(user)
    end

    test "steps fresh hosted user = [:agreement, :billing, :tools, :vault]" do
      user = insert(:user, onboarding_profile: %{})
      assert %{steps: [:agreement, :billing, :tools, :vault]} = Onboarding.status(user)
    end

    test "steps stays [:agreement, :billing, :tools, :vault] regardless of profile.uses_obsidian" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
      assert %{steps: [:agreement, :billing, :tools, :vault]} = Onboarding.status(user)
    end

    test "next_step=billing when terms accepted but no subscription" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      assert %{terms_ok: true, subscription_ok: false, next_step: :billing} =
               Onboarding.status(user)
    end

    test "next_step=done when terms accepted, active subscription, profile set (obsidian user)" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})

      assert %{terms_ok: true, subscription_ok: true, next_step: :done} =
               Onboarding.status(user)
    end

    test "next_step=agreement when accepted version is older than current_tos_version" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2025-01-01", %{})
      insert(:subscription, user: user, status: "active")

      assert %{terms_ok: false, subscription_ok: true, next_step: :agreement} =
               Onboarding.status(user)
    end

    test "next_step=done when terms accepted, past_due subscription, profile set (obsidian user)" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "past_due")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})

      assert %{terms_ok: true, subscription_ok: true, next_step: :done} =
               Onboarding.status(user)
    end

    test "caches a positive terms check so repeat calls skip the agreement query" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      # First call warms the cache.
      assert %{terms_ok: true} = Onboarding.status(user)

      {status, queries} =
        with_agreement_query_count(fn -> Onboarding.status(user) end)

      assert %{terms_ok: true} = status
      assert queries == 0
    end

    test "does not cache a negative terms check (re-queries until accepted)" do
      user = insert(:user, onboarding_profile: %{})

      assert %{terms_ok: false} = Onboarding.status(user)

      {status, queries} =
        with_agreement_query_count(fn -> Onboarding.status(user) end)

      assert %{terms_ok: false} = status
      assert queries >= 1
    end

    test "degrades to a DB read when the terms cache is unavailable" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      # Drop the cache owner (and its table). accepted_version/2 must report
      # nothing cached (nil) rather than raise, put_accepted/3 must be a no-op,
      # and status/1 must still read the DB and work.
      :ok = Supervisor.terminate_child(Engram.Supervisor, TermsCache)
      on_exit(fn -> Supervisor.restart_child(Engram.Supervisor, TermsCache) end)

      assert TermsCache.accepted_version(user.id, "terms_of_service") == nil
      assert :ok = TermsCache.put_accepted(user.id, "terms_of_service", "2026-05-15")
      assert %{terms_ok: true} = Onboarding.status(user)
    end
  end

  describe "accept_terms/6 + min_required gate" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      Application.put_env(:engram, :billing_enabled, true)

      VersionCache.invalidate_all()
      on_exit(&VersionCache.invalidate_all/0)

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
      end)

      :ok
    end

    test "terms_accepted? true when accepted >= floor even if below current" do
      # Floor = 2026-05-19 (material, effective now); current = 2026-06-01
      # (material, future effective_date so it stays out of the floor).
      LegalFixtures.insert_version(
        version: "2026-05-19",
        material: true,
        effective_date: nil
      )

      LegalFixtures.insert_version(
        version: "2026-06-01",
        material: true,
        effective_date: ~D[2099-01-01]
      )

      VersionCache.invalidate_all()

      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h_tos", "2026-05-19", "h_priv", %{})

      assert Onboarding.status(user).terms_ok
    end

    test "terms_accepted? false when accepted below floor" do
      # Floor = 2026-06-01 (material, effective now); acceptance of 2026-05-19
      # is below the floor.
      LegalFixtures.insert_version(
        version: "2026-06-01",
        material: true,
        effective_date: ~D[2000-01-01]
      )

      VersionCache.invalidate_all()

      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h_tos", "2026-05-19", "h_priv", %{})

      refute Onboarding.status(user).terms_ok
    end

    test "accept_terms stores content_hash and writes a privacy_policy row" do
      LegalFixtures.insert_version(
        version: "2026-05-19",
        material: true,
        effective_date: nil
      )

      LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
      VersionCache.invalidate_all()

      user = insert(:user, onboarding_profile: %{})

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
      LegalFixtures.insert_version(
        version: "2026-05-19",
        material: true,
        effective_date: nil
      )

      LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
      VersionCache.invalidate_all()

      user = insert(:user, onboarding_profile: %{})

      assert Onboarding.status(user).current_privacy_version == "2026-05-19"
    end
  end

  describe "computed floor gate + terms_notice" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      VersionCache.invalidate_all()
      Application.put_env(:engram, :billing_enabled, true)

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
        VersionCache.invalidate_all()
      end)

      :ok
    end

    test "terms_ok true and no notice when accepted == current, effective now" do
      LegalFixtures.insert_version(
        version: "2026-05-19",
        material: true,
        effective_date: nil
      )

      LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
      VersionCache.invalidate_all()
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})

      status = Onboarding.status(user)
      assert status.terms_ok
      assert status.terms_notice == nil
    end

    test "notice present but terms_ok still true during the window (new material version, future effective_date)" do
      LegalFixtures.insert_version(
        version: "2026-05-19",
        material: true,
        effective_date: nil
      )

      LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})

      LegalFixtures.insert_version(
        version: "2026-06-01",
        material: true,
        effective_date: ~D[2099-01-01]
      )

      VersionCache.invalidate_all()

      status = Onboarding.status(user)
      assert status.terms_ok
      assert status.terms_notice.version == "2026-06-01"
      assert status.terms_notice.effective_date == ~D[2099-01-01]
    end

    test "terms_ok false once the new material version is effective and unaccepted" do
      LegalFixtures.insert_version(
        version: "2026-05-19",
        material: true,
        effective_date: nil
      )

      LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})

      LegalFixtures.insert_version(
        version: "2026-06-01",
        material: true,
        effective_date: ~D[2000-01-01]
      )

      VersionCache.invalidate_all()

      refute Onboarding.status(user).terms_ok
    end
  end

  describe "set_profile/2" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      Application.put_env(:engram, :billing_enabled, true)

      LegalFixtures.insert_version(
        document: "terms_of_service",
        version: "2026-05-15",
        material: true,
        effective_date: nil
      )

      LegalFixtures.insert_version(
        document: "privacy_policy",
        version: "2026-05-15",
        material: true,
        effective_date: nil
      )

      VersionCache.invalidate_all()

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
        VersionCache.invalidate_all()
      end)

      :ok
    end

    test "stores uses_obsidian + tools + completed_at on the user" do
      user = insert(:user, onboarding_profile: %{})

      assert {:ok, updated} =
               Onboarding.set_profile(user, %{
                 uses_obsidian: true,
                 tools: ["claude", "claude_code"]
               })

      assert updated.onboarding_profile["uses_obsidian"] == true
      assert updated.onboarding_profile["tools"] == ["claude", "claude_code"]
      assert updated.onboarding_profile["completed_at"] != nil
    end

    test "rejects empty tools list" do
      user = insert(:user, onboarding_profile: %{})

      assert {:error, :empty_tools} =
               Onboarding.set_profile(user, %{uses_obsidian: false, tools: []})
    end

    test "rejects unknown tool slug" do
      user = insert(:user, onboarding_profile: %{})

      assert {:error, :invalid_tool} =
               Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["telepathy"]})
    end

    test "accepts every known tool slug" do
      user = insert(:user, onboarding_profile: %{})

      tools =
        ~w(claude chatgpt grok mistral open_webui lobechat
           claude_code cursor windsurf cline continue opencode github_copilot
           web_only other_mcp)

      assert {:ok, updated} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: tools})
      assert updated.onboarding_profile["tools"] == tools
    end

    test "rejects non-boolean uses_obsidian" do
      user = insert(:user, onboarding_profile: %{})

      assert {:error, :invalid_uses_obsidian} =
               Onboarding.set_profile(user, %{uses_obsidian: "yes", tools: ["claude"]})
    end

    test "rejects empty payload (neither tools nor uses_obsidian)" do
      user = insert(:user, onboarding_profile: %{})

      assert {:error, :nothing_to_set} = Onboarding.set_profile(user, %{})
    end

    test "partial POST then completion: tools first, uses_obsidian later stamps completed_at" do
      user = insert(:user, onboarding_profile: %{})

      # First screen: tools only. No completed_at yet.
      assert {:ok, after_tools} = Onboarding.set_profile(user, %{tools: ["claude"]})
      assert after_tools.onboarding_profile["tools"] == ["claude"]
      refute Map.has_key?(after_tools.onboarding_profile, "uses_obsidian")
      refute Map.has_key?(after_tools.onboarding_profile, "completed_at")

      # Second screen: source only. Both fields now present → completed_at latches.
      assert {:ok, after_source} = Onboarding.set_profile(after_tools, %{uses_obsidian: true})
      assert after_source.onboarding_profile["tools"] == ["claude"]
      assert after_source.onboarding_profile["uses_obsidian"] == true
      assert is_binary(after_source.onboarding_profile["completed_at"])
    end
  end

  describe "status/1 vault gate (after profile, only when uses_obsidian=false)" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      Application.put_env(:engram, :billing_enabled, true)

      LegalFixtures.insert_version(
        document: "terms_of_service",
        version: "2026-05-15",
        material: true,
        effective_date: nil
      )

      LegalFixtures.insert_version(
        document: "privacy_policy",
        version: "2026-05-15",
        material: true,
        effective_date: nil
      )

      VersionCache.invalidate_all()

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
        VersionCache.invalidate_all()
      end)

      :ok
    end

    test "next_step :vault when fresh-start profile complete but no vault exists" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})

      assert %{has_vault: false, next_step: :vault} = Onboarding.status(user)
    end

    test "next_step :done for obsidian user with no vault (plugin will create it)" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})

      assert %{has_vault: false, next_step: :done} = Onboarding.status(user)
    end

    test "next_step :done for fresh user once a vault has been created" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})
      {:ok, _} = Engram.Vaults.create_vault(user, %{name: "My Vault"})

      assert %{has_vault: true, next_step: :done} = Onboarding.status(user)
    end
  end

  describe "status/1 vault gate (next_step :tools / :vault come after :billing)" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      Application.put_env(:engram, :billing_enabled, true)

      LegalFixtures.insert_version(
        document: "terms_of_service",
        version: "2026-05-15",
        material: true,
        effective_date: nil
      )

      LegalFixtures.insert_version(
        document: "privacy_policy",
        version: "2026-05-15",
        material: true,
        effective_date: nil
      )

      VersionCache.invalidate_all()

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
        VersionCache.invalidate_all()
      end)

      :ok
    end

    test "next_step :tools when terms + subscription ok but no tools yet" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")

      assert %{
               terms_ok: true,
               subscription_ok: true,
               profile_complete: false,
               next_step: :tools
             } = Onboarding.status(user)
    end

    test "next_step :vault once tools are POSTed but uses_obsidian still missing" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")
      {:ok, _} = Onboarding.set_profile(user, %{tools: ["claude"]})

      assert %{
               terms_ok: true,
               subscription_ok: true,
               profile_complete: false,
               next_step: :vault
             } = Onboarding.status(user)
    end

    test "next_step :done once profile is set (obsidian user — vault gate skipped)" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})

      assert %{profile_complete: true, next_step: :done} = Onboarding.status(user)
    end

    test "next_step :billing still wins over :tools when subscription missing" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      assert %{next_step: :billing, profile_complete: false} = Onboarding.status(user)
    end

    test "next_step :agreement still wins when terms not accepted" do
      user = insert(:user, onboarding_profile: %{})
      insert(:subscription, user: user, status: "trialing")

      assert %{next_step: :agreement} = Onboarding.status(user)
    end
  end

  describe "record_action/2 + list_actions/1" do
    setup do
      user = insert(:user)
      {:ok, user: user}
    end

    test "writes a row and is idempotent", %{user: user} do
      assert :ok = Onboarding.record_action(user.id, :first_vault_created)
      assert :ok = Onboarding.record_action(user.id, :first_vault_created)

      assert ["first_vault_created"] = Onboarding.list_actions(user.id)
    end

    test "list_actions/1 returns [] for unknown user" do
      # Bigint that no user_fixture mints.
      assert [] = Onboarding.list_actions(0)
    end

    test "lists multiple distinct actions", %{user: user} do
      :ok = Onboarding.record_action(user.id, :tour_offered_skipped)
      :ok = Onboarding.record_action(user.id, :first_vault_created)

      assert MapSet.new(["tour_offered_skipped", "first_vault_created"]) ==
               MapSet.new(Onboarding.list_actions(user.id))
    end

    test "rejects unknown action atom", %{user: user} do
      assert {:error, %Ecto.Changeset{}} = Onboarding.record_action(user.id, :bogus)
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
