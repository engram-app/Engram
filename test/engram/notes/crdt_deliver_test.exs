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

      assert doc_id == note_id
    end

    test "announces even when no room is live (no crash, nested path content-type check)",
         %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")
      note_id = Ecto.UUID.generate()

      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "deep/nest/b.md", note_id, "x")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "crdt_doc_ready",
        payload: %{"doc_id" => doc_id}
      }

      assert doc_id == note_id
    end
  end

  describe "deliver_out — vault-channel fan-out (idle first-delivery)" do
    test "a REST write broadcasts note_yjs_update carrying the committed state on the sync topic",
         %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "fan.md",
          "content" => "# Fan\n\nfanout body"
        })

      # note_changed fires first (maps + confirms the id on the client); the
      # fan-out note_yjs_update follows on the SAME topic (ordered), carrying the
      # full committed Yjs state so an idle device converges room-free.
      assert_receive %Phoenix.Socket.Broadcast{event: "note_changed"}

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_yjs_update",
        payload: %{"note_id" => note_id, "b64" => b64}
      }

      assert note_id == note.id
      state = Base.decode64!(b64)
      assert byte_size(state) > 0
      {:ok, doc} = CrdtBridge.doc_from_state(state)
      text = doc |> Yex.Doc.get_text(CrdtBridge.text_name()) |> Yex.Text.to_string()
      assert text =~ "fanout body"
    end

    test "does NOT fan out for a non-.md note", %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      note_id = Ecto.UUID.generate()

      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "board.canvas", note_id, "x")

      refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 100
    end

    test "a state-less (legacy/lazy) row does NOT fan out note_yjs_update but still announces",
         %{user: user, vault: vault} do
      # load_merged_state returns {:ok, nil} for a row with no persisted CRDT
      # state; the `with {:ok, state} when is_binary(state)` guard skips the
      # broadcast (nothing to fan out), and the announce still lets enrolled
      # clients re-pull. Locks the "never crash / graceful skip" fallback.
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "leg.md", "content" => "x"})

      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(n in Note, where: n.id == ^note.id),
            set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
          )
        end)

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")

      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "leg.md", note.id, "x")

      refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 200
      assert_receive %Phoenix.Socket.Broadcast{event: "crdt_doc_ready"}, 1000
    end

    test "a doc_from_state failure still broadcasts the state with head: nil (no raise)",
         %{user: user, vault: vault} do
      # Deep-corruption fallback: load_merged_state returns a binary that
      # doc_from_state cannot parse (a shouldn't-happen state). fanout_idle must
      # not raise the caller — it broadcasts the state with head: nil, and the
      # client, unable to advance its watermark, re-pulls via coldReceive.
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "g.md", "content" => "x"})

      {:ok, {ct, nonce}} = Engram.Crypto.encrypt_crdt_state("not a yjs update", user, note.id)

      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(n in Note, where: n.id == ^note.id),
            set: [crdt_state_ciphertext: ct, crdt_state_nonce: nonce]
          )
        end)

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "g.md", note.id, "x")

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "note_yjs_update",
                       payload: %{"note_id" => note_id, "head" => head}
                     },
                     1000

      assert note_id == note.id
      assert head == nil
    end
  end

  describe "announce_ready/4 — discovery-only (checkpoint path)" do
    test "announces crdt_doc_ready for a .md note without touching any room",
         %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")
      note_id = Ecto.UUID.generate()

      assert :ok = CrdtDeliver.announce_ready(user.id, vault.id, "a.md", note_id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "crdt_doc_ready",
        payload: %{"doc_id" => ^note_id}
      }
    end

    test "does NOT announce for a non-.md note", %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")
      note_id = Ecto.UUID.generate()

      assert :ok = CrdtDeliver.announce_ready(user.id, vault.id, "board.canvas", note_id)

      refute_receive %Phoenix.Socket.Broadcast{event: "crdt_doc_ready"}
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

    test "does NOT fan out the redundant note_yjs_update when a live room exists",
         %{user: user, vault: vault} do
      # A live room's own update_v1 fans the delta out over the SAME per-vault
      # sync topic, so the full-state fanout_idle is gated off — else the same
      # write re-broadcasts (and re-decrypts) the note. (The bare test room has no
      # persistence, so update_v1 doesn't fire here; the point is only that the
      # redundant fanout_idle does not.)
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "body"})
      _room = start_bare_room(note.id, "")

      # Subscribe AFTER upsert so the upsert's own (room-less) fan-out is not
      # counted — we only measure this direct deliver_out, which has a live room.
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "r.md", note.id, "body")

      refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 200
    end
  end

  describe "upsert_note wiring" do
    test "an upsert announces crdt_doc_ready (CRDT is the only sync path)",
         %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")

      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "w.md",
          "content" => "hi",
          "mtime" => 1.0
        })

      assert_receive %Phoenix.Socket.Broadcast{
        event: "crdt_doc_ready",
        payload: %{"doc_id" => doc_id}
      }

      assert doc_id == note.id
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
    test "decrypt failure QUARANTINES the room (killed, no unbind) and still announces",
         %{user: user, vault: vault} do
      # Semantic flip from "skip the push, leave the room alive": a room we
      # could not converge is a poisoned cache — it serves its stale doc to
      # every client the announce triggers to re-pull, blocking delivery of
      # the committed write, and (pre Phase-0 union) its next checkpoint
      # reverted the row. Kill it brutally (no unbind checkpoint — never
      # persist a doc we could not converge); the next join re-binds a fresh
      # room hydrated from the row, which holds the merged truth.
      # The bare room is start_link'ed to this test process; the quarantine
      # kill would propagate over the link, so trap exits.
      Process.flag(:trap_exit, true)
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "s.md", "content" => "orig"})

      # Corrupt the stored CRDT state so decrypt fails (ciphertext mismatch).
      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(n in Note, where: n.id == ^note.id),
            set: [crdt_state_ciphertext: <<0, 1, 2, 3>>]
          )
        end)

      room = start_bare_room(note.id, "orig")
      ref = Process.monitor(room)
      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")

      log =
        capture_log(fn ->
          assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "s.md", note.id, "orig updated")
          assert_receive %Phoenix.Socket.Broadcast{event: "crdt_doc_ready"}, 1000
        end)

      # The poisoned room must be gone — killed, not gracefully stopped
      # (a graceful stop would run unbind → checkpoint of the stale doc).
      assert_receive {:DOWN, ^ref, :process, ^room, :killed}, 1000
      assert CrdtRegistry.lookup(note.id) == nil

      # The degradation is loud (Sentry captures Logger.error).
      assert log =~ "crdt deliver state load failed"
    end

    test "a STALE apply-failed message in the caller's mailbox does not quarantine a healthy room (#953-review F4)",
         %{user: user, vault: vault} do
      # A timed-out update_doc call can deliver its failure signal AFTER the
      # receive returned, leaving it in this (long-lived, e.g. channel)
      # process's mailbox. The signal is now ref-tagged per call, so a stale
      # message from an earlier call can never match — the next deliver for
      # the same note must NOT consume it and kill a healthy room.
      Process.flag(:trap_exit, true)
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "h.md", "content" => "orig"})
      room = start_bare_room(note.id, "")
      ref = Process.monitor(room)

      # Plant the legacy-shaped stray signal (what a timed-out earlier call
      # would have left behind pre-fix).
      send(self(), {:crdt_deliver_apply_failed, note.id})

      assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "h.md", note.id, "orig")

      refute_receive {:DOWN, ^ref, :process, ^room, :killed}, 300
      assert CrdtRegistry.lookup(note.id) == room
    end

    test "apply_update failure QUARANTINES the room (killed) — no stale cache survives",
         %{user: user, vault: vault} do
      Process.flag(:trap_exit, true)
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "s2.md", "content" => "orig"})

      # Store VALIDLY-ENCRYPTED garbage: decrypt succeeds, Yex.apply_update fails.
      {:ok, {ct, nonce}} = Engram.Crypto.encrypt_crdt_state("not a yjs update", user, note.id)

      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(n in Note, where: n.id == ^note.id),
            set: [crdt_state_ciphertext: ct, crdt_state_nonce: nonce]
          )
        end)

      room = start_bare_room(note.id, "orig")
      ref = Process.monitor(room)

      capture_log(fn ->
        assert :ok = CrdtDeliver.deliver_out(user.id, vault.id, "s2.md", note.id, "orig updated")
      end)

      assert_receive {:DOWN, ^ref, :process, ^room, :killed}, 1000
      assert CrdtRegistry.lookup(note.id) == nil
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
