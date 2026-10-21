defmodule Engram.OnboardingTest do
  use Engram.DataCase, async: false

  alias Engram.LegalFixtures
  alias Engram.Onboarding
  alias Engram.Onboarding.Agreement

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

    test "an UNSET :billing_enabled key is treated as disabled everywhere in status/1" do
      # status/1 used to read :billing_enabled twice with OPPOSITE defaults
      # (false for the wizard steps, true for the subscription gate) — with
      # the key unset that yields self-host wizard behavior but SaaS
      # subscription gating in the same response.
      Application.delete_env(:engram, :billing_enabled)

      user = insert(:user, onboarding_profile: %{})
      status = Onboarding.status(user)

      assert status.terms_ok
      assert status.subscription_ok
    end

    test "fresh user lands on :vault (agreement + billing skipped)" do
      user = insert(:user, onboarding_profile: %{})

      assert %{
               enabled: true,
               terms_ok: true,
               subscription_ok: true,
               profile_complete: false,
               has_vault: false,
               next_step: :vault
             } = Onboarding.status(user)
    end

    test "after :tools POST, next_step advances to :vault" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{tools: ["claude"]})

      assert %{profile_complete: false, next_step: :vault} = Onboarding.status(user)
    end

    test "profile complete with uses_obsidian=true and no vault yet → :vault" do
      # The plugin hasn't created the vault yet; wizard waits for the
      # `vault_populated` broadcast before navigating. `RequireOnboarding`
      # still skips the vault gate for `uses_obsidian=true`, so the plugin
      # can sync — but wizard navigation is intentionally stricter.
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})

      assert %{enabled: true, profile_complete: true, has_vault: false, next_step: :vault} =
               Onboarding.status(user)
    end

    test "profile complete with uses_obsidian=true AND vault exists → :done" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
      insert(:vault, user: user)

      assert %{enabled: true, profile_complete: true, has_vault: true, next_step: :done} =
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
      insert(:vault, user: user)
      # Explicitly no Onboarding.accept_terms/3 call.
      assert %{terms_ok: true, next_step: :done} = Onboarding.status(user)
    end

    test "missing subscription does not block — self-host has no paywall" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
      insert(:vault, user: user)
      # No insert(:subscription, ...) call.
      assert %{subscription_ok: true, next_step: :done} = Onboarding.status(user)
    end

    test "steps fresh user = [:vault]" do
      user = insert(:user, onboarding_profile: %{})
      assert %{steps: [:vault]} = Onboarding.status(user)
    end

    # The chain describes the intended journey: answering the vault step's
    # question must not remove it.
    test "steps stays [:vault] for a web signup regardless of uses_obsidian" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true})
      assert %{steps: [:vault]} = Onboarding.status(user)

      user2 = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user2, %{uses_obsidian: false})
      assert %{steps: [:vault]} = Onboarding.status(user2)
    end

    test "a plugin-first signup has no steps and is done before its first sync" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, signup_source: "plugin"})
      assert %{steps: [], next_step: :done, gate_ok: true} = Onboarding.status(user)
    end

    # A connector signup gets its vault provisioned, so nothing is left to ask.
    test "steps is empty when an OAuth client pre-answered it" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{tools: ["claude"], tools_prefilled: true})
      assert %{steps: [], next_step: :done, gate_ok: true} = Onboarding.status(user)
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

      LegalFixtures.reset_version_cache()
      on_exit(&LegalFixtures.reset_version_cache/0)

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

    test "steps fresh hosted user = [:agreement, :heard, :vault]" do
      user = insert(:user, onboarding_profile: %{})
      assert %{steps: [:agreement, :heard, :vault]} = Onboarding.status(user)
    end

    test "steps stays [:agreement, :heard, :vault] once a web signup answered both" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      :ok = Engram.Feedback.submit(user, "onboarding", %{"heard_from" => "reddit"})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true})
      assert %{steps: [:agreement, :heard, :vault]} = Onboarding.status(user)
    end

    # Its own step, after the terms: asked only of a web signup, which has no
    # other record of where it came from.
    test "a web signup is asked how it heard about us after the terms" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", "canonical", "2026-05-15", "p", %{})
      user = Engram.Accounts.get_user!(user.id)
      assert %{next_step: :heard} = Onboarding.status(user)

      :ok = Engram.Feedback.submit(user, "onboarding", %{"heard_from" => "youtube"})
      assert %{next_step: :vault} = Onboarding.status(user)
    end

    # An account that finished the old wizard was never asked; re-accepting
    # changed terms must not send it through a new question.
    test "a completed profile without an answer is not asked" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: false})
      insert(:vault, user: user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", "canonical", "2026-05-15", "p", %{})
      user = Engram.Accounts.get_user!(user.id)
      assert %{steps: [:agreement, :vault], next_step: :done} = Onboarding.status(user)
    end

    # Plugin-first: /link answers the Obsidian question and records the origin
    # before the wizard. Terms are the only step, then the wizard hands back
    # to /link so the plugin can sync and create the vault.
    test "a plugin-first signup sees only the terms, then is done" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, signup_source: "plugin"})

      assert %{steps: [:agreement], next_step: :agreement} = Onboarding.status(user)

      {:ok, _} =
        Onboarding.accept_terms(user, "2026-05-15", "canonical", "2026-05-15", "p", %{})

      user = Engram.Accounts.get_user!(user.id)
      assert %{steps: [:agreement], next_step: :done, gate_ok: true} = Onboarding.status(user)
      assert [] = Engram.Vaults.list_vaults(user)
    end

    # A web signup: terms, then Obsidian or fresh. No plan step: accepting the
    # terms starts the account on Free.
    test "a web signup goes from the terms to the heard step on Free" do
      user = insert(:user, onboarding_profile: %{})

      {:ok, _} =
        Onboarding.accept_terms(user, "2026-05-15", "canonical", "2026-05-15", "p", %{})

      user = Engram.Accounts.get_user!(user.id)
      assert %DateTime{} = user.free_tier_accepted_at
      assert %{steps: [:agreement, :heard, :vault], next_step: :heard} = Onboarding.status(user)
    end

    # The MCP-first path answers `tools` from the OAuth client before the
    # wizard starts. Accepting the terms starts the account on Free and
    # provisions the vault, so a connector signup sees one step before
    # returning to the consent screen.
    test "steps is [:agreement] when an OAuth client pre-answered it" do
      user = insert(:user, onboarding_profile: %{})

      {:ok, _} =
        Onboarding.set_profile(user, %{tools: ["antigravity"], tools_prefilled: true})

      assert %{steps: [:agreement], next_step: :agreement} = Onboarding.status(user)

      {:ok, _} =
        Onboarding.accept_terms(user, "2026-05-15", "canonical", "2026-05-15", "p", %{})

      user = Engram.Accounts.get_user!(user.id)
      assert %DateTime{} = user.free_tier_accepted_at
      assert [%{name: "My Vault"}] = Engram.Vaults.list_vaults(user)

      assert %{steps: [:agreement], next_step: :done, gate_ok: true} = Onboarding.status(user)
    end

    test "accepting terms does not start a paying connector signup on Free" do
      user = insert(:user, onboarding_profile: %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Onboarding.set_profile(user, %{tools: ["chatgpt"], tools_prefilled: true})

      {:ok, _} =
        Onboarding.accept_terms(user, "2026-05-15", "canonical", "2026-05-15", "p", %{})

      assert is_nil(Engram.Accounts.get_user!(user.id).free_tier_accepted_at)
      assert [%{name: "My Vault"}] = Engram.Vaults.list_vaults(user)
    end

    test "accepting terms does not start a paying account on Free" do
      user = insert(:user, onboarding_profile: %{})
      insert(:subscription, user: user, status: "active")

      {:ok, _} =
        Onboarding.accept_terms(user, "2026-05-15", "canonical", "2026-05-15", "p", %{})

      assert is_nil(Engram.Accounts.get_user!(user.id).free_tier_accepted_at)
    end

    # A connector signup that accepted the terms before the Free start
    # existed sits at :billing. The chain must keep listing it.
    test "a pre-filled profile past terms with no plan keeps the billing step" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{tools: ["chatgpt"], tools_prefilled: true})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      assert %{steps: [:agreement, :billing], next_step: :billing} = Onboarding.status(user)
    end

    # A row pre-filled before `completed_at` was stamped for connector
    # signups, holding a vault from elsewhere (e.g. the plugin's device link).
    # `next_step` still answers :vault, so the chain must list it.
    test "a pre-filled profile with a vault but no completed_at keeps the vault step" do
      user =
        insert(:user, onboarding_profile: %{"tools" => ["chatgpt"], "tools_prefilled" => true})

      insert(:vault, user: user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")

      assert %{steps: [:agreement, :vault], next_step: :vault} = Onboarding.status(user)
    end

    test "a pre-filled profile without a vault keeps the vault step, never the survey" do
      user =
        insert(:user, onboarding_profile: %{"tools" => ["chatgpt"], "tools_prefilled" => true})

      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")

      assert %{steps: [:agreement, :vault], next_step: :vault} = Onboarding.status(user)
    end

    # The whole guarantee against a wizard loop: the layout punts any step not
    # in `steps` back to /onboard, which resolves `next_step` again. And the
    # verdict the wire reports (`gate_ok`) must be the one `gate/2` enforces.
    test "next_step is always listed and gate_ok always matches gate/2" do
      prev = Application.get_env(:engram, :billing_enabled)
      on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev) end)

      for billing <- [true, false],
          origin <- [:web, :plugin, :connector, :legacy_connector],
          uses_obsidian <- [nil, true, false],
          terms <- [false, true],
          plan <- [false, true],
          vault <- [false, true],
          heard <- [false, true] do
        Application.put_env(:engram, :billing_enabled, billing)
        Engram.Onboarding.GateCache.evict_all()

        user =
          insert(:user,
            onboarding_profile:
              loop_profile(origin, uses_obsidian)
              |> then(&if(heard, do: Map.put(&1, "heard_from", "reddit"), else: &1)),
            free_tier_accepted_at: if(plan, do: DateTime.utc_now(:second))
          )

        if vault, do: insert(:vault, user: user)
        if terms, do: {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

        status = Onboarding.status(user)
        label = inspect({billing, origin, uses_obsidian, terms, plan, vault, heard})

        assert status.next_step == :done or status.next_step in status.steps,
               "#{label}: next_step #{status.next_step} not in #{inspect(status.steps)}"

        assert match?(:ok, Onboarding.gate(user)) == status.gate_ok,
               "#{label}: gate/2 disagrees with gate_ok #{status.gate_ok}"
      end
    end

    test "next_step=billing when terms accepted but no subscription" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      assert %{terms_ok: true, subscription_ok: false, next_step: :billing} =
               Onboarding.status(user)
    end

    test "next_step=done when terms accepted, active subscription, profile set (obsidian user with vault)" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
      insert(:vault, user: user)

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

    test "subscription_ok when terms accepted and subscription is past_due (grace window)" do
      # A `past_due` subscription is within Paddle's dunning grace window, so
      # `Billing.tier/1` keeps it at its paid tier (`:starter`/`:pro`) — see
      # `@entitled_statuses`. The onboarding billing gate passes on tier alone,
      # so a past_due user is NOT bounced back to `:billing`; with the rest of
      # the wizard complete they reach `:done`. (Payment repair happens later
      # via the billing settings page, not the onboarding wizard.)
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "past_due")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
      insert(:vault, user: user)

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

      # Drop the cache owner (and its tables). get/2 must report a miss rather
      # than raise, put/3 must be a no-op, and status/1 must still read the DB
      # and work.
      :ok = Supervisor.terminate_child(Engram.Supervisor, Engram.Cache.Server)
      on_exit(fn -> Supervisor.restart_child(Engram.Supervisor, Engram.Cache.Server) end)

      assert Engram.Cache.get(:terms, {user.id, "terms_of_service"}) == :miss
      assert :ok = Engram.Cache.put(:terms, {user.id, "terms_of_service"}, "2026-05-15")
      assert %{terms_ok: true} = Onboarding.status(user)
    end
  end

  describe "accept_terms/6 + min_required gate" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      Application.put_env(:engram, :billing_enabled, true)

      LegalFixtures.reset_version_cache()
      on_exit(&LegalFixtures.reset_version_cache/0)

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

      LegalFixtures.reset_version_cache()

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

      LegalFixtures.reset_version_cache()

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
      LegalFixtures.reset_version_cache()

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
      LegalFixtures.reset_version_cache()

      user = insert(:user, onboarding_profile: %{})

      assert Onboarding.status(user).current_privacy_version == "2026-05-19"
    end

    # The Free stamp commits with the first acceptance: a stamp that fails
    # fails the acceptance, so the user retries accept instead of landing past
    # the terms with no plan.
    test "a failed Free start fails the acceptance and records no agreement rows" do
      LegalFixtures.insert_version(version: "2026-05-19", effective_date: nil)
      LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
      LegalFixtures.reset_version_cache()

      user = insert(:user, onboarding_profile: %{"uses_obsidian" => false, "completed_at" => "x"})
      Engram.FreeStampBlock.block!()

      assert {:error, _} =
               Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})

      assert {:ok, []} = Engram.Repo.with_tenant(user.id, fn -> Engram.Repo.all(Agreement) end)
      assert is_nil(Engram.Accounts.get_user!(user.id).free_tier_accepted_at)
    end

    test "a retried acceptance after a failed Free start stamps Free" do
      LegalFixtures.insert_version(version: "2026-05-19", effective_date: nil)
      LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
      LegalFixtures.reset_version_cache()

      user = insert(:user, onboarding_profile: %{"uses_obsidian" => false, "completed_at" => "x"})
      Engram.FreeStampBlock.block!()
      {:error, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})
      Engram.FreeStampBlock.unblock!()

      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})

      assert %DateTime{} = Engram.Accounts.get_user!(user.id).free_tier_accepted_at
    end

    test "a paid account is never stamped Free, on first acceptance or re-acceptance" do
      LegalFixtures.insert_version(version: "2026-05-19", effective_date: nil)
      LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
      LegalFixtures.reset_version_cache()

      user = insert(:user, onboarding_profile: %{"uses_obsidian" => false, "completed_at" => "x"})
      insert(:subscription, user: user, tier: "pro", status: "active")

      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})
      assert is_nil(Engram.Accounts.get_user!(user.id).free_tier_accepted_at)

      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h2", "2026-05-19", "h2", %{})
      assert is_nil(Engram.Accounts.get_user!(user.id).free_tier_accepted_at)
    end

    # Double-submitted first acceptances: one stamp, one connector vault.
    test "concurrent first acceptances stamp once and provision one connector vault" do
      LegalFixtures.insert_version(version: "2026-05-19", effective_date: nil)
      LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
      LegalFixtures.reset_version_cache()

      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{tools: ["chatgpt"], tools_prefilled: true})
      stale = Engram.Accounts.get_user!(user.id)

      1..5
      |> Task.async_stream(
        fn _ -> Onboarding.accept_terms(stale, "2026-05-19", "h", "2026-05-19", "h", %{}) end,
        max_concurrency: 5
      )
      |> Enum.each(fn {:ok, result} -> assert {:ok, %Agreement{}} = result end)

      assert %DateTime{} = Engram.Accounts.get_user!(user.id).free_tier_accepted_at
      assert [%{name: "My Vault"}] = Engram.Vaults.list_vaults(user)
    end
  end

  describe "computed floor gate + legal_notices" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      LegalFixtures.reset_version_cache()
      Application.put_env(:engram, :billing_enabled, true)

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
        LegalFixtures.reset_version_cache()
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
      LegalFixtures.reset_version_cache()
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})

      status = Onboarding.status(user)
      assert status.terms_ok
      assert status.legal_notices == []
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

      LegalFixtures.reset_version_cache()

      status = Onboarding.status(user)
      assert status.terms_ok
      assert [%{version: "2026-06-01", effective_date: ~D[2099-01-01]}] = status.legal_notices
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

      LegalFixtures.reset_version_cache()

      refute Onboarding.status(user).terms_ok
    end

    # Accounts that accepted through the ToS-only path have no privacy row at
    # all. They are not new signups, so a privacy change must still reach them.
    test "a legacy account with terms but no privacy row still gets the privacy notice" do
      LegalFixtures.insert_version(version: "2026-05-19", effective_date: nil)

      LegalFixtures.insert_version(
        document: "privacy_policy",
        version: "2026-05-19",
        material: false
      )

      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", %{})

      LegalFixtures.insert_version(
        document: "privacy_policy",
        version: "2026-06-01",
        material: false,
        effective_date: ~D[2099-01-01]
      )

      LegalFixtures.reset_version_cache()

      assert [%{document: "privacy_policy", version: "2026-06-01"}] =
               Onboarding.legal_notices(user)
    end

    test "a brand-new signup who accepted nothing sees no notices" do
      LegalFixtures.insert_version(version: "2026-05-19", effective_date: nil)

      LegalFixtures.insert_version(
        version: "2026-06-01",
        material: true,
        effective_date: ~D[2099-01-01]
      )

      LegalFixtures.insert_version(
        document: "privacy_policy",
        version: "2026-06-01",
        material: false,
        effective_date: ~D[2099-01-01]
      )

      LegalFixtures.reset_version_cache()
      user = insert(:user, onboarding_profile: %{})

      assert Onboarding.legal_notices(user) == []
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

      LegalFixtures.reset_version_cache()

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
        LegalFixtures.reset_version_cache()
      end)

      :ok
    end

    test "tools_prefilled records that an OAuth client answered, not the user" do
      user = insert(:user, onboarding_profile: %{})

      assert {:ok, updated} =
               Onboarding.set_profile(user, %{tools: ["claude"], tools_prefilled: true})

      assert updated.onboarding_profile["tools_prefilled"] == true
    end

    # A qualifier on `tools`, never a standalone fact. Accepted alone, a stray
    # POST could mark an ordinary signup's own answer as pre-filled, dropping
    # their tools step out of the chain and freezing "Step X of N".
    # Nothing is written for the user before they accept the terms: the
    # pre-answer runs on the consent screen, ahead of the agreement step.
    test "tools_prefilled provisions nothing before terms and plan" do
      user = insert(:user, onboarding_profile: %{})

      assert {:ok, _} =
               Onboarding.set_profile(user, %{tools: ["chatgpt"], tools_prefilled: true})

      assert [] = Engram.Vaults.list_vaults(user)
    end

    test "accepting the Free plan provisions My Vault with the welcome note" do
      user = prefilled_past_terms()

      {:ok, _} = Onboarding.accept_free_tier(Engram.Accounts.get_user!(user.id))

      assert [vault] = Engram.Vaults.list_vaults(user)
      assert vault.name == "My Vault"

      assert %{notes: 1} =
               Engram.Vaults.content_counts(Engram.Accounts.get_user(user.id), vault.id)
    end

    test "a paid subscription provisions My Vault" do
      user = prefilled_past_terms()

      {:ok, _} =
        Engram.Billing.upsert_from_paddle_event(%{
          "event_type" => "subscription.created",
          "event_id" => "ntf_connector_1",
          "data" => %{
            "id" => "sub_connector_1",
            "status" => "active",
            "customer_id" => "ctm_connector_1",
            "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}, "status" => "active"}],
            "current_billing_period" => %{
              "starts_at" => "2026-05-13T00:00:00Z",
              "ends_at" => "2026-06-13T00:00:00Z"
            },
            "custom_data" => %{"user_id" => user.id}
          }
        })

      assert [%{name: "My Vault"}] = Engram.Vaults.list_vaults(user)
    end

    # A returning user whose plan already passes but whose terms lapsed: the
    # pre-answer cannot provision (terms not ok), and the plan step is already
    # satisfied, so accepting the terms is the moment it becomes due.
    test "accepting terms after the plan provisions My Vault" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_free_tier(user)
      {:ok, _} = Onboarding.set_profile(user, %{tools: ["chatgpt"], tools_prefilled: true})
      assert [] = Engram.Vaults.list_vaults(user)

      {:ok, _} =
        Onboarding.accept_terms(user, "2026-05-15", "canonical", "2026-05-15", "p", %{})

      assert [%{name: "My Vault"}] = Engram.Vaults.list_vaults(user)
    end

    test "a later subscription event does not recreate a deleted vault" do
      user = prefilled_past_terms()
      {:ok, _} = Onboarding.accept_free_tier(Engram.Accounts.get_user!(user.id))
      [vault] = Engram.Vaults.list_vaults(user)
      {:ok, _} = Engram.Vaults.delete_vault(Engram.Accounts.get_user!(user.id), vault.id)
      insert(:subscription, user: user, paddle_subscription_id: "sub_renew_1", status: "active")

      {:ok, _} =
        Engram.Billing.upsert_from_paddle_event(%{
          "event_type" => "subscription.updated",
          "event_id" => "ntf_renew_1",
          "data" => %{
            "id" => "sub_renew_1",
            "status" => "past_due",
            "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}, "status" => "active"}],
            "current_billing_period" => %{
              "starts_at" => "2026-06-13T00:00:00Z",
              "ends_at" => "2026-07-13T00:00:00Z"
            }
          }
        })

      assert [] = Engram.Vaults.list_vaults(user)
    end

    # A connector signup from before connector profiles completed at the
    # pre-answer is still on the vault step. Provisioning for it would mint
    # "My Vault", and the Free cap would then refuse the vault it creates.
    test "a pre-filled profile without completed_at is never provisioned" do
      user =
        insert(:user, onboarding_profile: %{"tools" => ["chatgpt"], "tools_prefilled" => true})

      {:ok, _} =
        Onboarding.accept_terms(user, "2026-05-15", "canonical", "2026-05-15", "p", %{})

      assert [] = Engram.Vaults.list_vaults(user)
      assert %{next_step: :vault} = Onboarding.status(Engram.Accounts.get_user!(user.id))
    end

    test "a deleted My Vault is not recreated by re-accepting terms" do
      user = prefilled_past_terms()
      {:ok, _} = Onboarding.accept_free_tier(Engram.Accounts.get_user!(user.id))
      [vault] = Engram.Vaults.list_vaults(user)
      {:ok, _} = Engram.Vaults.delete_vault(Engram.Accounts.get_user!(user.id), vault.id)

      {:ok, _} =
        Onboarding.accept_terms(user, "2026-05-15", "canonical", "2026-05-15", "p", %{})

      assert [] = Engram.Vaults.list_vaults(user)
    end

    test "a deleted My Vault is not recreated by subscribing again" do
      user = prefilled_past_terms()
      {:ok, _} = Onboarding.accept_free_tier(Engram.Accounts.get_user!(user.id))
      [vault] = Engram.Vaults.list_vaults(user)
      {:ok, _} = Engram.Vaults.delete_vault(Engram.Accounts.get_user!(user.id), vault.id)

      {:ok, _} = Engram.Billing.upsert_from_paddle_event(created_event(user, "sub_again_1"))

      assert [] = Engram.Vaults.list_vaults(user)
    end

    # A webhook must finish its side effects and return {:ok, sub} even when
    # the vault cannot be made (here: the vault cap is 0).
    test "subscription.created still succeeds when provisioning fails" do
      user = prefilled_past_terms()
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 0})

      assert {:ok, %Engram.Billing.Subscription{}} =
               Engram.Billing.upsert_from_paddle_event(created_event(user, "sub_capped_1"))

      assert [] = Engram.Vaults.list_vaults(user)
    end

    # Only the first acceptance starts an account on Free. Re-accepting
    # changed terms is not a plan choice: a lapsed payer stays at the plan step.
    test "re-accepting changed terms does not start an account on Free" do
      user = insert(:user, onboarding_profile: %{"uses_obsidian" => false, "completed_at" => "x"})
      {:ok, _} = Onboarding.accept_terms(user, "2026-01-01", %{})

      {:ok, _} =
        Onboarding.accept_terms(user, "2026-05-15", "canonical", "2026-05-15", "p", %{})

      assert is_nil(Engram.Accounts.get_user!(user.id).free_tier_accepted_at)
    end

    test "provisioning is idempotent" do
      user = prefilled_past_terms()
      {:ok, _} = Onboarding.accept_free_tier(Engram.Accounts.get_user!(user.id))

      assert :ok = Onboarding.maybe_provision_connector_vault(user)
      assert [_one] = Engram.Vaults.list_vaults(user)
    end

    test "provisioning skips a user who already has a vault" do
      # Inserted first: the factory bypasses the vault-list cache eviction that
      # `register_vault/5` performs, so a later insert would read as no vault.
      user = insert(:user, onboarding_profile: %{})
      existing = insert(:vault, user: user)
      {:ok, _} = Onboarding.set_profile(user, %{tools: ["chatgpt"], tools_prefilled: true})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      {:ok, _} = Onboarding.accept_free_tier(Engram.Accounts.get_user!(user.id))

      assert [%{id: id}] = Engram.Vaults.list_vaults(user)
      assert id == existing.id
    end

    # The vault page POSTs `uses_obsidian` on a profile that still carries
    # `tools_prefilled`. Only the pre-answer may provision: otherwise picking
    # Obsidian mints a "My Vault" the plugin's own vault then hits the Free
    # cap over.
    test "a later uses_obsidian save provisions nothing" do
      user = prefilled_past_terms()
      {:ok, _} = Onboarding.accept_free_tier(Engram.Accounts.get_user!(user.id))
      [vault] = Engram.Vaults.list_vaults(user)
      {:ok, _} = Engram.Vaults.delete_vault(Engram.Accounts.get_user!(user.id), vault.id)

      assert {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true})
      assert [] = Engram.Vaults.list_vaults(user)
    end

    test "an ordinary tools answer provisions no vault" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      {:ok, _} = Onboarding.accept_free_tier(Engram.Accounts.get_user!(user.id))

      assert {:ok, _} = Onboarding.set_profile(user, %{tools: ["chatgpt"]})
      assert [] = Engram.Vaults.list_vaults(user)
    end

    test "signup_source records a plugin-first signup" do
      user = insert(:user, onboarding_profile: %{})

      assert {:ok, updated} =
               Onboarding.set_profile(user, %{uses_obsidian: true, signup_source: "plugin"})

      assert updated.onboarding_profile["signup_source"] == "plugin"
    end

    # Like `tools_prefilled`, a qualifier: on its own it would mark a signup
    # plugin-first without the Obsidian answer that makes it one.
    test "signup_source on its own is refused" do
      user = insert(:user, onboarding_profile: %{})

      assert {:error, :nothing_to_set} = Onboarding.set_profile(user, %{signup_source: "plugin"})
    end

    # The origin is where the signup STARTED: a plugin-first user who later
    # connects ChatGPT through a consent screen is still a plugin signup.
    test "a later connector pre-answer does not re-record the origin" do
      capture_posthog()
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, signup_source: "plugin"})
      {:ok, _} = Onboarding.set_profile(user, %{tools: ["chatgpt"], tools_prefilled: true})

      events = collect_posthog_events("signup_source_recorded")
      assert [%{"properties" => %{"signup_source" => "plugin"} = props}] = events
      assert props["$set_once"] == %{"signup_source" => "plugin", "signup_tool" => "obsidian"}
    end

    test "attribution is stored once, bounded, and sent as signup_attributed" do
      capture_posthog()
      user = insert(:user, onboarding_profile: %{})

      assert {:ok, updated} =
               Onboarding.set_profile(user, %{
                 attribution: %{
                   "utm_source" => "newsletter",
                   "utm_campaign" => String.duplicate("a", 100),
                   "via" => "todd",
                   "referrer_domain" => "News.YCombinator.com",
                   "utm_term" => "not allowlisted",
                   "utm_medium" => "has spaces/and slashes"
                 }
               })

      stored = updated.onboarding_profile["attribution"]

      assert stored == %{
               "utm_source" => "newsletter",
               "utm_campaign" => String.duplicate("a", 64),
               "via" => "todd",
               "referrer_domain" => "news.ycombinator.com"
             }

      assert [%{"properties" => props}] = collect_posthog_events("signup_attributed")
      assert props["utm_source"] == "newsletter"
      assert props["$set_once"]["referrer_domain"] == "news.ycombinator.com"
      assert props["$set_once"]["signup_source"] == "website"

      # First touch wins: a second post neither overwrites nor re-sends.
      {:ok, again} = Onboarding.set_profile(user, %{attribution: %{"utm_source" => "other"}})
      assert again.onboarding_profile["attribution"]["utm_source"] == "newsletter"
      assert [] = collect_posthog_events("signup_attributed")
    end

    test "attribution on a plugin or connector signup does not claim website" do
      capture_posthog()
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, signup_source: "plugin"})
      {:ok, _} = Onboarding.set_profile(user, %{attribution: %{"utm_source" => "x"}})

      assert [%{"properties" => props}] = collect_posthog_events("signup_attributed")
      refute Map.has_key?(props["$set_once"], "signup_source")
    end

    test "attribution must be a map with at least one usable field" do
      user = insert(:user, onboarding_profile: %{})

      assert {:error, :invalid_attribution} = Onboarding.set_profile(user, %{attribution: "x"})

      assert {:error, :invalid_attribution} =
               Onboarding.set_profile(user, %{attribution: %{"utm_term" => "x", "via" => 1}})
    end

    test "signup_source must be a known origin" do
      user = insert(:user, onboarding_profile: %{})

      assert {:error, :invalid_signup_source} =
               Onboarding.set_profile(user, %{signup_source: "web"})
    end

    test "tools_prefilled on its own is refused" do
      user = insert(:user, onboarding_profile: %{})

      assert {:error, :nothing_to_set} = Onboarding.set_profile(user, %{tools_prefilled: true})
    end

    test "tools_prefilled must be a boolean" do
      user = insert(:user, onboarding_profile: %{})

      assert {:error, :invalid_tools_prefilled} =
               Onboarding.set_profile(user, %{tools: ["claude"], tools_prefilled: "yes"})
    end

    test "an ordinary tools answer leaves tools_prefilled unset" do
      user = insert(:user, onboarding_profile: %{})

      assert {:ok, updated} = Onboarding.set_profile(user, %{tools: ["claude"]})
      refute Map.has_key?(updated.onboarding_profile, "tools_prefilled")
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
           claude_code cursor windsurf cline muse continue opencode github_copilot
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

      LegalFixtures.reset_version_cache()

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
        LegalFixtures.reset_version_cache()
      end)

      :ok
    end

    test "next_step :vault when fresh-start profile complete but no vault exists" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})

      assert %{has_vault: false, next_step: :vault} = Onboarding.status(user)
    end

    test "next_step :vault for obsidian user with no vault yet (wizard waits for plugin first sync)" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})

      assert %{has_vault: false, next_step: :vault} = Onboarding.status(user)
    end

    test "next_step :done for obsidian user once the plugin creates a vault" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
      insert(:vault, user: user)

      assert %{has_vault: true, next_step: :done} = Onboarding.status(user)
    end

    test "next_step :done for fresh user once a vault has been created" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})
      {:ok, _, _} = Engram.Vaults.register_vault(user, "My Vault", Ecto.UUID.generate())

      assert %{has_vault: true, next_step: :done} = Onboarding.status(user)
    end

    # `gate_ok` and `next_step` disagree here ON PURPOSE: the plugin cannot
    # create the first vault until the gate already admits it. Anything that
    # re-derives "may this user proceed" from `next_step` inverts this case.
    # The consent page did exactly that, and bounced obsidian users between
    # /oauth/consent and the wizard forever — the wizard had nothing left to
    # collect, and the gate had nothing left to refuse.
    test "gate_ok true for an obsidian user with no vault, while next_step stays :vault" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})

      assert %{gate_ok: true, next_step: :vault, has_vault: false} = Onboarding.status(user)
      assert :ok = Onboarding.gate(user)
    end

    test "gate_ok false for a fresh-start user with no vault" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})

      assert %{gate_ok: false, next_step: :vault} = Onboarding.status(user)
      assert {:error, ["vault"], :vault} = Onboarding.gate(user)
    end

    test "gate_ok agrees with gate/2 for a user who has accepted nothing" do
      user = insert(:user, onboarding_profile: %{})

      assert %{gate_ok: false} = Onboarding.status(user)
      assert {:error, missing, _} = Onboarding.gate(user)
      assert "terms" in missing
    end
  end

  describe "status/1 vault gate (next_step :heard / :vault come after :billing)" do
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

      LegalFixtures.reset_version_cache()

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
        LegalFixtures.reset_version_cache()
      end)

      :ok
    end

    # Tools and the survey moved into the app: neither is a wizard step.
    test "next_step :heard when terms + subscription ok, nothing answered" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")

      assert %{
               terms_ok: true,
               subscription_ok: true,
               profile_complete: false,
               next_step: :heard
             } = Onboarding.status(user)
    end

    test "next_step :vault once the survey is answered" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Onboarding.set_profile(user, %{tools: ["claude"]})
      :ok = Engram.Feedback.submit(user, "onboarding", %{"heard_from" => "reddit"})

      assert %{profile_complete: false, next_step: :vault} = Onboarding.status(user)
    end

    # Only `heard_from` answers the heard step: the in-app survey also writes
    # through `Feedback.submit/3` and never carries it.
    test "next_step stays :heard after a survey answer with no heard_from" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Onboarding.set_profile(user, %{tools: ["claude"]})
      :ok = Engram.Feedback.submit(user, "onboarding", %{})

      assert %{profile_complete: false, next_step: :heard} = Onboarding.status(user)
    end

    test "next_step :vault for obsidian user with no vault yet (wizard waits for plugin first sync)" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})

      assert %{profile_complete: true, has_vault: false, next_step: :vault} =
               Onboarding.status(user)
    end

    test "next_step :done once an obsidian user has a vault row" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
      insert(:vault, user: user)

      assert %{profile_complete: true, has_vault: true, next_step: :done} =
               Onboarding.status(user)
    end

    test "next_step :billing still wins over :tools when subscription missing" do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      assert %{next_step: :billing, profile_complete: false} = Onboarding.status(user)
    end

    test "next_step :agreement still wins when terms not accepted" do
      user = insert(:user, onboarding_profile: %{})
      insert(:subscription, user: user, status: "active")

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
      # UUID that no user_fixture mints.
      assert [] = Onboarding.list_actions(Ecto.UUID.generate())
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

  describe "stamp_free_tier/1" do
    # The one write of the stamp owns the `:user` eviction, queued to run when
    # the caller's outer transaction commits.
    test "a stamp inside an outer transaction leaves no stale cached user" do
      user = insert(:user, free_tier_accepted_at: nil)
      assert %{free_tier_accepted_at: nil} = Engram.Accounts.get_user(user.id)

      {:ok, _} =
        Engram.Repo.transaction_after_commit(fn -> Onboarding.stamp_free_tier(user) end)

      assert %{free_tier_accepted_at: %DateTime{}} = Engram.Accounts.get_user(user.id)
    end

    # Another request reads the still-committed (unstamped) row and caches it
    # after the stamp but before the outer transaction commits. Evicting at
    # the stamp would leave that stale entry; the eviction must run on commit.
    test "evicts after commit, so a read between stamp and commit is not kept" do
      user = insert(:user, free_tier_accepted_at: nil)

      {:ok, _} =
        Engram.Repo.transaction_after_commit(fn ->
          {:ok, _saved, :won} = Onboarding.stamp_free_tier(user)
          :ok = Engram.Cache.put(:user, user.id, user)
        end)

      assert %{free_tier_accepted_at: %DateTime{}} = Engram.Accounts.get_user(user.id)
    end

    test "evicts after commit inside a tenant transaction too" do
      user = insert(:user, free_tier_accepted_at: nil)

      {:ok, _} =
        Engram.Repo.with_tenant(user.id, fn ->
          {:ok, _saved, :won} = Onboarding.stamp_free_tier(user)
          :ok = Engram.Cache.put(:user, user.id, user)
        end)

      assert %{free_tier_accepted_at: %DateTime{}} = Engram.Accounts.get_user(user.id)
    end
  end

  describe "accept_free_tier/1" do
    test "sets free_tier_accepted_at on the user" do
      user = insert(:user, free_tier_accepted_at: nil)
      assert {:ok, updated} = Onboarding.accept_free_tier(user)
      assert updated.free_tier_accepted_at != nil
    end

    test "is idempotent — second call leaves timestamp untouched" do
      user = insert(:user, free_tier_accepted_at: nil)
      {:ok, first} = Onboarding.accept_free_tier(user)
      {:ok, second} = Onboarding.accept_free_tier(first)
      assert DateTime.compare(first.free_tier_accepted_at, second.free_tier_accepted_at) == :eq
    end

    # Concurrent callers holding the same unstamped struct (double click, a
    # retry racing the original): one stamp wins and every caller sees it,
    # and the connector vault is provisioned once.
    test "concurrent calls stamp once and provision one connector vault" do
      user = prefilled_past_terms()
      stale = Engram.Accounts.get_user!(user.id)

      stamps =
        1..5
        |> Task.async_stream(fn _ -> Onboarding.accept_free_tier(stale) end, max_concurrency: 5)
        |> Enum.map(fn {:ok, {:ok, saved}} -> saved.free_tier_accepted_at end)

      final = Engram.Accounts.get_user!(user.id).free_tier_accepted_at
      assert Enum.all?(stamps, &(DateTime.compare(&1, final) == :eq))
      assert [%{name: "My Vault"}] = Engram.Vaults.list_vaults(user)
    end
  end

  describe "next_step — Free tier" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      Application.put_env(:engram, :billing_enabled, true)

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

      LegalFixtures.reset_version_cache()
      on_exit(&LegalFixtures.reset_version_cache/0)

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
      end)

      :ok
    end

    test "user with free_tier_accepted_at and other steps done → :done" do
      user = insert(:user, free_tier_accepted_at: DateTime.utc_now(), onboarding_profile: %{})
      seed_onboarding_complete_except_billing(user)
      assert %{next_step: :done} = Onboarding.status(user)
    end

    test "user without free_tier or paid subscription → :billing" do
      # Under the tightened predicate (Option C), users must EXPLICITLY accept
      # Free via the onboarding wizard (`free_tier_accepted_at` set). Without
      # that acceptance, `subscription_ok` fails and `next_step` is `:billing`.
      user = insert(:user, free_tier_accepted_at: nil, onboarding_profile: %{})
      seed_onboarding_complete_except_billing(user)
      assert %{next_step: :billing} = Onboarding.status(user)
    end
  end

  # Bring user to "all gates pass except billing/free-tier": accept current
  # ToS, set profile (tools + uses_obsidian), and create a vault. Mirrors the
  # setup used by the "next_step=done" tests in `status/1 when billing is
  # enabled`. Caller controls billing state (subscription row or
  # `free_tier_accepted_at`).
  defp seed_onboarding_complete_except_billing(user) do
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
    insert(:vault, user: user)
    :ok
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

  # Points PostHog at a local stub that forwards each capture to this process.
  defp capture_posthog do
    prior =
      {Application.get_env(:engram, :posthog_key), Application.get_env(:engram, :posthog_host)}

    on_exit(fn ->
      Application.put_env(:engram, :posthog_key, elem(prior, 0))
      Application.put_env(:engram, :posthog_host, elem(prior, 1))
    end)

    bypass = Bypass.open()
    Application.put_env(:engram, :posthog_key, "phc_test_token")
    Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")
    parent = self()

    Bypass.stub(bypass, "POST", "/capture/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:posthog, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, "1")
    end)
  end

  # Every captured event named `event` that arrives within half a second.
  # Waits for the first `event` (the capture is async and slow under load),
  # then keeps collecting for a short quiet window so a duplicate still shows.
  defp collect_posthog_events(event) do
    receive do
      {:posthog, %{"event" => ^event} = body} -> collect_more_posthog_events(event, [body])
    after
      5_000 -> []
    end
  end

  defp collect_more_posthog_events(event, acc) do
    receive do
      {:posthog, %{"event" => ^event} = body} -> collect_more_posthog_events(event, [body | acc])
      {:posthog, _other} -> collect_more_posthog_events(event, acc)
    after
      500 -> Enum.reverse(acc)
    end
  end

  defp created_event(user, sub_id) do
    %{
      "event_type" => "subscription.created",
      "event_id" => "ntf_" <> sub_id,
      "data" => %{
        "id" => sub_id,
        "status" => "active",
        "customer_id" => "ctm_" <> sub_id,
        "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}, "status" => "active"}],
        "current_billing_period" => %{
          "starts_at" => "2026-05-13T00:00:00Z",
          "ends_at" => "2026-06-13T00:00:00Z"
        },
        "custom_data" => %{"user_id" => user.id}
      }
    }
  end

  defp prefilled_past_terms do
    user = insert(:user, onboarding_profile: %{})
    {:ok, _} = Onboarding.set_profile(user, %{tools: ["chatgpt"], tools_prefilled: true})
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    user
  end

  # Profiles as each origin writes them (see `Onboarding.set_profile/2`).
  defp loop_profile(origin, uses_obsidian) do
    base =
      case origin do
        :web -> %{}
        :plugin -> %{"signup_source" => "plugin"}
        :connector -> %{"tools" => ["chatgpt"], "tools_prefilled" => true}
        :legacy_connector -> %{"tools" => ["chatgpt"], "tools_prefilled" => true}
      end

    base = if is_nil(uses_obsidian), do: base, else: Map.put(base, "uses_obsidian", uses_obsidian)

    complete =
      origin == :connector or (origin != :legacy_connector and is_boolean(uses_obsidian))

    if complete, do: Map.put(base, "completed_at", "2026-10-01T00:00:00Z"), else: base
  end
end
