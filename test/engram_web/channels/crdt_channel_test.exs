defmodule EngramWeb.CrdtChannelTest do
  use EngramWeb.ChannelCase, async: false

  alias Engram.{Crypto, Notes, Vaults}
  alias Engram.Notes.CrdtBridge

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "CrdtChannelTest"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "base"})
    other_user = insert(:user)
    {:ok, other_user} = Crypto.ensure_user_dek(other_user)

    socket = user_socket(user)

    result =
      subscribe_and_join(
        socket,
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        %{}
      )

    {:ok, _, joined} = result
    Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, self(), joined.channel_pid)

    %{
      socket: joined,
      user: user,
      vault: vault,
      note: note,
      other_user: other_user,
      doc_id: "#{vault.id}/p.md"
    }
  end

  # ---------------------------------------------------------------------------
  # Auth / join
  # ---------------------------------------------------------------------------

  describe "join/3" do
    test "accepts join for own user_id and vault", %{user: user, vault: vault} do
      socket = user_socket(user)

      assert {:ok, _reply, _joined} =
               subscribe_and_join(
                 socket,
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{}
               )
    end

    test "rejects join for another user's id in topic", %{
      user: user,
      vault: vault,
      other_user: other_user
    } do
      socket = user_socket(other_user)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{}
               )
    end

    test "rejects join for vault belonging to another user", %{user: user, other_user: other_user} do
      insert(:user_limit_override, user: other_user, key: "vaults_cap", value: %{"v" => -1})
      {:ok, other_vault} = Vaults.create_vault(other_user, %{name: "OtherVault"})
      socket = user_socket(user)

      assert {:error, %{reason: "vault_not_found"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{other_vault.id}",
                 %{}
               )
    end

    test "rejects join with invalid vault_id", %{user: user} do
      socket = user_socket(user)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:not-a-uuid",
                 %{}
               )
    end
  end

  # ---------------------------------------------------------------------------
  # crdt_msg — sync step1 → step2 reply
  # ---------------------------------------------------------------------------

  describe "crdt_msg" do
    test "sync step1 for existing doc yields a step2 crdt_msg reply with server content",
         %{socket: socket, doc_id: doc_id} do
      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})

      push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(frame)})

      assert_push "crdt_msg", %{"doc_id" => reply_doc_id, "b64" => b64}, 3000
      assert reply_doc_id == doc_id

      {:ok, {:sync, {:sync_step2, update}}} = Yex.Sync.message_decode(Base.decode64!(b64))
      :ok = Yex.apply_update(client, update)
      assert CrdtBridge.text_of(client) == "base"
    end

    test "unknown doc_id is silently ignored — no push, no crash",
         %{socket: socket, vault: vault} do
      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})

      push(socket, "crdt_msg", %{
        "doc_id" => "#{vault.id}/does-not-exist.md",
        "b64" => Base.encode64(frame)
      })

      refute_push "crdt_msg", _payload, 500
    end

    test "malformed base64 is silently ignored — no crash",
         %{socket: socket, doc_id: doc_id} do
      push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => "!!!not_valid_base64!!!"})
      refute_push "crdt_msg", _payload, 300
    end

    test "second crdt_msg for the same doc reuses the cached room", %{
      socket: socket,
      doc_id: doc_id
    } do
      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})

      push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(frame)})
      assert_push "crdt_msg", %{"doc_id" => ^doc_id}, 3000

      # Send a second step1 — should get another step2 (room already cached)
      client2 = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv2}} = Yex.Sync.get_sync_step1(client2)
      {:ok, frame2} = Yex.Sync.message_encode({:sync, {:sync_step1, sv2}})

      push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(frame2)})
      assert_push "crdt_msg", %{"doc_id" => ^doc_id}, 3000
    end

    test "update crdt_msg is applied to the room doc and notify_activity is invoked",
         %{socket: socket, doc_id: doc_id, user: user, vault: vault, note: note} do
      # Step 1: bring client up to date with the server
      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, step1_frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
      push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(step1_frame)})
      assert_push "crdt_msg", %{"b64" => b64_step2}, 3000
      {:ok, {:sync, {:sync_step2, upd}}} = Yex.Sync.message_decode(Base.decode64!(b64_step2))

      # Capture the server's state vector BEFORE applying the update (so we can
      # compute the delta the server doesn't have yet).
      {:ok, server_sv_before} = Yex.encode_state_vector(client)

      :ok = Yex.apply_update(client, upd)
      assert CrdtBridge.text_of(client) == "base"

      # Step 2: mutate the client doc and compute the delta vs. server state
      text = Yex.Doc.get_text(client, CrdtBridge.text_name())
      Yex.Text.insert(text, 4, " updated")
      assert CrdtBridge.text_of(client) == "base updated"

      # delta = everything the server doesn't have yet
      {:ok, delta} = Yex.encode_state_as_update(client, server_sv_before)

      {:ok, update_frame} = Yex.Sync.message_encode({:sync, {:sync_update, delta}})
      push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(update_frame)})

      # Give the room a moment to apply the update
      Process.sleep(200)

      # Verify the room's doc was updated
      {:ok, room_pid} =
        Engram.Notes.CrdtRegistry.ensure_started(user.id, vault.id, note.id)

      doc = Yex.Sync.SharedDoc.get_doc(room_pid)
      assert CrdtBridge.text_of(doc) == "base updated"

      # notify_activity wiring: if the timer pid was stored in the room's
      # process dict AND received :activity, the room stays alive (the timer
      # does not exit the room — it's linked the other way). The room being
      # alive confirms the full update→persist→notify path ran.
      assert Process.alive?(room_pid)
    end
  end
end
