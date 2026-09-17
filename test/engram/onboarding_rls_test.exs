defmodule Engram.OnboardingRlsTest do
  @moduledoc """
  Pins onboarding's `user_agreements` access against an ENFORCED row-level
  security policy.

  ## The incident this fences

  Staging, image `engram:80ec292`, the moment PR #1674 split the DB roles and
  the app pool began connecting as `engram_app` (no SUPERUSER, no BYPASSRLS):
  onboarding broke for 100% of users, in both directions at once.

    * `query_accepted_version/2` returned nil for users who HAD accepted — a
      FILTERED read, not an error. `terms_ok` read false and the wizard sent an
      already-onboarded user back to /onboard/agreement. Verified against a
      user holding terms_of_service + privacy_policy rows dated 2026-06-15.
    * `insert_agreement/1` then raised 42501 (insufficient_privilege), so
      POST /api/onboarding/accept-terms answered 500. Dead end both ways.

  `skip_tenant_check: true` was on both call sites. It only silences Engram's
  own `Repo.prepare_query/3` tripwire; it sets no `app.current_tenant`, so it
  is not a substitute for `Repo.with_tenant/2`.

  ## Why the two tests that look like they cover this did not

  Both were green through the incident, and it is worth being precise about
  why, because the shape recurs:

    * `repo_user_agreements_tenant_test.exs` asserts `Repo.all(Agreement)`
      raises `Engram.TenantError` — the APP-level guard. The production code
      passed `skip_tenant_check: true`, which bypasses exactly that guard, so
      the test never exercised the production call path.
    * `rls_coverage_test.exs` is schema-level: it proves the TABLE has RLS
      enabled, forced, and a policy. It says nothing about any call site.

  A test only covers this class if it runs a real public function under a
  non-BYPASSRLS role. That is what this file does.

  `async: false` because the role change is connection-global. See
  `docs/context/rls-enforcement-testing-traps.md`.
  """

  use Engram.DataCase, async: false

  # The rolling-back variant, because the INSERT under test RAISES when
  # unscoped — that 42501 is the staging 500 this file fences.
  import Engram.RlsCase

  alias Engram.LegalFixtures
  alias Engram.Onboarding
  alias Engram.Onboarding.Agreement
  alias Engram.Repo

  @tos "terms_of_service"
  @privacy "privacy_policy"
  @version "2026-05-15"

  setup do
    prev_enabled = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)

    LegalFixtures.reset_version_cache()

    # Floor and current both at @version, material and effective now, so an
    # acceptance of @version satisfies the gate.
    LegalFixtures.insert_version(
      document: @tos,
      version: @version,
      content_hash: "canonical",
      material: true,
      effective_date: nil
    )

    LegalFixtures.insert_version(
      document: @privacy,
      version: @version,
      content_hash: "p",
      material: true,
      effective_date: nil
    )

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev_enabled)
      LegalFixtures.reset_version_cache()
    end)

    :ok
  end

  # Seeds an acceptance WITHOUT going through `accept_terms/3`.
  #
  # Load-bearing: the private `accepted_version/2` is cache-first, and
  # `accept_terms/6` warms `TermsCache` for exactly the `{user_id, document}`
  # key the `status/1` test reads back. Seeding through that API would let the
  # assertion pass out of ETS without touching the row under test.
  #
  # The other thing keeping that read honest is that EVERY test here inserts a
  # FRESH user, so the cache key cannot be warm from this file or a prior one.
  # That property is load-bearing and easy to destroy: a refactor to a shared
  # setup user would make the `status/1` assertion vacuous, silently.
  # (`TermsCache` does expose `delete_local/1` and `clear_local/0` via
  # `Engram.Cache.NodeLocalEts` if a future test needs explicit eviction;
  # `LegalFixtures.reset_version_cache/0` resets `VersionCache` only.)
  defp seed_acceptance!(user, document) do
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        %Agreement{}
        |> Agreement.changeset(%{
          user_id: user.id,
          document: document,
          version: @version,
          accepted_at: DateTime.utc_now(:second)
        })
        |> Repo.insert()
      end)
  end

  describe "onboarding under enforced RLS" do
    # CONTROL. Without this every assertion below is ambiguous between
    # "correctly scoped" and "the role drop never engaged".
    test "control: an unscoped user_agreements read is filtered to zero rows" do
      user = insert(:user, onboarding_profile: %{})
      seed_acceptance!(user, @tos)

      outcome = as_prod_role(fn -> Repo.all(Agreement, skip_tenant_check: true) end)

      assert outcome == {:returned, []},
             """
             Harness is not engaging RLS, so every assertion in this file is meaningless.

               rows visible as engram_app with no tenant: #{inspect(outcome)} (expected {:returned, []})

             Either SET LOCAL ROLE did not apply, or the tenant was not cleared,
             or the role has BYPASSRLS.
             """
    end

    test "accept_terms/3 inserts instead of raising 42501" do
      user = insert(:user, onboarding_profile: %{})

      assert {:returned, {:ok, %Agreement{} = row}} =
               as_prod_role(fn -> Onboarding.accept_terms(user, @version, %{}) end),
             "accept_terms raised or errored under enforced RLS — this is the 500 that " <>
               "blocked every signup on staging"

      assert row.user_id == user.id
      assert row.version == @version
    end

    test "accept_terms/6 succeeds with both of its inserts scoped" do
      # The 6-arity form calls insert_agreement/1 twice inside one
      # Repo.transaction, each independently scoped (the process-dict tenant is
      # deleted on exit, so the second call re-enters rather than reusing the
      # first scope). `{:ok, tos_row}` is only returned when BOTH inserts
      # succeed, which is what makes this meaningful — the harness rolls back,
      # so the privacy row cannot be read back directly.
      user = insert(:user, onboarding_profile: %{})

      assert {:returned, {:ok, %Agreement{document: @tos}}} =
               as_prod_role(fn ->
                 Onboarding.accept_terms(user, @version, "tos-hash", @version, "priv-hash", %{})
               end)
    end

    test "status/1 sees an acceptance the cache never warmed" do
      user = insert(:user, onboarding_profile: %{})
      seed_acceptance!(user, @tos)
      seed_acceptance!(user, @privacy)

      assert {:returned, %{terms_ok: true}} =
               as_prod_role(fn -> Onboarding.status(user) end),
             "terms_ok read false for a user who HAS accepted — the filtered read that " <>
               "sent onboarded users back to /onboard/agreement"
    end
  end
end
