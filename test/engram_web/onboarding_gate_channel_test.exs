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

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Legal.VersionCache
  alias Engram.LegalFixtures
  alias Engram.Onboarding
  alias Engram.Onboarding.GateCache
  alias Engram.Repo
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
    {:ok, vault, _} = Vaults.register_vault(user, "Ungated", Ecto.UUID.generate())

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

      Sandbox.allow(Repo, self(), joined.channel_pid)
    end

    # Counterpart to the positive self-host test below, mirroring
    # `require_onboarding_test.exs`. Without this, short-circuiting `gate/1`
    # to `:ok` whenever `billing_enabled` is false passes the entire suite:
    # the positive test satisfies every precondition for a pass, so it stays
    # green even if the gate is deleted from both channels outright.
    test "self-host still gates on profile — billing off is not auth off", %{
      user: user,
      vault: vault
    } do
      Application.put_env(:engram, :billing_enabled, false)
      GateCache.evict_all()

      assert {:error, %{reason: "onboarding_required", missing: ["profile"]}} =
               subscribe_and_join(
                 user_socket(user),
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )
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

      Sandbox.allow(Repo, self(), joined.channel_pid)
    end
  end

  describe "gate ordering (the checks it must not displace)" do
    # A `crdt:<other-user>:<uuid>` probe costs zero DB work. Deriving the
    # onboarding verdict costs ~4 round-trips including an RLS transaction,
    # and there is no join rate limiter — so the free ownership match has to
    # come first. The plugin's identity self-heal also keys on this exact
    # reason (channel.ts, e2e test_84); replacing it wedges the heal.
    test "a foreign topic still returns unauthorized, not onboarding_required", %{
      socket: socket,
      vault: vault
    } do
      other = insert_user(onboarding_profile: %{})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.CrdtChannel,
                 "crdt:#{other.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )
    end

    test "sync: foreign topic likewise", %{socket: socket, vault: vault} do
      other = insert_user(onboarding_profile: %{})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, EngramWeb.SyncChannel, "sync:#{other.id}:#{vault.id}")
    end

    # T3.7: a user mid-DEK-rotation must hear rotation_in_progress. Gating
    # ahead of RotationGate.check/1 would have swallowed it.
    test "rotation_in_progress outranks onboarding_required", %{user: user, vault: vault} do
      {:ok, _} =
        user
        |> Ecto.Changeset.change(dek_rotation_locked_at: DateTime.utc_now())
        |> Repo.update()

      assert {:error, %{reason: "rotation_in_progress"}} =
               subscribe_and_join(
                 user_socket(user),
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )
    end
  end

  describe "socket-frozen user struct" do
    # `UserSocket` assigns current_user ONCE at connect/3. A Free user who
    # finishes onboarding mid-session (accept_free_tier is a bare Repo.update
    # with no socket disconnect) must not be judged on the stale struct — it
    # would lock them out for the life of the connection, and Free is the
    # default cohort. Note the socket is built BEFORE onboarding completes.
    test "completing onboarding on an already-open socket takes effect", %{
      user: user,
      vault: vault,
      socket: socket
    } do
      assert {:error, %{reason: "onboarding_required"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )

      _ = complete_onboarding!(user)

      # Same stale socket, no reconnect.
      assert {:ok, _, joined} =
               subscribe_and_join(
                 socket,
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )

      Sandbox.allow(Repo, self(), joined.channel_pid)
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

    # Leaving `user:` open is deliberate, so it has to survive being talked to.
    # Phoenix dispatches inbound events unconditionally
    # (`Phoenix.Channel.Server.handle_info/2` -> `socket.channel.handle_in/3`),
    # so a channel with no `handle_in/3` clause raises UndefinedFunctionError
    # and the process dies. Server-push-only is a client convention, not an
    # enforced one — and this topic is reachable by accounts that have accepted
    # nothing and paid nothing.
    test "an unsolicited client push does not kill the channel", %{
      socket: socket,
      user: user
    } do
      {:ok, _, joined} = subscribe_and_join(socket, EngramWeb.UserChannel, "user:#{user.id}")
      ref = Process.monitor(joined.channel_pid)

      push(joined, "definitely_not_a_real_event", %{"x" => 1})

      refute_receive {:DOWN, ^ref, :process, _, _}, 300
      assert Process.alive?(joined.channel_pid)
    end
  end
end
