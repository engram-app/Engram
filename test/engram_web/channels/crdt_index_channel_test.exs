defmodule EngramWeb.CrdtIndexChannelTest do
  @moduledoc """
  Channel plumbing for the per-vault index room (#1150).

  Index frames ride the EXISTING per-vault `crdt:` channel — no new transport,
  per the issue. The vault is implicit in the channel topic, so unlike
  `crdt_msg` these frames carry no `doc_id`: there is exactly one index room per
  connection, and inventing an addressing scheme for it would be a second way to
  name the same thing.

  Still inert: nothing writes to the index and nothing reads it back. These
  tests pin the transport so #1151 (checkpoint) and Engram-obsidian#362/#363
  (client adoption) have a proven wire to build on.
  """
  use EngramWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Crypto, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtIndexDoc, CrdtIndexRegistry}

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    on_exit(fn -> EngramWeb.RateLimiter.reset_buckets!() end)

    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "IndexChannelTest"})

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

  # A state-bearing index write: the shape #1151 will actually send.
  defp update_frame(path, note_id) do
    doc = CrdtBridge.new_doc()

    doc
    |> Yex.Doc.get_map(CrdtIndexDoc.map_name())
    |> Yex.Map.set(path, %{"note_id" => note_id})

    {:ok, update} = Yex.encode_state_as_update(doc)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_update, update}})
    Base.encode64(frame)
  end

  defp step1_frame(doc) do
    {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(doc)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
    Base.encode64(frame)
  end

  test "a step1 opens the vault's index room and answers with step2", ctx do
    client = CrdtBridge.new_doc()

    push(ctx.socket, "crdt_index_msg", %{"b64" => step1_frame(client)})

    assert_push "crdt_index_msg", %{"b64" => b64}, 3_000
    assert {:ok, {:sync, {:sync_step2, _diff}}} = Yex.Sync.message_decode(Base.decode64!(b64))

    assert is_pid(CrdtIndexRegistry.lookup(ctx.vault.id)),
           "the frame must have spun this vault's index room"
  end

  test "an index update from one client reaches another through the room", ctx do
    a = CrdtBridge.new_doc()

    a
    |> Yex.Doc.get_map(CrdtIndexDoc.map_name())
    |> Yex.Map.set("Notes/x.md", %{"note_id" => "n-x"})

    {:ok, update} = Yex.encode_state_as_update(a)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_update, update}})
    push(ctx.socket, "crdt_index_msg", %{"b64" => Base.encode64(frame)})

    # A second client handshakes and must converge on A's entry.
    b = CrdtBridge.new_doc()
    push(ctx.socket, "crdt_index_msg", %{"b64" => step1_frame(b)})

    assert_push "crdt_index_msg", %{"b64" => reply}, 3_000
    {:ok, {:sync, {:sync_step2, diff}}} = Yex.Sync.message_decode(Base.decode64!(reply))
    :ok = Yex.apply_update(b, diff)

    entry = b |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.fetch!("Notes/x.md")
    assert entry["note_id"] == "n-x"
  end

  # The index room is addressed by the channel topic, so it must never be
  # reachable as a note doc_id — otherwise a client could drive the index
  # through the note path and bypass note_in_vault? validation entirely.
  test "the index room is NOT reachable through crdt_msg", ctx do
    client = CrdtBridge.new_doc()

    ref =
      push(ctx.socket, "crdt_msg", %{
        "doc_id" => ctx.vault.id,
        "b64" => step1_frame(client)
      })

    assert_reply ref, :error, %{reason: "note_not_found", doc_id: _}
    assert CrdtIndexRegistry.lookup(ctx.vault.id) == nil
  end

  describe "rate lanes" do
    setup do
      prev = Application.get_env(:engram, :crdt_msg_rate_limit_override)
      Application.put_env(:engram, :crdt_msg_rate_limit_override, 1)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:engram, :crdt_msg_rate_limit_override)
          v -> Application.put_env(:engram, :crdt_msg_rate_limit_override, v)
        end
      end)

      :ok
    end

    # Assert on the REPLY of every frame, not on a push: with the edit budget
    # pinned to 1 the FIRST frame succeeds either way, so `assert_push` alone
    # would pass whichever lane these are billed to. The 2nd and 3rd are what
    # discriminate — as edits they would come back rate_limited.
    test "an index HANDSHAKE rides the handshake lane, not the edit budget", ctx do
      refs =
        for _ <- 1..3 do
          push(ctx.socket, "crdt_index_msg", %{"b64" => step1_frame(CrdtBridge.new_doc())})
        end

      for ref <- refs do
        assert_reply ref, :ok, %{}, 3_000
      end
    end

    # The other half, which an earlier version of this file claimed and never
    # tested: `frame_class_b64/1` lanes by wire prefix, so a state-bearing index
    # update is an EDIT and pays the edit budget exactly like a note update.
    #
    # Pinned deliberately rather than "fixed". Nothing writes the index until
    # #1151, and that is where the volume of these writes — and therefore
    # whether they belong on the handshake lane — is actually knowable. Moving
    # ALL index traffic onto the handshake lane just relocates the starvation
    # risk onto handshakes, which is the 2026-07-07 cross-file-overwrite shape.
    test "a state-bearing index UPDATE is billed to the edit lane", ctx do
      first = push(ctx.socket, "crdt_index_msg", %{"b64" => update_frame("Notes/a.md", "n-a")})
      assert_reply first, :ok, %{}, 3_000

      second = push(ctx.socket, "crdt_index_msg", %{"b64" => update_frame("Notes/b.md", "n-b")})
      assert_reply second, :error, %{reason: "rate_limited"}, 3_000
    end
  end

  # "Deliberately inert" describes the SERVER — nothing writes the index and
  # nothing reads it back. It is not a property of an endpoint any authenticated
  # client can push to: the index room has no persistence, no checkpoint timer
  # and therefore no drain or LRU bound, so its only limit is auto_exit when the
  # socket closes. Until #1151 the wire ships OFF.
  test "the wire is closed unless explicitly enabled", ctx do
    Application.put_env(:engram, :crdt_index_enabled, false)
    on_exit(fn -> Application.put_env(:engram, :crdt_index_enabled, true) end)

    ref = push(ctx.socket, "crdt_index_msg", %{"b64" => step1_frame(CrdtBridge.new_doc())})

    assert_reply ref, :error, %{reason: "index_disabled"}, 3_000
    assert CrdtIndexRegistry.lookup(ctx.vault.id) == nil, "a disabled wire must spin no room"
  end

  # A rejected index frame must come back as a reply, not vanish. Nothing reads
  # the index yet, so a silent drop here would be invisible until #1151 turned
  # it into a drift class.
  test "a malformed frame is rejected with a reply rather than dropped", ctx do
    ref = push(ctx.socket, "crdt_index_msg", %{"b64" => "!!!not base64!!!"})

    assert_reply ref, :error, %{reason: "index_frame_rejected"}, 3_000
  end
end
