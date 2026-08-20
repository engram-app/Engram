defmodule EngramWeb.LifecycleGateChannelTest do
  @moduledoc """
  #1426 ported ONE of the three vault-pipeline gates to the sockets. These pin
  the other two: `AccountLifecycle` (410 deleted / 403 suspended) and
  `RequireActiveSubscription` (402 suspended). Without them an admin could
  suspend an abusive account, `SessionInvalidator` would kill its sockets, and
  the still-valid JWT would reconnect seconds later into full read/write CRDT
  sync while every REST call returned 402/410.
  """
  use EngramWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.LegalFixtures
  alias Engram.Onboarding
  alias Engram.Onboarding.GateCache
  alias Engram.Repo
  alias Engram.Vaults

  setup do
    prev = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)

    # Seed + accept an explicit version rather than relying on "no versions
    # exist". VersionCache is node-local ETS and is NOT sandboxed, so a
    # concurrent case seeding a material version leaks a terms floor in here
    # and every test fails on missing: ["terms"] instead of the lifecycle
    # reason it is actually asserting (see #1427).
    LegalFixtures.insert_version(
      document: "terms_of_service",
      version: "2026-05-15",
      content_hash: "canonical",
      material: true,
      effective_date: nil
    )

    # reset_version_cache/0, not invalidate_all/0 — it adds the :sys.get_state
    # barrier so the async invalidation cannot land mid-test.
    LegalFixtures.reset_version_cache()
    GateCache.evict_all()

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev)
      LegalFixtures.reset_version_cache()
      GateCache.evict_all()
    end)

    user = insert_user(onboarding_profile: %{})
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault} = Vaults.create_vault(user, %{name: "Lifecycle"})

    # Fully onboarded on purpose: these tests must fail for LIFECYCLE reasons,
    # not because the onboarding gate happened to catch them first.
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    {:ok, _} = Onboarding.accept_free_tier(user)
    {:ok, user} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
    GateCache.evict_all()

    {:ok, user: user, vault: vault}
  end

  defp mark!(user, field) do
    {:ok, user} =
      user
      |> Ecto.Changeset.change([{field, DateTime.utc_now()}])
      |> Repo.update()

    # The gate caches PASS verdicts; a suspension must not be masked by one.
    GateCache.evict_all()
    user
  end

  defp join_crdt(user, vault) do
    subscribe_and_join(
      user_socket(user),
      EngramWeb.CrdtChannel,
      "crdt:#{user.id}:#{vault.id}",
      %{"crdt_proto" => 2}
    )
  end

  describe "suspended accounts" do
    test "crdt: join is refused", %{user: user, vault: vault} do
      user = mark!(user, :suspended_at)
      assert {:error, %{reason: "account_suspended"}} = join_crdt(user, vault)
    end

    test "sync: join is refused", %{user: user, vault: vault} do
      user = mark!(user, :suspended_at)

      assert {:error, %{reason: "account_suspended"}} =
               subscribe_and_join(
                 user_socket(user),
                 EngramWeb.SyncChannel,
                 "sync:#{user.id}:#{vault.id}"
               )
    end

    # The reconnect path is the whole point: SessionInvalidator kills the live
    # socket, but the JWT is still valid and the client comes straight back.
    test "a fresh socket after suspension is still refused", %{user: user, vault: vault} do
      assert {:ok, _, joined} = join_crdt(user, vault)
      Sandbox.allow(Repo, self(), joined.channel_pid)

      user = mark!(user, :suspended_at)
      assert {:error, %{reason: "account_suspended"}} = join_crdt(user, vault)
    end

    # AccountLifecycle exempts /api/billing/* so a suspended user can pay their
    # way out. `user:` is the socket equivalent — it carries
    # `subscription_activated`, so gating it would strand them.
    test "user: stays joinable so they can self-reactivate", %{user: user} do
      user = mark!(user, :suspended_at)

      assert {:ok, _, _} =
               subscribe_and_join(user_socket(user), EngramWeb.UserChannel, "user:#{user.id}")
    end
  end

  describe "soft-deleted accounts" do
    test "crdt: join is refused", %{user: user, vault: vault} do
      user = mark!(user, :deleted_at)
      assert {:error, %{reason: "account_deleted"}} = join_crdt(user, vault)
    end

    test "sync: join is refused", %{user: user, vault: vault} do
      user = mark!(user, :deleted_at)

      assert {:error, %{reason: "account_deleted"}} =
               subscribe_and_join(
                 user_socket(user),
                 EngramWeb.SyncChannel,
                 "sync:#{user.id}:#{vault.id}"
               )
    end

    # Deleted takes precedence over suspended (mirrors the plug).
    test "deleted outranks suspended", %{user: user, vault: vault} do
      user = mark!(user, :suspended_at)
      user = mark!(user, :deleted_at)
      assert {:error, %{reason: "account_deleted"}} = join_crdt(user, vault)
    end
  end

  describe "healthy accounts" do
    test "still join normally", %{user: user, vault: vault} do
      assert {:ok, _, joined} = join_crdt(user, vault)
      Sandbox.allow(Repo, self(), joined.channel_pid)
    end
  end
end
