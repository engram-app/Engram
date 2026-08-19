defmodule EngramWeb.OnboardingGateChannelTest do
  @moduledoc """
  Sync moved to Phoenix Channels; `RequireOnboarding` is a Plug and a Plug
  never runs on a socket. These tests pin the WebSocket half of the gate so a
  user who skipped ToS + plan selection cannot sync a vault anyway.

  The `user:` channel is deliberately NOT gated — the FTUX vault screen joins
  it mid-wizard to wait for `vault_created`/`vault_populated`, so gating it
  would deadlock the very onboarding step it is meant to enforce.
  """
  use EngramWeb.ChannelCase, async: false

  alias Engram.Legal.VersionCache
  alias Engram.LegalFixtures
  alias Engram.Onboarding
  alias Engram.Onboarding.GateCache
  alias Engram.Vaults

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

    VersionCache.invalidate_all()
    GateCache.evict_all()

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev_enabled)
      VersionCache.invalidate_all()
      GateCache.evict_all()
    end)

    # The reported staging account: signed up, never accepted ToS, never
    # picked a plan. `onboarding_profile: %{}` is the factory's documented
    # opt-out of its "already onboarded" default.
    user = insert_user(onboarding_profile: %{})
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault} = Vaults.create_vault(user, %{name: "Ungated"})

    {:ok, user: user, vault: vault, socket: user_socket(user)}
  end

  defp complete_onboarding!(user) do
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    {:ok, user} = Onboarding.accept_free_tier(user)
    {:ok, user} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
    GateCache.evict_all()
    user
  end

  describe "crdt: channel (the live sync write path)" do
    test "join is refused for an un-onboarded user", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      assert {:error, %{reason: "onboarding_required"} = err} =
               subscribe_and_join(
                 socket,
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )

      assert "terms" in err.missing
      assert "subscription" in err.missing
    end

    test "join succeeds once onboarding completes", %{user: user, vault: vault} do
      user = complete_onboarding!(user)

      assert {:ok, _, joined} =
               subscribe_and_join(
                 user_socket(user),
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )

      Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, self(), joined.channel_pid)
    end

    test "self-host (billing disabled) is unaffected", %{user: user, vault: vault} do
      Application.put_env(:engram, :billing_enabled, false)
      GateCache.evict_all()
      {:ok, user} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
      GateCache.evict_all()

      assert {:ok, _, joined} =
               subscribe_and_join(
                 user_socket(user),
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )

      Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, self(), joined.channel_pid)
    end
  end

  describe "sync: channel (manifest / legacy pull path)" do
    test "join is refused for an un-onboarded user", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      assert {:error, %{reason: "onboarding_required"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.SyncChannel,
                 "sync:#{user.id}:#{vault.id}"
               )
    end

    test "join succeeds once onboarding completes", %{user: user, vault: vault} do
      user = complete_onboarding!(user)
      assert {:ok, _, _} = join_sync(user_socket(user), user, vault)
    end
  end

  describe "user: channel (wizard notifications)" do
    test "join is ALLOWED un-onboarded — the FTUX vault screen depends on it", %{
      socket: socket,
      user: user
    } do
      assert {:ok, %{plan: %{tier: :free}}, _} =
               subscribe_and_join(socket, EngramWeb.UserChannel, "user:#{user.id}")
    end
  end
end
