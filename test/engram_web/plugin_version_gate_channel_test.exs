defmodule EngramWeb.PluginVersionGateChannelTest do
  @moduledoc """
  The socket half of the compatibility floor. `EngramWeb.Plugs.RequirePluginVersion`
  covers REST, but sync runs over these channels and a Plug never runs on a
  socket — enforcing only the HTTP half would leave a "blocked" client syncing
  happily, which is the failure this pins.
  """
  use EngramWeb.ChannelCase, async: false

  alias Engram.PluginVersion

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

  setup do
    user = insert_user(onboarding_profile: %{})
    # Never resolved: the gate refuses ahead of the vault lookup, which is the
    # point — a blocked client is refused before it can touch anything.
    {:ok, user: user, vault_id: Ecto.UUID.generate()}
  end

  describe "crdt:" do
    test "an old plugin is refused with everything it needs to recover", ctx do
      assert {:error, payload} =
               subscribe_and_join(
                 socket_with_version(ctx.user, @ancient),
                 EngramWeb.CrdtChannel,
                 "crdt:#{ctx.user.id}:#{ctx.vault_id}",
                 %{"crdt_proto" => 2}
               )

      assert payload.reason == "plugin_upgrade_required"
      assert payload.min_version == PluginVersion.minimum()
      assert payload.your_version == @ancient
      assert payload.update_url == PluginVersion.update_url()
    end

    # Precedence: this user is NOT onboarded, so without the floor sitting
    # ahead of the onboarding gate they would be told to finish the wizard —
    # advice they cannot act on with a client that cannot speak the protocol.
    test "the upgrade verdict beats the onboarding verdict", ctx do
      assert {:error, %{reason: "plugin_upgrade_required"}} =
               subscribe_and_join(
                 socket_with_version(ctx.user, @ancient),
                 EngramWeb.CrdtChannel,
                 "crdt:#{ctx.user.id}:#{ctx.vault_id}",
                 %{"crdt_proto" => 2}
               )
    end

    # The gate must stay behind the free topic-ownership match: the plugin's
    # identity self-heal keys on `unauthorized` specifically.
    test "a foreign topic still reports unauthorized, not upgrade", ctx do
      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket_with_version(ctx.user, @ancient),
                 EngramWeb.CrdtChannel,
                 "crdt:#{Ecto.UUID.generate()}:#{ctx.vault_id}",
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
                 "sync:#{ctx.user.id}:#{ctx.vault_id}"
               )
    end
  end

  describe "everything unknown is allowed" do
    # nil is every client shipped to date plus the web SPA. If this ever fails,
    # the floor has been made fail-closed and the installed base is bricked.
    test "a socket with no reported version gets past the floor", ctx do
      assert {:error, payload} =
               subscribe_and_join(
                 socket_with_version(ctx.user, nil),
                 EngramWeb.CrdtChannel,
                 "crdt:#{ctx.user.id}:#{ctx.vault_id}",
                 %{"crdt_proto" => 2}
               )

      refute payload.reason == "plugin_upgrade_required"
    end

    test "a current version gets past the floor", ctx do
      assert {:error, payload} =
               subscribe_and_join(
                 socket_with_version(ctx.user, PluginVersion.minimum()),
                 EngramWeb.CrdtChannel,
                 "crdt:#{ctx.user.id}:#{ctx.vault_id}",
                 %{"crdt_proto" => 2}
               )

      refute payload.reason == "plugin_upgrade_required"
    end
  end
end
