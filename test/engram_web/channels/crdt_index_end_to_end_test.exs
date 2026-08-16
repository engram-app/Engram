defmodule EngramWeb.CrdtIndexEndToEndTest do
  @moduledoc """
  The whole identity loop, driven by a CLIENT over the real channel.

  Every other test of this subsystem calls the server's own functions:
  `Identity.claim/3`, `CrdtIndexPersistence.bind/3`, `ProjectVaultIndex.perform/1`.
  That leaves the thing the design actually promises unexercised — a client
  writes `filemeta_v0`, and the `notes` rows follow.

  It matters more here than it usually would. Nothing in `lib/` writes the index
  in production yet (Engram-obsidian#362 is the client adoption), so the whole
  feature has shipped through green CI — e2e suites included — twice while
  carrying critical defects, simply because no test path reached it. Reviews
  caught those; reviews are not a substitute for execution.

  Nothing here is a mock: a real `UserSocket`, the real `CrdtChannel`, real
  `sync_update` frames encoded by y_ex, the real room, real Postgres, real
  encryption, and the real projection worker.

      client frame -> channel -> room -> tail log -> checkpoint -> snapshot
        -> ProjectVaultIndex -> notes.path_* actually moves
  """
  use EngramWeb.ChannelCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtIndexDoc, CrdtIndexRegistry, VaultIndexUpdateLog}
  alias Engram.Workers.ProjectVaultIndex
  alias Yex.Sync.SharedDoc

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    on_exit(fn -> EngramWeb.RateLimiter.reset_buckets!() end)

    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "IndexE2E"})

    {:ok, _, socket} =
      subscribe_and_join(
        user_socket(user),
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        %{"crdt_proto" => 2}
      )

    Sandbox.allow(Repo, self(), socket.channel_pid)

    %{socket: socket, user: user, vault: vault}
  end

  # Exactly what a client sends: a Yjs sync_update carrying one filemeta_v0 entry.
  defp client_claim(path, note_id) do
    doc = CrdtBridge.new_doc()

    doc
    |> Yex.Doc.get_map(CrdtIndexDoc.map_name())
    |> Yex.Map.set(path, %{"note_id" => note_id})

    {:ok, update} = Yex.encode_state_as_update(doc)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_update, update}})
    Base.encode64(frame)
  end

  defp note(ctx, path) do
    {:ok, note} = Notes.upsert_note(ctx.user, ctx.vault, %{"path" => path, "content" => "x"})
    note
  end

  defp path_of(ctx, note_id) do
    case Notes.get_note_by_id(ctx.user, ctx.vault, note_id) do
      {:ok, %{path: path}} -> path
      _ -> nil
    end
  end

  defp tail_count(ctx) do
    {:ok, n} =
      Repo.with_tenant(ctx.user.id, fn ->
        Repo.aggregate(from(l in VaultIndexUpdateLog, where: l.vault_id == ^ctx.vault.id), :count)
      end)

    n
  end

  # The room is started by the channel, so the test process is not an observer.
  # Wait for the write to be DURABLE rather than for a message we cannot see —
  # `handle_update_v1` is asynchronous, so a frame being accepted says nothing
  # about the tail yet.
  defp await_tail(ctx, n) do
    Enum.reduce_while(1..150, :timeout, fn _, _ ->
      if tail_count(ctx) >= n do
        {:halt, :ok}
      else
        Process.sleep(20)
        {:cont, :timeout}
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("client claim never reached the tail log")
    end
  end

  defp stop_room_and_wait(ctx) do
    case :global.whereis_name({:crdt_index, ctx.vault.id}) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        # The channel is the room's observer, so closing it is what drops the
        # last observer and triggers auto_exit -> terminate -> unbind.
        #
        # Unlink first: subscribe_and_join LINKS the channel to the test
        # process, so its shutdown propagates and kills the test itself.
        Process.unlink(ctx.socket.channel_pid)
        :ok = close(ctx.socket)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
        :ok

      :undefined ->
        :ok
    end
  end

  defp run_projection(ctx) do
    ProjectVaultIndex.perform(%Oban.Job{
      args: %{"user_id" => ctx.user.id, "vault_id" => ctx.vault.id}
    })
  end

  describe "a client claim moves the row" do
    test "client writes filemeta_v0 over the channel and the note actually moves", ctx do
      n = note(ctx, "Old/e2e.md")

      push(ctx.socket, "crdt_index_msg", %{"b64" => client_claim("New/e2e.md", n.id)})
      :ok = await_tail(ctx, 1)

      # Graceful room exit -> checkpoint -> snapshot, and the projection enqueue.
      :ok = stop_room_and_wait(ctx)

      assert :ok = run_projection(ctx)

      assert path_of(ctx, n.id) == "New/e2e.md",
             "a claim written by a real client over the real channel did not move the row"
    end

    # The claim is durable in the TAIL before any checkpoint. This is the path
    # that had no coverage at all before #1391: kill the room without a graceful
    # exit and the claim must still land.
    test "a claim survives a room killed before it ever checkpoints", ctx do
      n = note(ctx, "Old/killed.md")

      push(ctx.socket, "crdt_index_msg", %{"b64" => client_claim("New/killed.md", n.id)})
      :ok = await_tail(ctx, 1)

      # Kill the ROOM outright: no terminate/2, so no unbind and no snapshot.
      pid = :global.whereis_name({:crdt_index, ctx.vault.id})
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

      # A fresh room binds from snapshot + tail. Projection reads the persisted
      # snapshot, so the claim has to survive all the way through a checkpoint.
      {:ok, revived} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
      ref2 = Process.monitor(revived)
      :ok = SharedDoc.unobserve(revived)
      assert_receive {:DOWN, ^ref2, :process, ^revived, _}, 5_000

      assert :ok = run_projection(ctx)

      assert path_of(ctx, n.id) == "New/killed.md",
             "a claim that only ever existed in the tail was lost across a room kill"
    end

    # Two claims, one checkpoint. Pins that the tail replays in order and that
    # the checkpoint folds ALL of it in, not just the last one.
    test "several client claims all survive one checkpoint", ctx do
      a = note(ctx, "Old/a.md")
      b = note(ctx, "Old/b.md")

      push(ctx.socket, "crdt_index_msg", %{"b64" => client_claim("New/a.md", a.id)})
      push(ctx.socket, "crdt_index_msg", %{"b64" => client_claim("New/b.md", b.id)})
      :ok = await_tail(ctx, 2)

      :ok = stop_room_and_wait(ctx)

      assert :ok = run_projection(ctx)

      assert path_of(ctx, a.id) == "New/a.md"
      assert path_of(ctx, b.id) == "New/b.md"

      assert tail_count(ctx) == 0,
             "the checkpoint folded the claims in but left the tail behind"
    end
  end
end
