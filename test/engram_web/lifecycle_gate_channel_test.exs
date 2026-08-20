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
  alias Engram.UsageMeters
  alias Engram.UsageMeters.ActivityCache
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

    # Deliberately NOT evicting GateCache here. Lifecycle is never cached by
    # design, so eviction is not needed for these tests to pass — but a warm
    # PASS entry (left by an earlier successful join in the same test) is the
    # ONLY signal that catches someone "optimizing" the double read by putting
    # lifecycle behind the cache. Evicting threw that detector away: the
    # review proved a `GateCache.passed?` short-circuit in `check/1` left all
    # 22 tests across both gate files green.
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

      _suspended = mark!(user, :suspended_at)

      # Rejoin on a socket built from the PRE-suspension struct — that is the
      # real shape: `UserSocket` freezes `current_user` at `connect/3`, so the
      # reconnecting client's socket predates the suspension. Passing the
      # already-mutated struct (as this test used to) would keep passing even
      # if `check/1` read `socket.assigns.current_user` instead of the DB,
      # which is exactly the invariant the extra read exists to hold.
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

  # The `user:` carve-out is SUSPENSION-specific: it mirrors AccountLifecycle
  # allowlisting `/api/billing/*` so a suspended user can pay their way out.
  # Deletion has no such exemption — the deleted clause runs ahead of the
  # allowlist and HTTP is terminal, "410 on every endpoint, no exemptions".
  describe "user: channel vs deletion (#1435)" do
    test "a deleted account cannot join user:", %{user: user} do
      _deleted = mark!(user, :deleted_at)

      assert {:error, %{reason: "account_deleted"}} =
               subscribe_and_join(user_socket(user), EngramWeb.UserChannel, "user:#{user.id}")
    end

    test "an un-onboarded account CAN still join user: — the wizard needs it", %{vault: _v} do
      fresh = insert_user(onboarding_profile: %{})

      assert {:ok, _, _} =
               subscribe_and_join(user_socket(fresh), EngramWeb.UserChannel, "user:#{fresh.id}")
    end
  end

  describe "soft-deleted accounts" do
    test "crdt: join is refused", %{user: user, vault: vault} do
      # `user` stays the PRE-deletion struct on purpose — see the suspension
      # test above. The gate must read the row, not the socket.
      _deleted = mark!(user, :deleted_at)
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

  describe "purged accounts (row gone)" do
    # `Accounts.Lifecycle.hard_delete/2` removes the row outright, so the
    # re-read returns nil. Falling back to the socket's frozen `current_user`
    # there is fail-OPEN: that struct predates the deletion and carries no
    # `deleted_at`, so lifecycle would pass and a purged account with a
    # still-valid JWT would keep syncing. HTTP fails closed on this path —
    # `Plugs.Auth` cannot resolve a missing user and 401s — so the socket must
    # not be more permissive than the pipeline it is mirroring.
    test "crdt: join is refused once the row is gone", %{user: user, vault: vault} do
      Repo.delete!(user)
      GateCache.evict_all()

      assert {:error, %{reason: "account_deleted"}} = join_crdt(user, vault)
    end

    test "sync: join is refused once the row is gone", %{user: user, vault: vault} do
      Repo.delete!(user)
      GateCache.evict_all()

      assert {:error, %{reason: "account_deleted"}} =
               subscribe_and_join(
                 user_socket(user),
                 EngramWeb.SyncChannel,
                 "sync:#{user.id}:#{vault.id}"
               )
    end
  end

  describe "liveness (the half that decides when deleted_at gets set)" do
    # `EngramWeb.Plugs.BumpActivity` stamps `usage_meters.last_active_at` and
    # runs ONLY on `:authed_api`. `InactivityCleanup.sweep_soft_delete/0`
    # soft-deletes Free accounts whose stamp has aged past the window.
    #
    # So a plugin user who syncs daily over CRDT and rarely touches REST ages
    # into that sweep while in constant active use. Before the lifecycle gate
    # that was invisible — sync kept working. WITH the gate it becomes a
    # permanent `account_deleted` refusal on a live account whose Qdrant points
    # and S3 attachments the sweep already dropped.
    #
    # Porting the enforcement half of the pipeline without the liveness half
    # is what turns a latent mis-classification into user-visible data loss.
    test "a crdt: join stamps last_active_at", %{user: user, vault: vault} do
      ActivityCache.clear_local()

      assert {:ok, _, joined} = join_crdt(user, vault)
      Sandbox.allow(Repo, self(), joined.channel_pid)

      assert %DateTime{} = UsageMeters.last_active_at(user.id)
    end

    test "a sync: join stamps last_active_at", %{user: user, vault: vault} do
      ActivityCache.clear_local()

      assert {:ok, _, _} =
               subscribe_and_join(
                 user_socket(user),
                 EngramWeb.SyncChannel,
                 "sync:#{user.id}:#{vault.id}"
               )

      assert %DateTime{} = UsageMeters.last_active_at(user.id)
    end

    # An ACCOUNT-refused join is not activity: a suspended or deleted client
    # retrying forever must not keep its own account looking alive.
    test "an account-gate refusal does not stamp", %{user: user, vault: vault} do
      ActivityCache.clear_local()
      user = mark!(user, :suspended_at)

      assert {:error, %{reason: "account_suspended"}} = join_crdt(user, vault)
      assert is_nil(UsageMeters.last_active_at(user.id))
    end

    # An ENTITLEMENT refusal is the opposite, and deliberately so: the account
    # is healthy, only its API plan is not. HTTP stamps here too — BumpActivity
    # is router.ex:57, RequireApiRpsBudget is :58 — so a Pro user with a PAT
    # integration who downgrades to Free stays visibly alive on both
    # transports. Stamping after the entitlement gate instead would let
    # InactivityCleanup soft-delete an account generating daily traffic.
    test "an ENTITLEMENT refusal still stamps", %{user: user, vault: vault} do
      ActivityCache.clear_local()
      {:ok, _raw, api_key} = Engram.Accounts.create_api_key(user, "no-entitlement")

      assert {:error, %{reason: "api_access_not_available"}} =
               subscribe_and_join(
                 user_socket(user, api_key),
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )

      assert %DateTime{} = UsageMeters.last_active_at(user.id)
    end
  end

  # `RotationLockCheck` runs on :authed_api and its moduledoc is explicit that
  # "Read AND write paths block" — rotated rows reference a dek_version whose
  # master mapping has not flipped yet, so any decrypt with the old DEK fails
  # until the rotation completes. CrdtChannel open-coded a check; SyncChannel
  # had none, so a mid-rotation user was blocked on every HTTP route and on
  # `crdt:` but received Presence + note_changed on `sync:` for the whole
  # rotation window. (#1434)
  describe "DEK rotation (#1434)" do
    setup %{user: user} do
      {:ok, _} =
        user
        |> Ecto.Changeset.change(dek_rotation_locked_at: DateTime.utc_now())
        |> Repo.update()

      :ok
    end

    test "sync: join is refused mid-rotation", %{user: user, vault: vault} do
      assert {:error, %{reason: "rotation_in_progress"}} =
               subscribe_and_join(
                 user_socket(user),
                 EngramWeb.SyncChannel,
                 "sync:#{user.id}:#{vault.id}"
               )
    end

    test "crdt: still reports rotation_in_progress, not a lifecycle reason", %{
      user: user,
      vault: vault
    } do
      assert {:error, %{reason: "rotation_in_progress"}} = join_crdt(user, vault)
    end

    # Rotation must outrank lifecycle: it is transient and self-clears, and
    # the client backs off on it. Reporting account_suspended for a suspended
    # user mid-rotation would be correct too, but the ordering has to be
    # DECIDED rather than incidental — HTTP runs AccountDeleted (52) before
    # RotationLockCheck (54), so deleted wins there and must here.
    test "a DELETED account mid-rotation still reports account_deleted", %{
      user: user,
      vault: vault
    } do
      _deleted = mark!(user, :deleted_at)
      assert {:error, %{reason: "account_deleted"}} = join_crdt(user, vault)
    end
  end

  # Pricing v2 §G write half (#1433). Free's `api_write_enabled` is false, so
  # an API-key caller is 402'd on every non-GET REST route — and must not be
  # able to write through the socket instead. Reads stay open: the plug
  # exempts GET, and existing tests assert Free API keys can join and read.
  describe "API-key entitlements (#1433)" do
    setup %{user: user, vault: vault} do
      {:ok, _raw, api_key} = Engram.Accounts.create_api_key(user, "entitlement-gate")
      {:ok, note} = Engram.Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "hi"})
      {:ok, api_key: api_key, note: note}
    end

    # Free's `api_rps_cap` is 0 and `RequireApiRpsBudget` has no GET
    # exemption, so a Free key cannot make a single REST call. It must not be
    # able to open a socket and read the whole vault instead.
    test "a Free PAT cannot join at all", %{user: user, vault: vault, api_key: api_key} do
      assert {:error, %{reason: "api_access_not_available"}} =
               subscribe_and_join(
                 user_socket(user, api_key),
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )
    end

    test "a Free PAT cannot join sync: either", %{user: user, vault: vault, api_key: api_key} do
      assert {:error, %{reason: "api_access_not_available"}} =
               subscribe_and_join(
                 user_socket(user, api_key),
                 EngramWeb.SyncChannel,
                 "sync:#{user.id}:#{vault.id}"
               )
    end

    # The exemption must key on the api_key being non-nil, NOT on the assign
    # existing: `UserSocket.accept/4` ALWAYS sets :current_api_key (nil for
    # JWT), so a literal port of the plug's `not is_map_key/2` guard would
    # gate every web and plugin user on the platform.
    test "the SAME user on a JWT socket is unaffected", %{user: user, vault: vault} do
      assert {:ok, _, joined} = join_crdt(user, vault)
      Sandbox.allow(Repo, self(), joined.channel_pid)
    end

    test "a read-entitled PAT can join but still cannot write", %{
      user: user,
      vault: vault,
      api_key: api_key
    } do
      # rps only — `api_write_enabled` stays at the Free default (false).
      grant_api_read!(user)

      assert {:ok, _, joined} =
               subscribe_and_join(
                 user_socket(user, api_key),
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )

      Sandbox.allow(Repo, self(), joined.channel_pid)

      ref = push(joined, "crdt_create", %{"doc_id" => Ecto.UUID.generate(), "path" => "n.md"})
      assert_reply ref, :error, %{reason: "api_write_not_available"}
    end

    # `crdt_msg` is not "the write frame" — it carries the Yjs sync handshake
    # too. SyncStep1 (`<<0, 0, _>>`) is a pure state-vector REQUEST: it is how
    # a client asks for doc state. Blocking it means a read-entitled key joins
    # successfully and then receives nothing, forever — no room is ever
    # observed, so fan-out never fires either. The plug this mirrors opens
    # with `when m in ["GET", "HEAD"], do: conn` under "Reads are never
    # gated"; this is that clause.
    test "a write-blocked PAT can still send SyncStep1 and read", %{
      user: user,
      vault: vault,
      api_key: api_key,
      note: note
    } do
      grant_api_read!(user)

      {:ok, _, joined} =
        subscribe_and_join(
          user_socket(user, api_key),
          EngramWeb.CrdtChannel,
          "crdt:#{user.id}:#{vault.id}",
          %{"crdt_proto" => 2}
        )

      Sandbox.allow(Repo, self(), joined.channel_pid)

      # SyncStep1 for an empty local state = read the whole doc.
      step1 = Base.encode64(<<0, 0, 1, 0>>)
      ref = push(joined, "crdt_msg", %{"doc_id" => note.id, "b64" => step1})
      assert_reply ref, :ok, %{}
    end

    test "a JWT socket writes normally", %{user: user, vault: vault} do
      assert {:ok, _, joined} = join_crdt(user, vault)
      Sandbox.allow(Repo, self(), joined.channel_pid)

      id = Ecto.UUID.generate()
      ref = push(joined, "crdt_create", %{"doc_id" => id, "path" => "n.md"})
      assert_reply ref, :ok, %{doc_id: ^id}
    end

    test "a PAT with api_write_enabled granted can write", %{
      user: user,
      vault: vault,
      api_key: api_key
    } do
      grant_api_write!(user)

      assert {:ok, _, joined} =
               subscribe_and_join(
                 user_socket(user, api_key),
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )

      Sandbox.allow(Repo, self(), joined.channel_pid)

      id = Ecto.UUID.generate()
      ref = push(joined, "crdt_create", %{"doc_id" => id, "path" => "n2.md"})
      assert_reply ref, :ok, %{doc_id: ^id}
    end
  end

  describe "healthy accounts" do
    test "still join normally", %{user: user, vault: vault} do
      assert {:ok, _, joined} = join_crdt(user, vault)
      Sandbox.allow(Repo, self(), joined.channel_pid)
    end
  end
end
