defmodule EngramWeb.PluginVersionGateChannelTest do
  @moduledoc """
  The socket half of the compatibility floor. `EngramWeb.Plugs.RequirePluginVersion`
  covers REST, but sync runs over these channels and a Plug never runs on a
  socket — enforcing only the HTTP half would leave a "blocked" client syncing
  happily, which is the failure this pins.
  """
  use EngramWeb.ChannelCase, async: false

  alias Engram.LegalFixtures
  alias Engram.Onboarding
  alias Engram.Onboarding.GateCache
  alias Engram.Vaults

  # Old enough to sit below any floor we would ever set, so this file does not
  # need editing when the floor moves.
  @ancient "0.0.1"

  defp socket_with_version(user, version) do
    socket(EngramWeb.UserSocket, "user_#{user.id}", %{
      current_user: user,
      current_api_key: nil,
      plugin_version: version
    })
  end

  defp join_crdt(user, vault_id, version) do
    subscribe_and_join(
      socket_with_version(user, version),
      EngramWeb.CrdtChannel,
      "crdt:#{user.id}:#{vault_id}",
      %{"crdt_proto" => 2}
    )
  end

  setup do
    prev = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)

    LegalFixtures.insert_version(
      document: "terms_of_service",
      version: "2026-05-15",
      content_hash: "canonical",
      material: true,
      effective_date: nil
    )

    LegalFixtures.reset_version_cache()
    GateCache.evict_all()

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev)
      LegalFixtures.reset_version_cache()
      GateCache.evict_all()
    end)

    # FULLY onboarded, deliberately. The version floor sits AFTER the
    # onboarding gate (see the precedence test below), so a half-set-up user
    # would fail these for the wrong reason and the file would pass while
    # testing nothing.
    user = insert_user(onboarding_profile: %{})
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Vaults.register_vault(user, "PluginFloor", Ecto.UUID.generate())
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    {:ok, _} = Onboarding.accept_free_tier(user)
    {:ok, user} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
    GateCache.evict_all()

    {:ok, user: user, vault: vault}
  end

  describe "crdt:" do
    test "an old plugin is refused with everything it needs to recover", ctx do
      assert {:error, payload} = join_crdt(ctx.user, ctx.vault.id, @ancient)

      # LITERALS. Comparing against PluginVersion.minimum()/update_url() would
      # re-derive the expectation from the module under test and pass even if
      # that module were corrupted.
      assert payload.reason == "plugin_upgrade_required"
      assert payload.min_version == "1.28.0"
      assert payload.your_version == @ancient
      assert payload.update_url == "obsidian://show-plugin?id=engram-vault-sync"
    end

    # The gate must stay behind the free topic-ownership match: the plugin's
    # identity self-heal keys on `unauthorized` specifically.
    test "a foreign topic still reports unauthorized, not upgrade", ctx do
      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket_with_version(ctx.user, @ancient),
                 EngramWeb.CrdtChannel,
                 "crdt:#{Ecto.UUID.generate()}:#{ctx.vault.id}",
                 %{"crdt_proto" => 2}
               )
    end
  end

  describe "sync:" do
    test "an old plugin is refused", ctx do
      assert {:error, %{reason: "plugin_upgrade_required"}} =
               subscribe_and_join(
                 socket_with_version(ctx.user, @ancient),
                 EngramWeb.SyncChannel,
                 "sync:#{ctx.user.id}:#{ctx.vault.id}"
               )
    end
  end

  describe "everything unknown is allowed" do
    # nil is every client shipped to date plus the web SPA. If this ever fails,
    # the floor has been made fail-closed and the installed base is bricked.
    test "a socket with no reported version joins", ctx do
      assert {:ok, _, _} = join_crdt(ctx.user, ctx.vault.id, nil)
    end

    test "a version at the floor joins", ctx do
      assert {:ok, _, _} = join_crdt(ctx.user, ctx.vault.id, "1.28.0")
    end

    # A PREVIEW of a LATER release. `nextPatch` means a preview of stable
    # 1.28.0 is named 1.28.1-*, which sorts above a 1.28.0 floor. The
    # dangerous neighbour — a pre-release OF the floor — is refused, and
    # pinned in plugin_version_test.exs.
    test "a preview build above the floor joins", ctx do
      assert {:ok, _, _} = join_crdt(ctx.user, ctx.vault.id, "1.28.1-pr.512.g876f2c2")
    end
  end

  # Precedence runs the OTHER way from what reads nicest, on purpose. The floor
  # sits after the liveness stamp on both transports, so an un-onboarded user
  # hears about onboarding first. That costs a less useful message and buys the
  # thing that matters: a refused client still stamps `last_active_at`, so
  # `InactivityCleanup` cannot soft-delete someone who syncs daily and merely
  # runs an old plugin. If this ever reports `plugin_upgrade_required`, the
  # gate moved above the stamp and the data loss came back with it.
  test "onboarding is reported before the floor, because the floor sits after the stamp" do
    bare = insert_user(onboarding_profile: %{})

    assert {:error, %{reason: "onboarding_required"}} =
             join_crdt(bare, Ecto.UUID.generate(), @ancient)
  end
end
