defmodule Engram.Notes.CrdtDeliverTest do
  # async: false — registers rooms under :global (cluster-wide names) and
  # subscribes to Endpoint topics. Uses a BARE SharedDoc with no persistence
  # module, so there is no terminate-time DB flush (the :global-room sandbox
  # hazard documented in crdt_channel_test.exs is specifically CrdtPersistence's
  # unbind; a no-op room avoids it).
  use Engram.DataCase, async: false

  alias Engram.Notes.{CrdtBridge, CrdtDeliver, CrdtRegistry}
  alias Yex.Sync.SharedDoc

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "DeliverTest"})
    %{user: user, vault: vault}
  end

  describe "deliver_out/5 — announce" do
    test "broadcasts crdt_doc_ready to the vault crdt topic", %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")
      note_id = Ecto.UUID.generate()

      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "a.md", note_id, "# A")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "crdt_doc_ready",
        payload: %{"doc_id" => doc_id}
      }

      assert doc_id == "#{vault.id}/a.md"
    end

    test "announces even when no room is live (no crash, vault-prefixed nested path)",
         %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")
      note_id = Ecto.UUID.generate()

      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "deep/nest/b.md", note_id, "x")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "crdt_doc_ready",
        payload: %{"doc_id" => doc_id}
      }

      assert doc_id == "#{vault.id}/deep/nest/b.md"
    end
  end

  describe "deliver_out/5 — live-room frame push" do
    test "pushes a yjs frame to a live room's observers", %{user: user, vault: vault} do
      note_id = Ecto.UUID.generate()
      room = start_bare_room(note_id, "base")
      SharedDoc.observe(room)

      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")

      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "n.md", note_id, "base updated")

      # The observing test process receives the diff frame produced by applying
      # the incoming plaintext onto the room's owned doc (deliver-out, gap 3).
      assert_receive {:yjs, frame, ^room}, 1000
      assert is_binary(frame)

      # And the discovery announce still fires for vault clients lacking the room.
      assert_receive %Phoenix.Socket.Broadcast{event: "crdt_doc_ready"}, 1000

      # The room's owned text converged to the incoming plaintext.
      doc = SharedDoc.get_doc(room)
      assert Engram.Notes.CrdtBridge.text_of(doc) == "base updated"
    end

    test "delivering a frontmatter change updates the live room's Y.Map, not just the body",
         %{user: user, vault: vault} do
      note_id = Ecto.UUID.generate()
      room = start_bare_room(note_id, "old body\n")

      :ok =
        CrdtDeliver.deliver_out(
          user.id,
          vault.id,
          "n.md",
          note_id,
          "---\ntitle: Hi\n---\nnew body\n"
        )

      doc = SharedDoc.get_doc(room)
      assert CrdtBridge.frontmatter_of(doc) == {["title"], %{"title" => "\"Hi\""}}
      assert CrdtBridge.body_of(doc) == "new body\n"
    end

    test "no-op when incoming equals the room's current text (still announces)",
         %{user: user, vault: vault} do
      note_id = Ecto.UUID.generate()
      room = start_bare_room(note_id, "same")
      SharedDoc.observe(room)
      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")

      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "n.md", note_id, "same")

      # diff_into_text is a no-op on equality → no frame broadcast...
      refute_receive {:yjs, _frame, ^room}, 200
      # ...but the announce always fires.
      assert_receive %Phoenix.Socket.Broadcast{event: "crdt_doc_ready"}, 1000
    end
  end

  describe "upsert_note wiring" do
    test "an upsert announces crdt_doc_ready (CRDT is the only sync path)",
         %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")

      {:ok, _note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "w.md",
          "content" => "hi",
          "mtime" => 1.0
        })

      assert_receive %Phoenix.Socket.Broadcast{
        event: "crdt_doc_ready",
        payload: %{"doc_id" => doc_id}
      }

      assert doc_id == "#{vault.id}/w.md"
    end
  end

  # A SharedDoc with NO persistence module (no bind/unbind), registered under the
  # same :global name CrdtRegistry uses, so CrdtRegistry.lookup/1 finds it.
  # auto_exit: false keeps it alive across observer churn within the test.
  defp start_bare_room(note_id, seed_text) do
    {:ok, room} =
      SharedDoc.start_link(
        [
          doc_name: note_id,
          doc_option: %Yex.Doc.Options{offset_kind: :utf16},
          auto_exit: false
        ],
        name: CrdtRegistry.global_name(note_id)
      )

    on_exit(fn ->
      # The room can terminate on its own between the alive? check and the
      # stop (SharedDoc auto-exits when its last observer leaves), so a bare
      # GenServer.stop races and exits with :noproc. Tolerate an already-dead
      # process rather than crash the on_exit callback.
      try do
        if Process.alive?(room), do: GenServer.stop(room)
      catch
        :exit, _ -> :ok
      end
    end)

    if seed_text do
      SharedDoc.update_doc(room, fn doc ->
        Yex.Text.insert(Yex.Doc.get_text(doc, Engram.Notes.CrdtBridge.text_name()), 0, seed_text)
      end)
    end

    room
  end
end
