defmodule EngramWeb.CrdtChannelTest do
  use EngramWeb.ChannelCase, async: false
  import Ecto.Query, only: [from: 2]

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Attachments, Crypto, Fixtures, Notes, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtRegistry, CrdtUpdateLog}
  alias Engram.Repo
  alias Yex.Sync.SharedDoc

  setup do
    EngramWeb.RateLimiter.reset_buckets!()

    on_exit(fn ->
      EngramWeb.RateLimiter.reset_buckets!()
    end)

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
        %{"crdt_proto" => 2}
      )

    {:ok, _, joined} = result
    Sandbox.allow(Repo, self(), joined.channel_pid)

    %{
      socket: joined,
      user: user,
      vault: vault,
      note: note,
      other_user: other_user,
      doc_id: note.id
    }
  end

  # ---------------------------------------------------------------------------
  # Socket-native frames: create / delete / catchup
  # ---------------------------------------------------------------------------

  describe "crdt_create" do
    test "creates a bare row for a client-minted id", %{socket: socket, user: user, vault: vault} do
      id = Ecto.UUID.generate()
      ref = push(socket, "crdt_create", %{"doc_id" => id, "path" => "Notes/n.md"})
      assert_reply ref, :ok, %{doc_id: ^id}
      assert Notes.note_in_vault?(user, vault.id, id)
    end

    test "id live at a different FREE path relocates the note (Phase E2 rename-as-move)", %{
      socket: socket,
      user: user,
      vault: vault,
      note: note
    } do
      ref = push(socket, "crdt_create", %{"doc_id" => note.id, "path" => "Notes/other.md"})
      assert_reply ref, :ok, %{doc_id: got}
      assert got == note.id
      {:ok, moved} = Notes.get_note(user, vault, "Notes/other.md")
      assert moved.id == note.id
    end

    test "id live at a different path with an OCCUPIED target replies id_conflict", %{
      socket: socket,
      user: user,
      vault: vault,
      note: note
    } do
      {:ok, _other} =
        Notes.upsert_note(user, vault, %{"path" => "Notes/occupied.md", "content" => "x"})

      ref = push(socket, "crdt_create", %{"doc_id" => note.id, "path" => "Notes/occupied.md"})
      assert_reply ref, :error, %{reason: "id_conflict", doc_id: got}
      assert got == note.id
    end

    test "nil path replies bad_path without crashing the channel", %{socket: socket} do
      ref = push(socket, "crdt_create", %{"doc_id" => Ecto.UUID.generate(), "path" => nil})
      assert_reply ref, :error, %{reason: "bad_path"}
      ref2 = push(socket, "crdt_catchup_since", %{})
      assert_reply ref2, :ok, %{changes: _}
    end

    test "non-UUID doc_id replies bad_doc_id without crashing the channel", %{socket: socket} do
      ref = push(socket, "crdt_create", %{"doc_id" => "not-a-uuid", "path" => "Notes/x.md"})
      assert_reply ref, :error, %{reason: "bad_doc_id"}
      ref2 = push(socket, "crdt_catchup_since", %{})
      assert_reply ref2, :ok, %{changes: _}
    end

    test "same-path resurrect within the delete window replies recently_deleted (delete-wins)", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "Notes/dw.md", "content" => "keep"})

      :ok = Notes.delete_note_by_id(user, vault, note.id)

      ref = push(socket, "crdt_create", %{"doc_id" => note.id, "path" => "Notes/dw.md"})
      assert_reply ref, :error, %{reason: "recently_deleted"}
      refute Notes.note_in_vault?(user, vault.id, note.id)
    end

    test "a frame missing a required key replies bad_frame without crashing the channel", %{
      socket: socket
    } do
      # crdt_create with no "path" key matches no handle_in clause but the
      # channel-wide fallback; the channel must survive.
      ref = push(socket, "crdt_create", %{"doc_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, %{reason: "bad_frame"}

      ref2 = push(socket, "crdt_catchup_since", %{})
      assert_reply ref2, :ok, %{changes: _}
    end
  end

  describe "crdt_delete" do
    test "soft-deletes a note by id and is idempotent", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Notes/del.md", "content" => "x"})
      ref = push(socket, "crdt_delete", %{"doc_id" => note.id})
      assert_reply ref, :ok, %{doc_id: _}
      refute Notes.note_in_vault?(user, vault.id, note.id)

      ref2 = push(socket, "crdt_delete", %{"doc_id" => note.id})
      assert_reply ref2, :ok, %{doc_id: _}
    end

    test "delete broadcast carries the deleting socket's device_id (#970)", %{
      user: user,
      vault: vault
    } do
      device_id = Ecto.UUID.generate()

      {:ok, _, device_socket} =
        subscribe_and_join(
          socket(EngramWeb.UserSocket, "user_#{user.id}", %{
            current_user: user,
            current_api_key: nil,
            device_id: device_id
          }),
          EngramWeb.CrdtChannel,
          "crdt:#{user.id}:#{vault.id}",
          %{"crdt_proto" => 2}
        )

      Sandbox.allow(Repo, self(), device_socket.channel_pid)

      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Notes/dev.md", "content" => "x"})

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      ref = push(device_socket, "crdt_delete", %{"doc_id" => note.id})
      assert_reply ref, :ok, %{doc_id: _}

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "delete", "id" => id} = payload
      }

      assert id == note.id
      assert payload["device_id"] == device_id
    end
  end

  # Single-path catch-up (Phase B): replay the seq-ordered op-log over the
  # socket. Each op carries FULL content (not an SV-diff), so it is causally
  # complete and can never pend — the e2e test_85 deaf-note fix.
  describe "crdt_catchup_since" do
    test "replays seq-ordered notes with full content after cursor 0", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "Notes/a.md", "content" => "aaa"})
      {:ok, n2} = Notes.upsert_note(user, vault, %{"path" => "Notes/b.md", "content" => "bbb"})

      ref = push(socket, "crdt_catchup_since", %{"cursor_seq" => 0})
      assert_reply ref, :ok, %{changes: changes, has_more: has_more, next_seq: _next}

      a = Enum.find(changes, &(&1.id == n1.id))
      b = Enum.find(changes, &(&1.id == n2.id))
      assert a.type == :note
      assert a.path == "Notes/a.md" and a.content == "aaa" and a.deleted == false
      assert b.path == "Notes/b.md" and b.content == "bbb"
      assert is_integer(a.seq)

      # Seq-ordered ascending (deterministic apply order).
      seqs = Enum.map(changes, & &1.seq)
      assert seqs == Enum.sort(seqs)
      assert has_more == false
    end

    test "includes tombstones so deletes replay as ops", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      {:ok, n} = Notes.upsert_note(user, vault, %{"path" => "Notes/del.md", "content" => "x"})
      :ok = Notes.delete_note(user, vault, "Notes/del.md")

      ref = push(socket, "crdt_catchup_since", %{"cursor_seq" => 0})
      assert_reply ref, :ok, %{changes: changes}

      tomb = Enum.find(changes, &(&1.id == n.id))
      assert tomb != nil and tomb.deleted == true
    end

    test "only returns changes with seq > cursor", %{socket: socket, user: user, vault: vault} do
      {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "Notes/c1.md", "content" => "1"})
      {:ok, n2} = Notes.upsert_note(user, vault, %{"path" => "Notes/c2.md", "content" => "2"})

      # Cursor at n1's seq → n1 excluded, n2 included.
      ref = push(socket, "crdt_catchup_since", %{"cursor_seq" => n1.seq})
      assert_reply ref, :ok, %{changes: changes}
      ids = Enum.map(changes, & &1.id)
      refute n1.id in ids
      assert n2.id in ids
    end

    test "a non-integer cursor_seq replies bad_cursor instead of crashing the channel", %{
      socket: socket
    } do
      ref = push(socket, "crdt_catchup_since", %{"cursor_seq" => "nope"})
      assert_reply ref, :error, %{reason: "bad_cursor"}

      ref2 = push(socket, "crdt_catchup_since", %{"cursor_seq" => 0})
      assert_reply ref2, :ok, %{changes: _}
    end

    test "the seq feed merges attachments alongside notes in seq order", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      {:ok, n} =
        Notes.upsert_note(user, vault, %{"path" => "Notes/n.md", "content" => "note-body"})

      {:ok, att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "img.png",
          "content_base64" => Base.encode64("attachment-bytes"),
          "mime_type" => "image/png"
        })

      ref = push(socket, "crdt_catchup_since", %{"cursor_seq" => 0})
      assert_reply ref, :ok, %{changes: changes}

      note_row = Enum.find(changes, &(&1.id == n.id))
      att_row = Enum.find(changes, &(&1.id == att.id))

      assert note_row.type == :note
      assert att_row != nil and att_row.type == :attachment and att_row.path == "img.png"

      # Merged feed is a single seq-ordered stream (seq is vault-global, so a
      # note and an attachment never collide → an integer cursor paginates both).
      seqs = Enum.map(changes, & &1.seq)
      assert seqs == Enum.sort(seqs)
    end
  end

  # ---------------------------------------------------------------------------
  # crdt_create_batch — bulk genesis-with-content (Task 1, single-push-path)
  # ---------------------------------------------------------------------------

  describe "crdt_create_batch" do
    test "creates every note with content and allocates seqs", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      id1 = Ecto.UUID.generate()
      id2 = Ecto.UUID.generate()

      creates = [
        %{"doc_id" => id1, "path" => "A.md", "b64" => frame_for_content("alpha")},
        %{"doc_id" => id2, "path" => "B.md", "b64" => frame_for_content("beta")}
      ]

      ref = push(socket, "crdt_create_batch", %{"creates" => creates})
      assert_reply ref, :ok, %{results: results}
      assert Enum.all?(results, &(&1.status == "ok"))
      assert Enum.map(results, & &1.doc_id) |> Enum.sort() == Enum.sort([id1, id2])

      assert_note_content_eventually(user, vault, id1, "alpha")
      assert_note_content_eventually(user, vault, id2, "beta")
    end

    test "materializes content SYNCHRONOUSLY so the seq feed carries it immediately", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # A genesis create must persist notes.content the instant the reply lands,
      # NOT ~250ms later via the room's checkpoint timer. The seq-ordered catch-up
      # feed (the single convergence path) reads durable notes.content, so a
      # seq-replay racing the timer would read content="" and 0-byte-materialize
      # the note (e2e test_03/09/10/86 under load). NO wait_until here — that is
      # the whole point: the content is already there.
      id = Ecto.UUID.generate()
      creates = [%{"doc_id" => id, "path" => "Sync.md", "b64" => frame_for_content("sync-body")}]

      ref = push(socket, "crdt_create_batch", %{"creates" => creates})
      assert_reply ref, :ok, %{results: [%{status: "ok"}]}

      assert {:ok, note} = Notes.get_note_by_id(user, vault, id)
      assert note.content == "sync-body"
    end

    test "a duplicate create for the same note does not double the body", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # A create is idempotent: a second crdt_create_batch for the SAME note (a
      # client retry, or a create racing a live-seed of the same note) must NOT
      # concatenate a second copy of the body. Each frame_for_content mints a
      # FRESH Y.Doc, so the two frames carry identical text on DIVERGENT lineages
      # — re-applying the second onto the first's room doc makes Yjs append it
      # (#846; e2e test_82 saw a deterministic 19B "original" -> 38B doubled,
      # which then blocked the peer's real edit from converging). The genesis
      # frame seeds only an EMPTY note, so the second create is a no-op.
      id = Ecto.UUID.generate()

      create = %{"doc_id" => id, "path" => "Dup.md", "b64" => frame_for_content("dup-body")}
      ref1 = push(socket, "crdt_create_batch", %{"creates" => [create]})
      assert_reply ref1, :ok, %{results: [%{status: "ok"}]}

      # Fresh frame => a different lineage carrying the same text.
      redo = %{"doc_id" => id, "path" => "Dup.md", "b64" => frame_for_content("dup-body")}
      ref2 = push(socket, "crdt_create_batch", %{"creates" => [redo]})
      assert_reply ref2, :ok, %{results: [%{status: "ok"}]}

      assert {:ok, note} = Notes.get_note_by_id(user, vault, id)
      assert note.content == "dup-body"
    end

    test "one bad entry does not fail the batch", %{socket: socket, user: user, vault: vault} do
      good = Ecto.UUID.generate()

      creates = [
        %{"doc_id" => good, "path" => "Good.md", "b64" => frame_for_content("ok")},
        %{"doc_id" => "not-a-uuid", "path" => "Bad.md", "b64" => frame_for_content("x")}
      ]

      ref = push(socket, "crdt_create_batch", %{"creates" => creates})
      assert_reply ref, :ok, %{results: results}
      by_id = Map.new(results, &{&1.doc_id, &1.status})
      assert by_id[good] == "ok"
      assert by_id["not-a-uuid"] == "error"

      assert_note_content_eventually(user, vault, good, "ok")
    end

    test "rejects an oversized creates list", %{socket: socket} do
      creates =
        for _ <- 1..101,
            do: %{
              "doc_id" => Ecto.UUID.generate(),
              "path" => "X.md",
              "b64" => frame_for_content("x")
            }

      ref = push(socket, "crdt_create_batch", %{"creates" => creates})
      assert_reply ref, :error, %{reason: "too_many_creates", max: 100}
    end
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
                 %{"crdt_proto" => 2}
               )
    end

    test "rejects join when crdt_proto is below server schema version", %{
      user: user,
      vault: vault
    } do
      socket = user_socket(user)

      assert {:error, %{reason: "crdt_proto_too_old", min: 2}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 1}
               )
    end

    test "rejects join when crdt_proto is absent (defaults to 1)", %{
      user: user,
      vault: vault
    } do
      socket = user_socket(user)

      assert {:error, %{reason: "crdt_proto_too_old", min: 2}} =
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
                 %{"crdt_proto" => 2}
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
                 %{"crdt_proto" => 2}
               )
    end

    test "rejects join with invalid vault_id", %{user: user} do
      socket = user_socket(user)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:not-a-uuid",
                 %{"crdt_proto" => 2}
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

    test "#1087: genesis row + later REST content write → STEP2 hydrates the content (no empty room)",
         %{socket: socket, user: user, vault: vault} do
      # The e2e test_38/43 shape, in-process: crdt_create makes a bare genesis
      # row (empty content, EMPTY-doc snapshot); a REST write then lands
      # content while NO room is live. The next STEP1 must open a room whose
      # bind seeds from the row — pre-fix, from_snapshot? (the empty genesis
      # snapshot) defeated the seed and STEP2 served empty forever.
      genesis_id = Ecto.UUID.generate()
      ref = push(socket, "crdt_create", %{"doc_id" => genesis_id, "path" => "Notes/g.md"})
      assert_reply ref, :ok, %{doc_id: created_id}

      # Kill the genesis room so the REST write below lands with no live room
      # (deliver_out's live-room push must not be what heals this).
      Engram.Notes.CrdtRegistry.terminate_room(created_id)

      # REST content write; wipe the state columns back to the EMPTY genesis
      # snapshot shape (simulating the merge-never-reached-state window).
      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{"path" => "Notes/g.md", "content" => "late body"})

      {:ok, empty_state} = Yex.encode_state_as_update(CrdtBridge.new_doc())
      {:ok, {ct, nonce}} = Engram.Crypto.encrypt_crdt_state(empty_state, user, created_id)

      {:ok, _} =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.update_all(
            from(n in Engram.Notes.Note, where: n.id == ^created_id),
            set: [crdt_state_ciphertext: ct, crdt_state_nonce: nonce]
          )
        end)

      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
      push(socket, "crdt_msg", %{"doc_id" => created_id, "b64" => Base.encode64(frame)})

      assert_push "crdt_msg", %{"doc_id" => ^created_id, "b64" => b64}, 3000
      {:ok, {:sync, {:sync_step2, update}}} = Yex.Sync.message_decode(Base.decode64!(b64))
      :ok = Yex.apply_update(client, update)
      assert CrdtBridge.text_of(client) == "late body"
    end

    test "a successfully routed crdt_msg is ACKED with :ok", %{socket: socket, doc_id: doc_id} do
      # Without an ack, a client that attaches a reply/timeout handler treats
      # every successful push as a timeout: the web SPA re-handshook every open
      # note every ~3.5s forever (2026-07-14). The ack is the delivery signal.
      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})

      ref = push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(frame)})

      assert_reply ref, :ok, %{}, 3000
    end

    # ---------------------------------------------------------------------
    # doc_id IS the note_id — ownership validation, not path_hmac lookup
    # ---------------------------------------------------------------------

    test "crdt_msg routes to the room for a doc_id that IS the note_id", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      note = Fixtures.insert_note!(user, vault, path: "a.md")

      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})

      ref = push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => Base.encode64(frame)})

      refute_reply ref, :error
      assert_push "crdt_msg", %{"doc_id" => reply_doc_id}, 3000
      assert reply_doc_id == note.id
      assert CrdtRegistry.lookup(note.id)
    end

    test "crdt_msg for a note_id not in the vault is dropped — no room, no crash", %{
      socket: socket
    } do
      random_note_id = Ecto.UUID.generate()
      tiny_b64 = Base.encode64(<<0>>)

      log =
        capture_log(fn ->
          push(socket, "crdt_msg", %{"doc_id" => random_note_id, "b64" => tiny_b64})

          refute_push "crdt_msg", _payload, 300
        end)

      refute CrdtRegistry.lookup(random_note_id)

      assert log =~ "dropped crdt_msg",
             "Expected 'dropped crdt_msg' warning in log, got: #{inspect(log)}"
    end

    test "crdt_msg for an unknown note_id REPLIES note_not_found so the client can heal (#955)",
         %{socket: socket} do
      # The silent drop left the sending client talking into the void — the
      # 2026-07-07 create-race cross-wire stayed invisible client-side until a
      # cold-start reconcile. The error reply lets the plugin trigger its live
      # id-map reconcile (ensureNoteIdMapped, v1.11.22) immediately.
      random_note_id = Ecto.UUID.generate()
      tiny_b64 = Base.encode64(<<0>>)

      capture_log(fn ->
        ref = push(socket, "crdt_msg", %{"doc_id" => random_note_id, "b64" => tiny_b64})
        assert_reply ref, :error, %{reason: "note_not_found", doc_id: ^random_note_id}, 500
      end)
    end

    test "malformed base64 is silently ignored — no crash",
         %{socket: socket, doc_id: doc_id} do
      push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => "!!!not_valid_base64!!!"})
      refute_push "crdt_msg", _payload, 300
    end

    # -------------------------------------------------------------------------
    # Frame size cap
    # -------------------------------------------------------------------------

    test "oversize crdt_msg frame is rejected with frame_too_large error",
         %{socket: socket, doc_id: doc_id, note: note} do
      # Encode 5_000_001 bytes — one byte over the 5 MB cap.
      oversized_b64 = Base.encode64(:binary.copy(<<0>>, 5_000_001))

      ref = push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => oversized_b64})

      assert_reply ref, :error, %{reason: "frame_too_large"}, 3000

      # The room must NOT have been started (the frame was rejected before ensure_room).
      assert CrdtRegistry.lookup(note.id) == nil
    end

    test "a crafted syncStep1 with an implausible state vector is rejected before the NIF (P0 #989)",
         %{socket: socket, doc_id: doc_id, note: note} do
      # <<0, 0>> step1 + varUint8Array(<<128, 128, 128, 128, 15>>): a 5-byte
      # state vector claiming ~2^31 client entries. Reaching the y_ex NIF
      # (Yex.encode_state_as_update/2) would OOM-abort the ENTIRE node,
      # uncatchable. The guard must reject it with an error reply and never
      # start the room / touch the NIF. Deterministic bytes only — a random SV
      # here has crashed the VM before.
      malicious = <<0, 0, 5, 128, 128, 128, 128, 15>>

      ref = push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(malicious)})

      assert_reply ref, :error, %{reason: "implausible_state_vector"}, 3000

      # Rejected before ensure_room, so the room never started and the frame
      # never reached SharedDoc.send_yjs_message / the NIF.
      assert CrdtRegistry.lookup(note.id) == nil
    end

    # -------------------------------------------------------------------------
    # Log hygiene: doc_id (note_id) must appear in metadata, not the message body
    # -------------------------------------------------------------------------

    test "dropped-frame warning exposes the note_id unredacted for diagnosis",
         %{socket: socket, doc_id: doc_id} do
      # doc_id here is a valid note_id UUID (setup fixture).
      log =
        capture_log(fn ->
          push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => "!!!not_valid_base64!!!"})
          # Synchronize on channel processing — no push is sent back for bad frames,
          # so we wait out the window to confirm the warning fired before capture ends.
          refute_push "crdt_msg", _, 300
        end)

      assert log =~ "dropped crdt_msg",
             "Expected 'dropped crdt_msg' warning in log, got: #{inspect(log)}"

      # A note_id is a non-sensitive UUID and is REQUIRED to diagnose which note
      # lost the dropped edit — it must be visible (was redacted under :path,
      # which blocked the 2026-07-06 incident triage).
      assert String.contains?(log, doc_id),
             "Expected note_id #{inspect(doc_id)} to be visible in the log, got: #{inspect(log)}"

      # ...but only via metadata, never interpolated into the message body.
      [_meta_and_level, msg] = String.split(log, "[warning]", parts: 2)

      refute String.contains?(msg, doc_id),
             "note_id must live in metadata, not the message body: #{inspect(msg)}"

      # The drop must be attributable — user_id + vault_id (both non-sensitive
      # UUIDs) let a lost edit be traced to who hit it (the 2026-07-06 drops
      # carried neither).
      assert log =~ "user_id=", "drop log must carry user_id for attribution: #{inspect(log)}"
      assert log =~ "vault_id=", "drop log must carry vault_id for attribution: #{inspect(log)}"
    end

    test "a non-UUID doc_id stays redacted — never leaks a cleartext path",
         %{socket: socket} do
      # A stale path-keyed client sends a path as the doc_id. It is NOT a UUID,
      # so it must fall back to the redacted :path metadata key and never appear.
      secret_path = "PrivateFolder/Secret Note.md"

      log =
        capture_log(fn ->
          push(socket, "crdt_msg", %{"doc_id" => secret_path, "b64" => Base.encode64(<<0>>)})
          refute_push "crdt_msg", _, 300
        end)

      assert log =~ "dropped crdt_msg"

      refute String.contains?(log, secret_path),
             "A cleartext path in doc_id must never appear in logs: #{inspect(log)}"
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

      doc = SharedDoc.get_doc(room_pid)
      assert CrdtBridge.text_of(doc) == "base updated"

      # notify_activity wiring: if the timer pid was stored in the room's
      # process dict AND received :activity, the room stays alive (the timer
      # does not exit the room — it's linked the other way). The room being
      # alive confirms the full update→persist→notify path ran.
      assert Process.alive?(room_pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Rapid REST writes with a live room (e2e test_49/test_78 regression)
  #
  # Deliver-out used to re-diff the merged PLAINTEXT into the room doc,
  # re-encoding the same textual change on the room's own Yjs lineage. The
  # next REST write then replayed those room-lineage ops from the update-log
  # tail onto the snapshot (which carries the SAME change on the merge
  # lineage) — Yjs unions both encodings and the stored content duplicates
  # ("Version 2" + tail replay → "Version 22", cascading to the "Iteration 67"
  # interleave seen in e2e).
  # ---------------------------------------------------------------------------

  describe "rapid REST writes with a live room" do
    test "sequential REST updates stay verbatim and the room converges", %{
      socket: socket,
      doc_id: doc_id,
      user: user,
      vault: vault,
      note: note
    } do
      # 1. A client enrolls the note — the room binds from the "base" snapshot.
      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, step1_frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
      push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(step1_frame)})
      assert_push "crdt_msg", %{"b64" => _b64_step2}, 3000

      {:ok, room_pid} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)

      # 2. First REST write lands while the room is live. Deliver-out is async
      #    (SharedDoc.update_doc is a cast) — synchronize on the room having
      #    converged AND the delivery having reached the update-log tail, the
      #    exact preconditions of the e2e failure window.
      v2 = "# Stale Check\nIteration 2"
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => v2})

      wait_until(fn ->
        CrdtBridge.text_of(SharedDoc.get_doc(room_pid)) == v2 and
          tail_count(user) >= 1
      end)

      # 3. The next REST write replays the tail. It must come through verbatim —
      #    not doubled/interleaved with the delivered ops ("Iteration 22" / "23").
      v3 = "# Stale Check\nIteration 3"
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => v3})

      {:ok, stored} = Notes.get_note(user, vault, "p.md")
      assert stored.content == v3

      # 4. The room converges to the same text (delivery shares the merge
      #    lineage instead of re-encoding the change).
      wait_until(fn ->
        CrdtBridge.text_of(SharedDoc.get_doc(room_pid)) == v3
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Per-user crdt_msg rate limit
  #
  # Scoped in its own describe so the limit=2 override only applies to these
  # tests. Other tests in the file run at the production default (240/10_000ms)
  # and won't trip the limiter on valid-frame pushes.
  # ---------------------------------------------------------------------------

  describe "crdt_msg rate limiting" do
    setup do
      Application.put_env(:engram, :crdt_msg_rate_limit_override, 2)
      EngramWeb.RateLimiter.reset_buckets!()

      on_exit(fn ->
        Application.delete_env(:engram, :crdt_msg_rate_limit_override)
        EngramWeb.RateLimiter.reset_buckets!()
      end)
    end

    @tag capture_log: true
    test "sync handshake frames (STEP1/STEP2) do NOT consume the edit budget",
         %{socket: socket} do
      # 2026-07-07 incident: connect enrollment fires one STEP1 per note, so a
      # ~230-note vault blew the 240/10s crdt_msg limit on every connect and the
      # user's real edits were dropped for the window. Handshake frames must ride
      # a SEPARATE (larger) bucket so enrollment can never starve edits.
      # Yjs v1 layout (Yex.Sync doctest): <<0, 0, ..>> step1, <<0, 1, ..>> step2,
      # <<0, 2, ..>> update.
      step1_b64 = Base.encode64(<<0, 0, 0>>)
      step2_b64 = Base.encode64(<<0, 1, 0>>)
      update_b64 = Base.encode64(<<0, 2, 0>>)
      absent = Ecto.UUID.generate()

      # 4 handshake frames — double the edit override of 2 — all must pass.
      for b64 <- [step1_b64, step1_b64, step2_b64, step2_b64] do
        ref = push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => b64})
        refute_reply ref, :error, %{reason: "rate_limited"}, 100
      end

      # The edit budget (2) is UNTOUCHED by those handshakes: two updates pass,
      # the third is denied.
      push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => update_b64})
      push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => update_b64})
      ref = push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => update_b64})
      assert_reply ref, :error, %{reason: "rate_limited"}, 3000
    end

    @tag capture_log: true
    test "a LARGE STEP2 pays the edit budget — relabeled mutations don't get the 10x lane",
         %{socket: socket} do
      # STEP2 mutates the doc exactly like an update (y_ex applies both via
      # apply_update). Only the near-empty enrollment echo STEP2s ride the
      # handshake lane; a state-bearing STEP2 must count as an edit or a client
      # could relabel every mutation as <<0, 1, ..>> and bypass the edit cap.
      big_step2_b64 = Base.encode64(<<0, 1>> <> :binary.copy(<<7>>, 4_096))
      absent = Ecto.UUID.generate()

      push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => big_step2_b64})
      push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => big_step2_b64})
      ref = push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => big_step2_b64})

      assert_reply ref, :error, %{reason: "rate_limited"}, 3000
    end

    @tag capture_log: true
    test "the handshake bucket is still bounded (flood shield, not an exemption)",
         %{socket: socket} do
      Application.put_env(:engram, :crdt_hs_rate_limit_override, 2)
      on_exit(fn -> Application.delete_env(:engram, :crdt_hs_rate_limit_override) end)

      step1_b64 = Base.encode64(<<0, 0, 0>>)
      absent = Ecto.UUID.generate()

      push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => step1_b64})
      push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => step1_b64})
      ref = push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => step1_b64})

      assert_reply ref, :error, %{reason: "rate_limited"}, 3000
    end

    @tag capture_log: true
    test "crdt_catchup_since shares the handshake budget and is rejected once exhausted",
         %{socket: socket} do
      Application.put_env(:engram, :crdt_hs_rate_limit_override, 2)
      on_exit(fn -> Application.delete_env(:engram, :crdt_hs_rate_limit_override) end)

      push(socket, "crdt_catchup_since", %{})
      push(socket, "crdt_catchup_since", %{})
      ref = push(socket, "crdt_catchup_since", %{})

      assert_reply ref, :error, %{reason: "rate_limited"}, 3000
    end

    @tag capture_log: true
    test "crdt_msg beyond the rate limit is rejected with rate_limited error",
         %{socket: socket} do
      # Limit override = 2 (see describe setup above). Push a tiny valid frame
      # three times; the third must be denied. Uses a NON-EXISTENT note_id:
      # check_rate runs before ensure_room, so this exercises the limiter
      # without the allowed frames binding a room — a room-bind on the first two
      # frames can delay the third's reply past the assert window under load.
      tiny_b64 = Base.encode64(<<0>>)
      absent = Ecto.UUID.generate()

      push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      ref = push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})

      assert_reply ref, :error, %{reason: "rate_limited"}, 3000
    end

    # These target check_rate, which runs BEFORE ensure_room, so they push a
    # NON-EXISTENT note_id: the limiter counts every frame, but an allowed frame
    # just drops (no room started) — avoiding the room terminate-flush cascade
    # that starting a real room in a unit test triggers. @tag capture_log hides
    # the expected "dropped crdt_msg" warnings.
    @tag capture_log: true
    test "the limit is per-device: one device hitting the cap does not throttle another device of the same user",
         %{user: user, vault: vault} do
      tiny_b64 = Base.encode64(<<0>>)
      absent = Ecto.UUID.generate()
      topic = "crdt:#{user.id}:#{vault.id}"

      # Device A exhausts its own budget (override = 2).
      {:ok, _, sock_a} =
        user_socket(user)
        |> Phoenix.Socket.assign(:device_id, "dev-a")
        |> subscribe_and_join(EngramWeb.CrdtChannel, topic, %{"crdt_proto" => 2})

      Sandbox.allow(Repo, self(), sock_a.channel_pid)

      push(sock_a, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      push(sock_a, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      ref_a = push(sock_a, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      assert_reply ref_a, :error, %{reason: "rate_limited"}, 3000

      # Device B — SAME user, different device — has a fresh budget: its first
      # frame must NOT be rate-limited (a per-user bucket would already be spent).
      {:ok, _, sock_b} =
        user_socket(user)
        |> Phoenix.Socket.assign(:device_id, "dev-b")
        |> subscribe_and_join(EngramWeb.CrdtChannel, topic, %{"crdt_proto" => 2})

      Sandbox.allow(Repo, self(), sock_b.channel_pid)

      ref_b = push(sock_b, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      refute_reply ref_b, :error, %{reason: "rate_limited"}, 300
    end

    @tag capture_log: true
    test "buckets are user-scoped: a forged device_id cannot drain another user's budget",
         %{socket: socket, user: user, other_user: other_user} do
      tiny_b64 = Base.encode64(<<0>>)
      absent = Ecto.UUID.generate()

      # Attacker (other_user) forges device_id to the VICTIM's user id, trying to
      # land in the victim's rate bucket, and hammers from their OWN vault.
      insert(:user_limit_override, user: other_user, key: "vaults_cap", value: %{"v" => -1})
      {:ok, atk_vault} = Vaults.create_vault(other_user, %{name: "AtkVault"})

      {:ok, _, atk_sock} =
        user_socket(other_user)
        |> Phoenix.Socket.assign(:device_id, to_string(user.id))
        |> subscribe_and_join(
          EngramWeb.CrdtChannel,
          "crdt:#{other_user.id}:#{atk_vault.id}",
          %{"crdt_proto" => 2}
        )

      Sandbox.allow(Repo, self(), atk_sock.channel_pid)

      # Attacker exhausts its OWN (user-scoped) bucket (override = 2).
      push(atk_sock, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      push(atk_sock, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      ref_atk = push(atk_sock, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      assert_reply ref_atk, :error, %{reason: "rate_limited"}, 3000

      # The victim's bucket is untouched — the server-derived user_id prefix
      # means the forged device_id landed in the attacker's own tenant. The
      # victim pushes an absent note_id too (limiter counts it, no room).
      victim_absent = Ecto.UUID.generate()
      ref_victim = push(socket, "crdt_msg", %{"doc_id" => victim_absent, "b64" => tiny_b64})
      refute_reply ref_victim, :error, %{reason: "rate_limited"}, 300
    end
  end

  # ---------------------------------------------------------------------------
  # crdt_doc_ready — device-B discovery announce
  # ---------------------------------------------------------------------------
  #
  # When a client first opens a room, ensure_room/2 fires
  # `broadcast_from!(socket, "crdt_doc_ready", %{"doc_id" => doc_id})` so OTHER
  # devices on the vault topic learn the note exists and pull it (they would
  # otherwise never observe the room, since the channel only observes rooms it
  # has itself sent a crdt_msg for). Asserting this in a unit test requires a
  # live :global room, and a room's terminate-time snapshot flush
  # (CrdtPersistence.unbind) runs AFTER the test's sandbox owner exits — it
  # crashes and cascades the Repo down for the next test (same hazard called
  # out for the self-bootstrap case above). The full announce → step-1 → pull
  # path is therefore covered by the CRDT-on e2e suite (device-B receive),
  # not here. The plugin-side receive/dispatch is unit-tested in
  # channel-crdt.test.ts (`NoteChannel inbound crdt_doc_ready`).

  # ---------------------------------------------------------------------------
  # Room pid monitoring — dead rooms must be evicted from the channel cache
  # ---------------------------------------------------------------------------

  describe "room pid monitoring" do
    test "room death evicts the cached pid and the next crdt_msg lands in a fresh room", %{
      socket: socket,
      doc_id: doc_id,
      note: note
    } do
      # 1. Send a sync step-1 to spin up and cache the room.
      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
      push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(frame)})
      assert_push "crdt_msg", %{"doc_id" => ^doc_id}, 3000

      # 2. Grab the live room pid and hard-kill it (`:kill` bypasses trap_exit).
      room = CrdtRegistry.lookup(note.id)
      assert is_pid(room)
      Process.exit(room, :kill)

      # 3. Wait for :global to drop the registration (the DOWN message must have
      #    been processed by the channel) — poll up to ~500ms.
      wait_until(fn -> CrdtRegistry.lookup(note.id) == nil end)

      # Give the channel process a moment to handle the :DOWN message so it
      # evicts the stale entry from its assigns before we push the next frame.
      Process.sleep(50)

      # 4. Push another sync step-1 (simulates a fresh client opening the doc).
      client2 = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv2}} = Yex.Sync.get_sync_step1(client2)
      {:ok, frame2} = Yex.Sync.message_encode({:sync, {:sync_step1, sv2}})
      push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(frame2)})
      assert_push "crdt_msg", %{"doc_id" => ^doc_id}, 3000

      # 5. A new room must have been created — different pid from the killed one.
      #    Poll briefly: ensure_observed may have started the room just before the
      #    step2 was pushed back, and :global registration might lag by one tick.
      wait_until(fn -> CrdtRegistry.lookup(note.id) != nil end)
      new_room = CrdtRegistry.lookup(note.id)
      assert is_pid(new_room)
      refute new_room == room
    end
  end

  # Poll `condition` every 10ms for up to 500ms, then assert it's truthy.
  # with_tenant wraps the fun's return in {:ok, _} (Ecto transaction).
  defp tail_count(user) do
    {:ok, n} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(CrdtUpdateLog, :count)
      end)

    n
  end

  # A base64 Yjs update that, applied to a fresh empty doc, ingests `content`
  # as full note plaintext — i.e. the frame a client sends as the initial
  # crdt_create_batch payload for a brand-new note.
  defp frame_for_content(content) do
    doc = CrdtBridge.new_doc()
    :ok = CrdtBridge.ingest_plaintext(doc, content)
    {:ok, update} = Yex.encode_state_as_update(doc)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_update, update}})
    Base.encode64(frame)
  end

  # Poll get_note_by_id until the row's decrypted content matches (or flunk).
  defp assert_note_content_eventually(user, vault, note_id, content) do
    wait_until(fn ->
      case Notes.get_note_by_id(user, vault, note_id) do
        {:ok, note} -> note.content == content
        _ -> false
      end
    end)
  end

  defp wait_until(condition, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 500

    if condition.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk("wait_until: condition never became true within 500ms")
      else
        Process.sleep(10)
        wait_until(condition, deadline)
      end
    end
  end

  describe "per-socket room cap (abuse backstop)" do
    test "rejects a new room once the socket hits max_rooms_per_socket",
         %{socket: socket, user: user, vault: vault, note: note} do
      Application.put_env(:engram, :max_rooms_per_socket, 1)
      on_exit(fn -> Application.delete_env(:engram, :max_rooms_per_socket) end)
      on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)

      {:ok, note2} = Notes.upsert_note(user, vault, %{"path" => "p2.md", "content" => "base2"})
      on_exit(fn -> CrdtRegistry.terminate_room(note2.id) end)

      step1_b64 = fn ->
        client = CrdtBridge.new_doc()
        {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
        {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
        Base.encode64(frame)
      end

      # First distinct note opens room #1 (rooms 0 < cap 1). The server answers a
      # known note's step1 with a step2 push — wait for it so room #1 is up and
      # in this socket's assigns before the next frame is handled.
      push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => step1_b64.()})
      assert_push "crdt_msg", %{"doc_id" => _, "b64" => _}, 3000

      # Second distinct note would open room #2 (rooms 1 >= cap 1) → refused.
      ref = push(socket, "crdt_msg", %{"doc_id" => note2.id, "b64" => step1_b64.()})
      assert_reply ref, :error, %{reason: "room_limit"}, 3000
    end
  end

  # ---------------------------------------------------------------------------
  # Rotation gate (T3.7, #1092) — DEK rotation must block the socket write path
  # ---------------------------------------------------------------------------

  describe "rotation gate" do
    test "join is refused while a DEK rotation holds the user lock", %{
      user: user,
      vault: vault
    } do
      # Build the socket from the ORIGINAL unlocked struct (its
      # dek_rotation_locked_at is nil), THEN lock the DB row. Refusal here
      # proves RotationGate.check/1 re-reads the row — a stale-struct check
      # (check_user on socket.assigns) would wrongly allow this join, which is
      # the exact long-lived-socket case #1092 is about.
      socket = user_socket(user)

      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

      assert {:error, %{reason: "rotation_in_progress"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )
    end

    test "join is allowed again once the lock clears", %{user: user, vault: vault} do
      # Lock, confirm refusal, then clear — a fresh join must succeed, proving
      # the gate is not sticky.
      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

      assert {:error, %{reason: "rotation_in_progress"}} =
               subscribe_and_join(
                 user_socket(user),
                 EngramWeb.CrdtChannel,
                 "crdt:#{user.id}:#{vault.id}",
                 %{"crdt_proto" => 2}
               )

      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: nil]],
        skip_tenant_check: true
      )

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
end
