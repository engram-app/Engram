defmodule Engram.Notes.CrdtDeliverTest do
  # async: false — registers rooms under :global (cluster-wide names) and
  # subscribes to Endpoint topics. Uses a BARE SharedDoc with no persistence
  # module, so there is no terminate-time DB flush (the :global-room sandbox
  # hazard documented in crdt_channel_test.exs is specifically CrdtPersistence's
  # unbind; a no-op room avoids it).
  use Engram.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Engram.{Notes, Repo}
  alias Engram.Notes.{CrdtBridge, CrdtDeliver, CrdtRegistry, Note}
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
    # These are PRIMARY-path tests: a real note row exists and deliver-out
    # applies its stored merge-lineage state. Rooms start EMPTY (production
    # rooms bind FROM the snapshot, so a plaintext-seeded bare room would put
    # the same text on a second lineage and double on the state apply).
    test "pushes a yjs frame to a live room's observers", %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "n.md", "content" => "base"})
      room = start_bare_room(note.id, "")
      SharedDoc.observe(room)

      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")

      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "n.md", note.id, "base")

      # The observing test process receives the frame produced by applying the
      # stored merge state onto the room's owned doc (deliver-out, gap 3).
      assert_receive {:yjs, frame, ^room}, 1000
      assert is_binary(frame)

      # And the discovery announce still fires for vault clients lacking the room.
      assert_receive %Phoenix.Socket.Broadcast{event: "crdt_doc_ready"}, 1000

      # The room's owned text converged to the stored content.
      doc = SharedDoc.get_doc(room)
      assert CrdtBridge.text_of(doc) == "base"
    end

    test "delivering a frontmatter change updates the live room's Y.Map, not just the body",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "n.md",
          "content" => "---\ntitle: Hi\n---\nnew body\n"
        })

      room = start_bare_room(note.id, "")

      :ok =
        CrdtDeliver.deliver_out(
          user.id,
          vault.id,
          "n.md",
          note.id,
          "---\ntitle: Hi\n---\nnew body\n"
        )

      doc = SharedDoc.get_doc(room)
      assert CrdtBridge.frontmatter_of(doc) == {["title"], %{"title" => "\"Hi\""}}
      assert CrdtBridge.body_of(doc) == "new body\n"
    end

    test "re-delivery of already-applied state is a no-op (still announces)",
         %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "n.md", "content" => "same"})
      room = start_bare_room(note.id, "")
      SharedDoc.observe(room)
      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")

      # First delivery converges the empty room onto the stored state.
      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "n.md", note.id, "same")
      assert_receive {:yjs, _frame, ^room}, 1000

      # Second delivery of the SAME state: apply_update is idempotent on
      # already-present ops → no new frame broadcast...
      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "n.md", note.id, "same")
      refute_receive {:yjs, _frame, ^room}, 200
      # ...but the announce always fires (twice total).
      assert_receive %Phoenix.Socket.Broadcast{event: "crdt_doc_ready"}, 1000
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
  # ---------------------------------------------------------------------------
  # State-load failure handling (post-merge review findings)
  #
  # A note that HAS CRDT state which fails to load (decrypt error, KMS outage)
  # must NOT degrade to the plaintext re-diff: re-encoding server-known content
  # on the room's lineage is the doubling corruption this module exists to
  # prevent. The push is skipped (loudly) and the announce still fires so
  # enrolled clients re-pull. Only a row with NO state at all (legacy/lazy
  # rows) may plaintext-ingest — there is no competing lineage to double.
  # ---------------------------------------------------------------------------

  describe "deliver_out/5 — state-load failure handling" do
    test "decrypt failure skips the room push (no plaintext re-encode) but still announces",
         %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "s.md", "content" => "orig"})

      # Corrupt the stored CRDT state so decrypt fails (ciphertext mismatch).
      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(n in Note, where: n.id == ^note.id),
            set: [crdt_state_ciphertext: <<0, 1, 2, 3>>]
          )
        end)

      room = start_bare_room(note.id, "orig")
      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")

      log =
        capture_log(fn ->
          assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "s.md", note.id, "orig updated")
          assert_receive %Phoenix.Socket.Broadcast{event: "crdt_doc_ready"}, 1000
        end)

      # The room was NOT mutated — a plaintext ingest would have re-encoded
      # "orig updated" on the room's lineage.
      doc = SharedDoc.get_doc(room)
      assert CrdtBridge.text_of(doc) == "orig"

      # The degradation is loud (Sentry captures Logger.error).
      assert log =~ "crdt deliver state load failed"
    end

    test "a row without CRDT state falls back to plaintext ingest (legacy row)",
         %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "l.md", "content" => "orig"})

      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(n in Note, where: n.id == ^note.id),
            set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
          )
        end)

      room = start_bare_room(note.id, "orig")

      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "l.md", note.id, "orig updated")

      doc = SharedDoc.get_doc(room)
      assert CrdtBridge.text_of(doc) == "orig updated"
    end

    test "EMPTY content on a stateless live room does NOT wipe the doc (folder-rename data-loss guard)",
         %{user: user, vault: vault} do
      # Regression for the folder-rename cascade: real_note_updates rows are a
      # meta-scan that never loads the content column, so note.content is
      # nil -> "" when broadcast_change reaches deliver_out. A live, unedited
      # room has no persisted CRDT state yet ({:ok, nil}); ingesting "" would
      # diff its body to empty. The cascade only re-paths, so the body must
      # survive. deliver_out must skip the plaintext push (announce still fires).
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "f.md", "content" => "child body"})

      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(n in Note, where: n.id == ^note.id),
            set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
          )
        end)

      room = start_bare_room(note.id, "child body")
      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")

      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "renamed/f.md", note.id, "")

      # Body preserved. The pre-fix code wiped this to "".
      doc = SharedDoc.get_doc(room)
      assert CrdtBridge.text_of(doc) == "child body"

      # The discovery announce still fires so clients re-pull the re-pathed doc.
      assert_receive %Phoenix.Socket.Broadcast{event: "crdt_doc_ready"}, 1000
    end
  end

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
