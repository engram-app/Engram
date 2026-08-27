defmodule EngramWeb.CrdtChannelTest do
  use EngramWeb.ChannelCase, async: false
  import Ecto.Query, only: [from: 2]

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Attachments, CheckpointInterleave, Crypto, Fixtures, Notes, Vaults}
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
    {:ok, vault, _} = Vaults.register_vault(user, "CrdtChannelTest", Ecto.UUID.generate())
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

    test "reply carries seeded: false when no b64 is sent", %{socket: socket} do
      id = Ecto.UUID.generate()
      ref = push(socket, "crdt_create", %{"doc_id" => id, "path" => "Notes/noseed.md"})
      assert_reply ref, :ok, %{doc_id: ^id, seeded: false}
    end
  end

  # The `genesis_seed` telemetry is how a fallback rate gets ATTRIBUTED — the
  # 2026-08-20 investigation could measure "70% of notes still open a room" but
  # not why, until these reasons existed. An instrument nobody tests reports
  # zeros when it breaks, and zeros read as "no declines", which is the same
  # vacuously-green failure the room-start probe was built to avoid. So the
  # instrument gets its own coverage.
  describe "genesis_seed telemetry" do
    setup do
      test_pid = self()
      handler = "genesis-seed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :crdt, :genesis_seed],
        fn _event, measurements, meta, _ ->
          send(test_pid, {:genesis_seed, meta, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "a bodyless create reports :no_b64", %{socket: socket} do
      ref =
        push(socket, "crdt_create", %{"doc_id" => Ecto.UUID.generate(), "path" => "Notes/a.md"})

      assert_reply ref, :ok, %{seeded: false}
      assert_receive {:genesis_seed, %{reason: :no_b64}, %{count: 1}}
    end

    test "a body-bearing create reports :seeded", %{socket: socket} do
      ref =
        push(socket, "crdt_create", %{
          "doc_id" => Ecto.UUID.generate(),
          "path" => "Notes/b.md",
          "b64" => frame_for_content("body")
        })

      assert_reply ref, :ok, %{seeded: true}
      # The telemetry reason is the OUTCOME atom now, not a two-way collapse of
      # it. `:write_declined` used to cover a benign concurrent-write decline,
      # an unreadable row and a raised write alike — one bar on the dashboard
      # for one routine event and two data-loss events (#1409 review).
      assert_receive {:genesis_seed, %{reason: :stored}, %{count: 1}}
    end

    test "a non-markdown path reports :not_markdown, not a frame error", %{socket: socket} do
      # `.canvas` rides these same creates but CRDT projects to notes.content
      # for markdown only. Distinguishing it from a malformed frame is the whole
      # reason the steps are tagged.
      ref =
        push(socket, "crdt_create", %{
          "doc_id" => Ecto.UUID.generate(),
          "path" => "Notes/board.canvas",
          "b64" => frame_for_content("body")
        })

      assert_reply ref, :ok, %{seeded: false}
      assert_receive {:genesis_seed, %{reason: :not_markdown}, _}
    end

    test "a malformed body reports :frame_decode_failed", %{socket: socket} do
      ref =
        push(socket, "crdt_create", %{
          "doc_id" => Ecto.UUID.generate(),
          "path" => "Notes/c.md",
          "b64" => "!!!not base64!!!"
        })

      assert_reply ref, :ok, %{seeded: false}
      assert_receive {:genesis_seed, %{reason: :frame_decode_failed}, _}
    end

    test "metadata carries ONLY the reason atom — never a payload-derived term", %{
      socket: socket
    } do
      # These error terms are the class this module's line ~418 warns about
      # ("error_kind/1, never inspect(reason)"): they can embed a wrapped DEK or
      # a provider response body. A `detail` key shipped here once; nothing
      # stopped a handler from `inspect`ing it into a log.
      ref =
        push(socket, "crdt_create", %{
          "doc_id" => Ecto.UUID.generate(),
          "path" => "Notes/d.md",
          "b64" => "!!!not base64!!!"
        })

      assert_reply ref, :ok, %{seeded: false}
      assert_receive {:genesis_seed, meta, _}
      assert Map.keys(meta) == [:reason]
      assert is_atom(meta.reason)
    end
  end

  describe "crdt_create with b64 (detached genesis seed)" do
    test "persists the body and creates NO room", %{socket: socket, user: user, vault: vault} do
      id = Ecto.UUID.generate()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/seeded.md",
          "b64" => frame_for_content("hello from genesis")
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: true}
      assert_note_content_eventually(user, vault, id, "hello from genesis")

      # The whole point: no SharedDoc actor was started for this note.
      assert CrdtRegistry.lookup(id) == nil
    end

    test "fans the genesis body out to the vault's other devices", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # #1409, found by the first paired e2e run. `note_yjs_update` is emitted
      # from CrdtPersistence.update_v1/4, which runs INSIDE the room GenServer.
      # A detached seed opens no room, so without an explicit fan-out a second
      # device only ever heard `crdt_doc_ready` — which says the note exists but
      # carries no content — and materialized the file at 0 bytes
      # (e2e-crdt test_no_conflict_modal_on_divergence; headless-protocol
      # "live A->B fan-out" saw the empty-string hash e3b0c44298fc).
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      id = Ecto.UUID.generate()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/fanned.md",
          "b64" => frame_for_content("# Fanned\n\ngenesis body")
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: true}

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "note_yjs_update",
                       payload: %{"note_id" => ^id, "b64" => b64}
                     },
                     2_000

      # FULL state, not a delta: a device that has never seen this note must
      # converge from an empty doc.
      {:ok, doc} = CrdtBridge.doc_from_state(Base.decode64!(b64))
      assert CrdtBridge.text_of(doc) == "# Fanned\n\ngenesis body"

      # Still no room — the fan-out must not resurrect the thing this whole
      # change removes.
      assert CrdtRegistry.lookup(id) == nil
    end

    test "an ack-loss retry with a FRESH clientID still takes the room-free fast path", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # #1409. The realistic retry: the create's ack was lost, so the client
      # rebuilds the genesis frame from scratch — a NEW Yjs clientID projecting
      # the SAME text. The existing "seeding the same note twice" test replays
      # the IDENTICAL frame, so it never exercises this.
      #
      # This is the case the tail/snapshot fold made subtle. `fold_row_and_tail/4`
      # applies the STORED snapshot (clientID A) into a doc holding the retry
      # frame (clientID B), and two independent inserts of the same text are
      # concurrent under YATA, so the UNION projects the body twice. Comparing
      # that union against the row would decline the retry (`seeded: false`),
      # sending the client to its crdt_msg fallback — which is safe but costs a
      # room, the exact thing this change exists to avoid.
      #
      # So the "already synced?" question is asked against the frame's OWN
      # projection, before the fold — what the client HAS — while the union is
      # only ever what a real write COMMITS. Both values, two jobs.
      id = Ecto.UUID.generate()
      payload = %{"doc_id" => id, "path" => "Notes/ackloss.md"}

      ref1 = push(socket, "crdt_create", Map.put(payload, "b64", frame_for_content("once")))
      assert_reply ref1, :ok, %{doc_id: ^id, seeded: true}
      assert_note_content_eventually(user, vault, id, "once")

      # A SEPARATE frame_for_content/1 call — CrdtBridge.new_doc/0 mints a fresh
      # clientID, which is what makes this different from the retry test above.
      ref2 = push(socket, "crdt_create", Map.put(payload, "b64", frame_for_content("once")))
      assert_reply ref2, :ok, %{doc_id: ^id, seeded: true}

      # Not doubled, and still no room: the retry cost nothing.
      assert {:ok, note} = Notes.get_note_by_id(user, vault, id)
      assert note.content == "once"
      assert CrdtRegistry.lookup(id) == nil
    end

    test "folds a tail row written in the seed window instead of stranding it", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # #1409 H2, data loss. In the seed window device B can open the note,
      # have bind/3 hydrate the still-bare row into an EMPTY doc, type, and land
      # a tail row — while notes.content is STILL "" because the room's
      # checkpoint is debounced by seconds. A seed that reads "" and writes only
      # the genesis lineage strands that edit: it bumps seq (so an offline
      # device pages our content and advances past it) and then
      # evict_racing_room/1 kills the room whose debounced checkpoint was the
      # only thing that would ever have materialized it.
      id = Ecto.UUID.generate()
      ref1 = push(socket, "crdt_create", %{"doc_id" => id, "path" => "Notes/tail.md"})
      assert_reply ref1, :ok, %{doc_id: ^id}

      insert_tail_row(user, vault, id, "TAILEDIT")
      assert tail_count(user) == 1

      ref2 =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/tail.md",
          "b64" => frame_for_content("GENESIS")
        })

      assert_reply ref2, :ok, %{doc_id: ^id, seeded: true}

      assert {:ok, note} = Notes.get_note_by_id(user, vault, id)
      assert note.content =~ "TAILEDIT", "the tail edit was destroyed by the seed"
      assert note.content =~ "GENESIS"

      # Folded means pruned: prune_ids carried exactly that row, so the log is
      # empty rather than holding an edit already in the snapshot.
      assert tail_count(user) == 0
    end

    test "emits no room_start telemetry — the whole point, measured by allocation", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # #1409. Residency after the fact cannot prove this: rooms idle-drain, so
      # a room-per-note regression can allocate and release entirely between two
      # samples. `[:engram, :crdt, :room_start]` counts ALLOCATION, which is the
      # claim. Guarded here so the e2e gate that reads the same event is not the
      # only thing standing behind it.
      test_pid = self()
      handler = "room-start-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :crdt, :room_start],
        fn _e, m, _meta, _ -> send(test_pid, {:room_start, m}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      for n <- 1..3 do
        id = Ecto.UUID.generate()

        ref =
          push(socket, "crdt_create", %{
            "doc_id" => id,
            "path" => "Notes/alloc#{n}.md",
            "b64" => frame_for_content("body #{n}")
          })

        assert_reply ref, :ok, %{doc_id: ^id, seeded: true}
        assert_note_content_eventually(user, vault, id, "body #{n}")
      end

      refute_receive {:room_start, _}, 100

      # Sanity that the probe is wired: a real room start DOES fire it, so the
      # refute above is an observation, not a broken handler.
      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "Notes/probe.md", "content" => "x"})

      {:ok, _room} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)
      on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)
      assert_receive {:room_start, %{count: 1}}, 2_000
    end

    test "a non-markdown genesis frame is never seeded", %{socket: socket, vault: _vault} do
      # #1409 M3. CRDT projects to notes.content for markdown only —
      # checkpoint/5 routes a .canvas doc to do_structural_checkpoint, which
      # never touches content. Its frame therefore projects "" against a fresh
      # (also "") row, hits the idempotent clause, and would report seeded: true
      # having written nothing, so the client stamps its body as synced and
      # stops. Unreachable today only because the plugin gates .md client-side.
      id = Ecto.UUID.generate()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/board.canvas",
          "b64" => frame_for_content("")
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: false}
    end

    test "a declined seed does NOT fan out", %{socket: socket, user: user, vault: vault} do
      # The fan-out rides the write path only. A create whose row already holds
      # a DIFFERENT body writes nothing, so broadcasting would push state no
      # writer here produced.
      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "Notes/taken.md", "content" => "base"})

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => note.id,
          "path" => "Notes/taken.md",
          "b64" => frame_for_content("something else")
        })

      assert_reply ref, :ok, %{doc_id: _, seeded: false}
      refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 200
    end

    test "seeding the same note twice does not double the body", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # #846: a client retry re-sends the create. The create-time checkpoint
      # flattens the doc to a fresh server lineage, so a naive re-apply APPENDS
      # rather than merging as a no-op and the body doubles.
      id = Ecto.UUID.generate()
      frame = frame_for_content("once")
      payload = %{"doc_id" => id, "path" => "Notes/retry.md", "b64" => frame}

      ref1 = push(socket, "crdt_create", payload)
      assert_reply ref1, :ok, %{seeded: true}
      assert_note_content_eventually(user, vault, id, "once")

      ref2 = push(socket, "crdt_create", payload)
      assert_reply ref2, :ok, %{doc_id: ^id}

      assert {:ok, note} = Notes.get_note_by_id(user, vault, id)
      assert note.content == "once"
    end

    test "a live room for the note skips the detached seed", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # Two writers, one document. A detached write would be invisible to the
      # room, which later checkpoints its own in-memory doc over it.
      #
      # The realistic shape: the create is retried (it is idempotent) after the
      # user opened the note in an editor, so a room now exists for it.
      id = Ecto.UUID.generate()
      ref1 = push(socket, "crdt_create", %{"doc_id" => id, "path" => "Notes/live.md"})
      assert_reply ref1, :ok, %{doc_id: ^id}

      {:ok, _room} = CrdtRegistry.ensure_started(user.id, vault.id, id)
      on_exit(fn -> CrdtRegistry.terminate_room(id) end)

      ref2 =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/live.md",
          "b64" => frame_for_content("body")
        })

      assert_reply ref2, :ok, %{doc_id: ^id, seeded: false}
    end

    test "a detached seed materializes the same content as the same frame through a room", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # The equivalence this design rests on: "detached" must be a deployment
      # detail, not a second semantics. Same frame, two routes, one result.
      frame = frame_for_content("# Title\n\nshared body")

      detached_id = Ecto.UUID.generate()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => detached_id,
          "path" => "Notes/detached.md",
          "b64" => frame
        })

      assert_reply ref, :ok, %{seeded: true}

      roomed_id = Ecto.UUID.generate()
      ref2 = push(socket, "crdt_create", %{"doc_id" => roomed_id, "path" => "Notes/roomed.md"})
      assert_reply ref2, :ok, %{doc_id: ^roomed_id}
      ref3 = push(socket, "crdt_msg", %{"doc_id" => roomed_id, "b64" => frame})
      # Await the ack (routed-to-room, per handle_in("crdt_msg", ...)) instead
      # of a bare push, so the room has actually started + observed the frame
      # before the poll below begins — otherwise room startup/:global
      # registration eats into the SAME window as the checkpoint-timer wait.
      assert_reply ref3, :ok, %{}

      # This leg converges on the room's checkpoint TIMER (~250ms), not on the
      # write itself — unlike the detached leg, which is synchronous. Give it a
      # deadline generous relative to that timer; this is a convergence
      # deadline, not a correctness bound (the assertion below is unchanged).
      assert_note_content_eventually(
        user,
        vault,
        roomed_id,
        "# Title\n\nshared body",
        System.monotonic_time(:millisecond) + 2_000
      )

      assert_note_content_eventually(user, vault, detached_id, "# Title\n\nshared body")

      assert {:ok, detached} = Notes.get_note_by_id(user, vault, detached_id)
      assert {:ok, roomed} = Notes.get_note_by_id(user, vault, roomed_id)
      assert detached.content == roomed.content
    end

    test "a malformed b64 creates the row and reports seeded: false", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # The row must still exist: identity and content are separate concerns, and
      # the client's fallback is a crdt_msg seed against that row.
      id = Ecto.UUID.generate()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/bad.md",
          "b64" => "!!!not base64!!!"
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: false}
      assert Notes.note_in_vault?(user, vault, id)
    end

    test "a row holding a DIFFERENT body than the frame declines and leaves the row untouched",
         %{socket: socket, user: user, vault: vault, note: note} do
      # `note` (from setup) is live at "p.md" with content "base". A same-path
      # crdt_create is the idempotent-retry leg (reaches {:ok, note}, not
      # {:adopted, _}), so this exercises seed_against/6's THIRD clause: the
      # row content ("base") and the frame's projection disagree — a
      # concurrent write landed between genesis and here — so it must decline
      # rather than merge two lineages itself.
      id = note.id

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "p.md",
          "b64" => frame_for_content("a different body")
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: false}
      assert {:ok, unchanged} = Notes.get_note_by_id(user, vault, id)
      assert unchanged.content == "base"
    end

    test "an empty frame on an already-empty row reports seeded: true with no write", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # A fresh genesis row starts with content: "" (genesis_insert_bare). A
      # frame that projects "" therefore matches seed_against/6's FIRST
      # clause (expected, expected pattern-equality) before ever reaching the
      # second ("" row) clause — the idempotent short-circuit, not a real
      # write.
      id = Ecto.UUID.generate()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/empty.md",
          "b64" => frame_for_content("")
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: true}
      assert {:ok, note} = Notes.get_note_by_id(user, vault, id)
      assert note.content == ""
    end

    test "a room that registers in the write window is evicted after the seed commits",
         %{socket: socket, user: user, vault: vault} do
      # #1409. `maybe_seed_detached/4`'s CrdtRegistry.lookup at the top is only
      # a cheap fast path — a room can register (and CrdtPersistence.bind/3
      # hydrate from the still-empty row) between that check and the write in
      # `seed_detached/5`, leaving that room divergent from the row. Round 3
      # fenced this with an advisory lock on both sides; that stalled every
      # room start on the node (bind/3 runs inline in the single
      # DynamicSupervisor process), so the seed now cleans up after itself
      # instead: commit, then terminate the racer so it re-binds against the
      # committed row.
      #
      # This drives exactly that window: park the create right before the write
      # transaction, register a room in the gap, then let it continue.
      #
      # What this test proves: the post-commit re-check finds the racing room,
      # terminates it, and the body still lands durably (`seeded: true`).
      # What it does NOT prove: any cross-connection ordering. Under this
      # file's SHARED sandbox connection (`async: false`) the channel and the
      # room's bind/3 are the SAME Postgres session, so there is no real
      # concurrency between the two DB legs here — only the registry
      # interleaving is genuine (CrdtRegistry is a `:global` process registry,
      # not transaction-gated).
      id = Ecto.UUID.generate()

      on_exit(CheckpointInterleave.arm(:genesis_seed_before_write))

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/race.md",
          "b64" => frame_for_content("body")
        })

      parked = CheckpointInterleave.await_parked(:genesis_seed_before_write, socket.channel_pid)

      {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, id)
      on_exit(fn -> CrdtRegistry.terminate_room(id) end)
      room_ref = Process.monitor(room)

      CheckpointInterleave.release(:genesis_seed_before_write, parked)

      assert_reply ref, :ok, %{doc_id: ^id, seeded: true}
      assert_note_content_eventually(user, vault, id, "body")

      # The stale room is gone, so the client's next crdt_msg starts a fresh
      # one that binds against the row we just committed.
      assert_receive {:DOWN, ^room_ref, :process, ^room, _}, 2_000
      assert CrdtRegistry.lookup(id) == nil
    end

    test "a seed that writes nothing leaves a racing room alone", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # The eviction is scoped to the clause that actually writes (#1409). An
      # idempotent retry against a row that ALREADY holds the frame's body wrote
      # nothing, so no room can have gone stale behind it — killing one would
      # drop a live editing session for free.
      id = Ecto.UUID.generate()
      payload = %{"doc_id" => id, "path" => "Notes/noop.md", "b64" => frame_for_content("body")}

      ref1 = push(socket, "crdt_create", payload)
      assert_reply ref1, :ok, %{seeded: true}
      assert_note_content_eventually(user, vault, id, "body")

      on_exit(CheckpointInterleave.arm(:genesis_seed_before_write))
      ref2 = push(socket, "crdt_create", payload)

      parked = CheckpointInterleave.await_parked(:genesis_seed_before_write, socket.channel_pid)

      {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, id)
      on_exit(fn -> CrdtRegistry.terminate_room(id) end)

      CheckpointInterleave.release(:genesis_seed_before_write, parked)

      assert_reply ref2, :ok, %{doc_id: ^id, seeded: true}
      assert CrdtRegistry.lookup(id) == room
    end

    test "a DEK rotation in progress reports seeded: false and leaves the row empty", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # CrdtCheckpoint.checkpoint/5 returns :ok when it SKIPS for rotation
      # (#1341). Building the reply from that :ok would tell the plugin the file
      # is synced while nothing was written — and a fresh import has no later
      # bind to replay from, so the note would just be empty forever.
      id = Ecto.UUID.generate()

      {:ok, _} =
        user
        |> Ecto.Changeset.change(dek_rotation_locked_at: DateTime.utc_now())
        |> Repo.update()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/rotating.md",
          "b64" => frame_for_content("must not be reported as synced")
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: false}

      assert {:ok, note} = Notes.get_note_by_id(user, vault, id)
      assert note.content == ""
    end

    test "a decline caused by a concurrent write is distinguishable from an empty server (#476)",
         %{socket: socket, user: user, vault: vault} do
      # THE #476 DOUBLING BUG. `seeded: false` collapses two server states that
      # need OPPOSITE client actions:
      #
      #   "I wrote nothing and the row is empty"  -> the client MUST push
      #   "I declined, the row holds another body" -> the client must NOT push
      #
      # In the second case the client pushed anyway, into what it still believed
      # was an empty doc. Writing a body into an empty Y.Doc mints a fresh
      # clientID, so that push is a RIVAL lineage carrying identical text, and
      # YATA's job is to preserve both concurrent inserts. The union is the note,
      # twice. Measured on a real 423-item import: 13 notes at exact 2x, the
      # largest a 34 KB note stored as 68,520 bytes.
      #
      # No client-side guard can fix this: the client cannot be correct with one
      # bit that does not distinguish the two. So the reply has to say WHICH.
      #
      # Reproduced deterministically by parking the seed at its pre-write seam
      # and landing a different body in exactly that window — the same race the
      # `seed_against/7` catch-all comment describes ("a concurrent write landed
      # between genesis and here"), which real imports hit more often on large
      # notes because a bigger frame means a longer decode/apply.
      id = Ecto.UUID.generate()

      on_exit(CheckpointInterleave.arm(:genesis_seed_before_write))

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/declined.md",
          "b64" => frame_for_content("client body")
        })

      parked = CheckpointInterleave.await_parked(:genesis_seed_before_write, socket.channel_pid)

      # The concurrent write the decline exists to protect.
      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Notes/declined.md",
          "content" => "a DIFFERENT body that must not be clobbered"
        })

      CheckpointInterleave.release(:genesis_seed_before_write, parked)

      # `seeded: false` stays for older clients, but it is no longer the whole
      # story: `genesis` names the outcome so the client can act on it.
      assert_reply ref, :ok, %{doc_id: ^id, seeded: false, genesis: "occupied"}
    end

    test "a create the server could not seed at all reports an EMPTY server, so the client may push",
         %{socket: socket} do
      # The other half of the distinction. Nothing raced here: the server simply
      # has no genesis bytes (no b64), the row it just created is empty, and
      # pushing the body is not merely safe but REQUIRED — treating this as
      # "occupied" would leave every such note permanently blank.
      id = Ecto.UUID.generate()
      ref = push(socket, "crdt_create", %{"doc_id" => id, "path" => "Notes/nob64.md"})

      assert_reply ref, :ok, %{doc_id: ^id, seeded: false, genesis: "absent"}
    end

    test "an idempotent retry over a row that HOLDS a body never reports absent", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # `:absent` is the one outcome the client trusts without verifying, so it
      # must mean the row is empty. It did not: `genesis_crdt_note/4` answers
      # `{:ok, note}` for an idempotent same-path retry, an E2 rename-as-move
      # AND a tombstone resurrect — all of which can carry a full body — and the
      # old code inferred "empty" from "we did not write". Proven by repro:
      # `genesis: "absent"` with `row_content: "base body"`, which makes the
      # client push a second copy into what it believes is an empty doc.
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Notes/holds-a-body.md",
          "content" => "a body that must not be doubled"
        })

      # Bodyless create against that live id + same path = the idempotent retry.
      ref =
        push(socket, "crdt_create", %{"doc_id" => note.id, "path" => "Notes/holds-a-body.md"})

      assert_reply ref, :ok, %{seeded: false, genesis: "occupied"}
    end

    test "an UNREADABLE row that is provably empty reports absent, not occupied", %{
      socket: socket
    } do
      # The inverse lie. `fold_row_and_tail/4` collapses "note not found",
      # "snapshot undecryptable" and "DEK unavailable" into one `:error`, which
      # became `occupied` = "never push" for a row that is provably EMPTY. A
      # transient KMS blip then told the client its body was unnecessary and
      # nothing ever re-opened the note, so it stayed blank on every device.
      #
      # Driven here through the cheapest unreadable path: a frame the server
      # cannot decode at all, against a freshly created (empty) row.
      id = Ecto.UUID.generate()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/undecodable.md",
          "b64" => "!!!not-base64!!!"
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: false, genesis: "absent"}
    end

    test "a successful seed reports that the server holds our bytes", %{socket: socket} do
      id = Ecto.UUID.generate()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/stored.md",
          "b64" => frame_for_content("body")
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: true, genesis: "stored"}
    end

    test "a write ABORTED by a concurrent one reports occupied, not absent", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # #476, third wave. The decline test above catches the concurrent write at
      # FOLD time. This one lands it later — after the fold, inside
      # `checkpoint/5`, in the gap its own `:after_row_read` seam exists for —
      # so the fenced write ABORTS instead of declining.
      #
      # The outcome used to be derived from `wrote?`: the write CLAUSE ran, so
      # the answer was `:absent` = "the row is empty, you must push". It was the
      # opposite of true. The write aborted precisely BECAUSE the row had just
      # been filled, and the client then pushed a body into a history-less doc,
      # minting the rival lineage this whole path exists to prevent.
      #
      # `row_state_after_write/4` was already re-reading the row and throwing
      # the answer away.
      id = Ecto.UUID.generate()

      # A BESPOKE hook rather than `CheckpointInterleave.arm/1`, and the reason
      # is the point that matters if you copy this: every existing interleave
      # test in this file arms `:genesis_seed_before_write`, which ONLY the
      # genesis path fires. `:after_row_read` fires on EVERY checkpoint —
      # including the background room-drain and checkpoint-timer ones this suite
      # leaves running. A global one-shot park would be consumed by whichever
      # checkpoint reached it first, stalling an unrelated room for the full
      # park timeout and starving later tests' channels. Parking only when the
      # parked process IS this channel confines it to the write under test.
      test_pid = self()
      channel_pid = socket.channel_pid
      armed = :counters.new(1, [:atomics])
      prev = Application.get_env(:engram, :checkpoint_interleave_hook)

      Application.put_env(:engram, :checkpoint_interleave_hook, fn
        :after_row_read ->
          if self() == channel_pid and :counters.get(armed, 1) == 0 do
            :counters.add(armed, 1, 1)
            send(test_pid, {:parked_here, self()})

            receive do
              :release_park -> :ok
            after
              5_000 -> :ok
            end
          end

          :ok

        _other ->
          :ok
      end)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:engram, :checkpoint_interleave_hook),
          else: Application.put_env(:engram, :checkpoint_interleave_hook, prev)
      end)

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/aborted.md",
          "b64" => frame_for_content("client body")
        })

      assert_receive {:parked_here, ^channel_pid}, 5_000

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Notes/aborted.md",
          "content" => "the concurrent body that won the fence"
        })

      send(channel_pid, :release_park)

      assert_reply ref, :ok, %{doc_id: ^id, seeded: false, genesis: "occupied"}
      # ...and the winner's body survives. An `absent` reply would have had the
      # client union a second lineage over exactly this.
      assert_note_content_eventually(user, vault, id, "the concurrent body that won the fence")
    end

    test "a RAISED seed costs that note its seed, never the channel", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # `seed_detached/4` wraps itself in a rescue for one reason: a raised query
      # (connection loss, a crypto fault) must cost THIS note its seed and
      # nothing else. Without it the channel process dies, taking every room
      # binding on the socket with it, and the client sees no reply at all.
      #
      # So this asserts BOTH halves — the honest per-note answer AND that the
      # socket is still serving afterwards. Asserting only the outcome would
      # pass with the rescue deleted in some orderings, since a dead channel and
      # a declined seed can look alike from one assertion.
      #
      # Driven by making the pre-write seam RAISE rather than park, which is the
      # cheapest way to reach the rescue without a fake.
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Notes/raised.md",
          "content" => "a body a transient fault must not endanger"
        })

      prev = Application.get_env(:engram, :checkpoint_interleave_hook)

      Application.put_env(:engram, :checkpoint_interleave_hook, fn
        :genesis_seed_before_write -> raise "transient fault"
        _other -> :ok
      end)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:engram, :checkpoint_interleave_hook),
          else: Application.put_env(:engram, :checkpoint_interleave_hook, prev)
      end)

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => note.id,
          "path" => "Notes/raised.md",
          "b64" => frame_for_content("client body")
        })

      # `:unreadable` reconciled against the caller's snapshot, which HAS a body.
      # A transient fault must never tell the client to push into a filled row.
      assert_reply ref, :ok, %{doc_id: _, seeded: false, genesis: "occupied"}

      # The channel is still alive and serving — the whole point of the rescue.
      # (The hook only raises on the genesis seam, so this bodyless create runs
      # clean.)
      id2 = Ecto.UUID.generate()
      ref2 = push(socket, "crdt_create", %{"doc_id" => id2, "path" => "Notes/after-raise.md"})
      assert_reply ref2, :ok, %{doc_id: ^id2}
    end

    test "an ADOPT reports occupied, and never applies our frame to the adopted note", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # The single-create ADOPT arm — the path is already owned by a LIVE note
      # under a different id, so `genesis_crdt_note/4` answers `{:adopted,
      # note}` and the reply carries the AUTHORITATIVE id.
      #
      # Its `genesis` is a hardcoded "occupied", and that is the one arm of the
      # decision table nothing exercised. It matters as much as any other:
      # `absent` here would tell the client to push a whole body onto a lineage
      # that already carries another note's, unioning the two under YATA. The
      # client's ADOPT path transfers ours deliberately instead.
      {:ok, existing} =
        Notes.upsert_note(user, vault, %{
          "path" => "Notes/adopted.md",
          "content" => "the note that already owns this path"
        })

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => Ecto.UUID.generate(),
          "path" => "Notes/adopted.md",
          "b64" => frame_for_content("our body")
        })

      existing_id = existing.id
      assert_reply ref, :ok, %{doc_id: ^existing_id, seeded: false, genesis: "occupied"}

      # And the frame was NOT merged into it — the ADOPT transfer is the client's
      # job, on a lineage it has first acquired.
      {:ok, still} = Notes.get_note(user, vault, "Notes/adopted.md")
      assert still.content == "the note that already owns this path"
    end

    test "a room already holding the doc reports occupied, never absent", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # `require_room_free/1` declines because a room owns the document, and a
      # room's in-memory doc can hold content the row does not show yet. Reading
      # that as "the server has nothing" is the same data-loss shape as the
      # decline above.
      id = Ecto.UUID.generate()
      {:ok, _room} = CrdtRegistry.ensure_started(user.id, vault.id, id)
      on_exit(fn -> CrdtRegistry.terminate_room(id) end)

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/roombusy.md",
          "b64" => frame_for_content("body")
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: false, genesis: "occupied"}
    end

    test "a new room started after eviction re-binds against the seeded row (STEP2 carries the body)",
         %{socket: socket, user: user, vault: vault} do
      # The eviction test above ("a room that registers in the write window is
      # evicted after the seed commits") proves the racing room dies. It does
      # NOT prove the entire point of killing it: that the REPLACEMENT room a
      # client's next STEP1 opens actually re-binds against the row the seed
      # just committed, rather than an empty one. Close that gap by driving a
      # real client through crdt_msg after the eviction, same as the
      # `describe "crdt_msg"` STEP1/STEP2 idiom elsewhere in this file.
      #
      # Reuses the exact race setup from the eviction test: park the seed right
      # before its write via the same CheckpointInterleave seam, register a
      # room in the gap, then release.
      id = Ecto.UUID.generate()

      on_exit(CheckpointInterleave.arm(:genesis_seed_before_write))

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/race-rebind.md",
          "b64" => frame_for_content("seeded body")
        })

      parked = CheckpointInterleave.await_parked(:genesis_seed_before_write, socket.channel_pid)

      {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, id)
      on_exit(fn -> CrdtRegistry.terminate_room(id) end)
      room_ref = Process.monitor(room)

      CheckpointInterleave.release(:genesis_seed_before_write, parked)

      assert_reply ref, :ok, %{doc_id: ^id, seeded: true}
      assert_note_content_eventually(user, vault, id, "seeded body")

      # The racer is confirmed dead before we drive the replacement — otherwise
      # a STEP1 below could route through the still-alive racer instead of
      # exercising the fresh bind this test is actually about.
      assert_receive {:DOWN, ^room_ref, :process, ^room, _}, 2_000
      assert CrdtRegistry.lookup(id) == nil

      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
      push(socket, "crdt_msg", %{"doc_id" => id, "b64" => Base.encode64(frame)})

      assert_push "crdt_msg", %{"doc_id" => ^id, "b64" => b64}, 3000
      {:ok, {:sync, {:sync_step2, update}}} = Yex.Sync.message_decode(Base.decode64!(b64))
      :ok = Yex.apply_update(client, update)
      assert CrdtBridge.text_of(client) == "seeded body"
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

  # #1409: the whole point of this frame is that it does NOT start a room.
  # `crdt_msg` routes every syncStep1 through `ensure_room`, so obtaining a cold
  # note's state cost one server room per note on a bulk first sync.
  describe "crdt_doc_state (room-free full-state read)" do
    test "returns the note's full Yjs state and starts NO room", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "Notes/cold.md", "content" => "cold body"})

      refute CrdtRegistry.lookup(note.id), "precondition: no room before the read"

      ref = push(socket, "crdt_doc_state", %{"doc_id" => note.id})
      assert_reply ref, :ok, %{doc_id: doc_id, b64: b64, head: head}

      assert doc_id == note.id
      assert is_binary(head)

      # The reply is real state, not an empty doc: it projects the body.
      {:ok, update} = Base.decode64(b64)
      {:ok, doc} = CrdtBridge.doc_from_state(update)
      assert CrdtBridge.project_doc(doc) =~ "cold body"

      # THE assertion this frame exists for.
      refute CrdtRegistry.lookup(note.id),
             "crdt_doc_state must not allocate a room (#1409)"
    end

    test "rejects an unknown note_id with the same signal crdt_msg sends", %{socket: socket} do
      ref = push(socket, "crdt_doc_state", %{"doc_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, %{reason: "note_not_found"}
    end

    test "rejects a non-UUID doc_id without echoing it back", %{socket: socket} do
      ref = push(socket, "crdt_doc_state", %{"doc_id" => "Notes/cleartext-path.md"})
      assert_reply ref, :error, reply
      assert reply.reason == "bad_doc_id"
      refute Map.has_key?(reply, :doc_id)
    end

    test "bills the handshake budget — it is the frame that REPLACES a handshake", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # The frame's own docstring says it "must bill the same budget or it would
      # be a way to dodge it", and nothing enforced that: deleting `check_rate`
      # was green (mutation B7). It matters more than a normal frame, not less —
      # a syncStep1 amortizes against a cached room, while this does a full
      # uncached rebuild (DB read, AES decrypt, apply, tail replay, encode) on
      # the channel process, once per cold note during a bulk sync.
      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "Notes/billed.md", "content" => "b"})

      # Shrink the handshake bucket to 1 and prove the SECOND read is refused —
      # which can only happen if the first one consumed the budget.
      Application.put_env(:engram, :crdt_hs_rate_limit_override, 1)

      on_exit(fn ->
        Application.delete_env(:engram, :crdt_hs_rate_limit_override)
        EngramWeb.RateLimiter.reset_buckets!()
      end)

      EngramWeb.RateLimiter.reset_buckets!()

      ref1 = push(socket, "crdt_doc_state", %{"doc_id" => note.id})
      assert_reply ref1, :ok, %{doc_id: _}

      ref2 = push(socket, "crdt_doc_state", %{"doc_id" => note.id})
      assert_reply ref2, :error, %{reason: "rate_limited"}
    end

    test "refuses to read a note in ANOTHER user's vault", %{socket: socket} do
      {:ok, other} = Fixtures.user_with_dek_fixture()
      other_vault = Fixtures.insert_vault!(other, "Other")

      {:ok, note} =
        Notes.upsert_note(other, other_vault, %{
          "path" => "Notes/theirs.md",
          "content" => "secret"
        })

      ref = push(socket, "crdt_doc_state", %{"doc_id" => note.id})
      assert_reply ref, :error, %{reason: "note_not_found"}
    end

    test "an unreadable snapshot answers an error and leaves the CHANNEL ALIVE", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # `CrdtTransport.load_doc/3` deliberately raises on a decrypt/decode
      # failure ("loud rather than silently returning an empty doc"). That was
      # safe while `read_delta/4` had NO caller — its REST route was deleted in
      # #1088. Wiring it to a socket frame made the raise live, and an
      # uncontained raise here does not cost one note: it kills the channel
      # process, taking `socket.assigns.rooms` and every monitor with it. The
      # client then rejoins and re-handshakes EVERY note — the exact room storm
      # #1409 exists to prevent — and since it retries the same frame, it loops.
      #
      # So the assertion that matters is not the error shape, it is that a
      # SECOND frame still works afterwards.
      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "Notes/poison.md", "content" => "body"})

      {:ok, healthy} =
        Notes.upsert_note(user, vault, %{"path" => "Notes/healthy.md", "content" => "fine"})

      # Corrupt the persisted snapshot: ciphertext that cannot decrypt.
      Repo.with_tenant(user.id, fn ->
        from(n in "notes", where: n.id == type(^note.id, Ecto.UUID))
        |> Repo.update_all(set: [crdt_state_ciphertext: :crypto.strong_rand_bytes(64)])
      end)

      ref = push(socket, "crdt_doc_state", %{"doc_id" => note.id})
      assert_reply ref, :error, reply
      # Never echo the raw failure — it can embed a wrapped DEK or provider body.
      assert reply.reason == "doc_state_failed"

      # THE assertion: the channel survived, so one poisoned note cannot cost
      # the whole session its rooms.
      ref2 = push(socket, "crdt_doc_state", %{"doc_id" => healthy.id})
      assert_reply ref2, :ok, %{doc_id: _, b64: _, head: _}
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

    test "a non-UUID cursor_id degrades to seq-only instead of crashing", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "Notes/g1.md", "content" => "1"})
      {:ok, n2} = Notes.upsert_note(user, vault, %{"path" => "Notes/g2.md", "content" => "2"})

      # Garbage cursor_id must not reject or 500 — it's a pagination refinement,
      # so it falls back to the seq-only cursor (seq > n1.seq → n2 only).
      ref =
        push(socket, "crdt_catchup_since", %{"cursor_seq" => n1.seq, "cursor_id" => "not-a-uuid"})

      assert_reply ref, :ok, %{changes: changes}
      ids = Enum.map(changes, & &1.id)
      refute n1.id in ids
      assert n2.id in ids
    end

    test "an equal-seq move pair is not dropped when the composite cursor splits it",
         %{socket: socket, user: user, vault: vault} do
      # move_attachment writes TWO rows at ONE seq (#614): the repoint at the
      # new path + the old-path tombstone. Walking the feed one row per page
      # (limit 1) forces a boundary BETWEEN them; a seq-only cursor (seq > seq)
      # would skip the second — a ghost old path survives (#312). The composite
      # cursor {seq, id} continues past the exact row and keeps both.
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "old.png",
          "content_base64" => Base.encode64("bytes"),
          "mime_type" => "image/png"
        })

      {:ok, _} = Attachments.move_attachment(user, vault, "old.png", "new.png")

      rows = catchup_all(socket, 1)
      att_paths = for r <- rows, r.type == :attachment, into: MapSet.new(), do: r.path

      # Both halves of the seq-S pair survive the paged walk.
      assert "new.png" in att_paths
      assert "old.png" in att_paths
      # And every row appears exactly once (no duplicate from a >= overlap).
      ids = Enum.map(rows, & &1.id)
      assert ids == Enum.uniq(ids)
    end
  end

  # Paginate the whole crdt_catchup_since feed one page at a time, threading the
  # composite {cursor_seq, cursor_id} cursor exactly as the plugin does.
  defp catchup_all(socket, limit) do
    Stream.unfold({0, nil}, fn
      :done ->
        nil

      {cursor_seq, cursor_id} ->
        payload =
          %{"cursor_seq" => cursor_seq, "limit" => limit}
          |> then(&if cursor_id, do: Map.put(&1, "cursor_id", cursor_id), else: &1)

        ref = push(socket, "crdt_catchup_since", payload)
        assert_reply ref, :ok, %{changes: changes, has_more: has_more, next_seq: ns, next_id: ni}
        next = if has_more, do: {ns, ni}, else: :done
        {changes, next}
    end)
    |> Enum.flat_map(& &1)
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

      {:ok, other_vault, _} =
        Vaults.register_vault(other_user, "OtherVault", Ecto.UUID.generate())

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

  # #1409: a room is `auto_exit: true` — it dies when its LAST OBSERVER leaves.
  # The channel becomes an observer on first contact and the only thing that
  # ever releases it is the room asking, which happens after `idle_exit_ms`
  # (5 minutes). So a room cannot close early no matter how briefly it was
  # needed: a 2,000-note first sync holds 2,000 rooms for five minutes past
  # their last frame, bounded only by the LRU cap force-evicting them.
  #
  # `crdt_release` is the client saying "done with this note" — the manual
  # close. Interactive editing keeps the 5-minute idle behaviour; a bulk import
  # releases each note the moment it has converged.
  #
  # It is a SEPARATE frame rather than a flag on `crdt_msg` because releasing
  # inside the `crdt_msg` handler would race the STEP2 the client is still
  # waiting for: `relay_frame` is a cast and the room answers observers
  # asynchronously, so unobserving on the way out of a STEP1 can drop the very
  # reply that makes convergence work. Only the client knows the exchange is
  # finished.
  describe "crdt_release" do
    test "releases this channel's observation and lets the room auto_exit", %{
      socket: socket,
      doc_id: doc_id
    } do
      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
      push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(frame)})
      assert_push "crdt_msg", %{"doc_id" => ^doc_id}, 3000

      room = CrdtRegistry.lookup(doc_id)
      assert is_pid(room)
      room_ref = Process.monitor(room)

      ref = push(socket, "crdt_release", %{"doc_id" => doc_id})
      assert_reply ref, :ok, %{}

      # THE point: milliseconds, not the 5-minute idle timer.
      assert_receive {:DOWN, ^room_ref, :process, ^room, _}, 2_000
      assert CrdtRegistry.lookup(doc_id) == nil
    end

    test "the checkpoint still lands — release must not lose the edit", %{
      socket: socket,
      user: user,
      vault: vault,
      doc_id: doc_id
    } do
      # auto_exit -> terminate/2 -> unbind -> checkpoint is what persists the
      # room's doc. Releasing early is only safe because it goes through that
      # same path; a brutal kill here would drop the body.
      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, f1} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
      push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(f1)})
      assert_push "crdt_msg", %{"doc_id" => ^doc_id, "b64" => b64}, 3000
      {:ok, {:sync, {:sync_step2, update}}} = Yex.Sync.message_decode(Base.decode64!(b64))
      :ok = Yex.apply_update(client, update)

      CrdtBridge.text_of(client)
      Yex.Text.insert(Yex.Doc.get_text(client, "content"), 0, "RELEASED-")
      {:ok, edit} = Yex.encode_state_as_update(client)
      {:ok, f2} = Yex.Sync.message_encode({:sync, {:sync_update, edit}})
      push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(f2)})

      ref = push(socket, "crdt_release", %{"doc_id" => doc_id})
      assert_reply ref, :ok, %{}

      assert_note_content_eventually(user, vault, doc_id, "RELEASED-base")
    end

    test "an unknown or unobserved doc_id is a quiet no-op, not an error", %{socket: socket} do
      ref = push(socket, "crdt_release", %{"doc_id" => Ecto.UUID.generate()})
      assert_reply ref, :ok, %{}
    end
  end

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
      # content while NO room is live. The next STEP1 must still serve the body.
      #
      # This is the USER-FACING #1087 guarantee, and it survives the removal of
      # the bind-time content seed: `upsert_note` merges the plaintext INTO the
      # note's persisted CRDT state roomlessly (doc_from_state -> replay_tail ->
      # merge_plaintext_*), so the doc already carries the body by the time the
      # room binds. Nothing has to resurrect `notes.content` here.
      genesis_id = Ecto.UUID.generate()
      ref = push(socket, "crdt_create", %{"doc_id" => genesis_id, "path" => "Notes/g.md"})
      assert_reply ref, :ok, %{doc_id: created_id}

      # Kill the genesis room so the REST write below lands with no live room
      # (deliver_out's live-room push must not be what heals this).
      CrdtRegistry.terminate_room(created_id)

      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{"path" => "Notes/g.md", "content" => "late body"})

      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
      push(socket, "crdt_msg", %{"doc_id" => created_id, "b64" => Base.encode64(frame)})

      assert_push "crdt_msg", %{"doc_id" => ^created_id, "b64" => b64}, 3000
      {:ok, {:sync, {:sync_step2, update}}} = Yex.Sync.message_decode(Base.decode64!(b64))
      :ok = Yex.apply_update(client, update)
      assert CrdtBridge.text_of(client) == "late body"
    end

    test "STEP2 does NOT resurrect notes.content over an empty-projecting snapshot (#1087 class)",
         %{socket: socket, user: user, vault: vault} do
      # Channel-layer twin of the CrdtPersistence test of the same name: the doc
      # is the sole authority, so a row whose crdt_state projects empty serves an
      # EMPTY STEP2 even though `notes.content` is non-empty. The server used to
      # seed from the plaintext row here, which is exactly what made it a third
      # writer of note content.
      #
      # This divergence is only constructible by hand — the write path keeps the
      # two consistent, which is what the sibling test above pins.
      genesis_id = Ecto.UUID.generate()
      ref = push(socket, "crdt_create", %{"doc_id" => genesis_id, "path" => "Notes/diverged.md"})
      assert_reply ref, :ok, %{doc_id: created_id}

      CrdtRegistry.terminate_room(created_id)

      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "Notes/diverged.md",
          "content" => "late body"
        })

      # Hand-wipe the state columns back to the EMPTY genesis snapshot, leaving
      # crdt_state empty while notes.content holds the body.
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
      assert CrdtBridge.text_of(client) == ""
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
      #
      # Isolate THIS warning's line first. `capture_log` is global, so under a
      # loaded suite the capture also holds unrelated concurrent output — the
      # Prometheus aggregator's "Dropping aggregation for bad tag value"
      # warnings arrive in bursts. Splitting the whole capture on the FIRST
      # `[warning]` then landed on one of those, leaving this test's own line —
      # metadata `note_id=...` included — inside `msg`, and the refute below
      # failed on metadata it was never meant to read. Same shared-capture
      # class as #1359.
      msg =
        log
        |> String.split("\n")
        |> Enum.find(&String.contains?(&1, "dropped crdt_msg"))
        |> String.split("[warning]", parts: 2)
        |> List.last()

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
        CrdtRegistry.ensure_started(user.id, vault.id, note.id)

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

      # 4 handshake frames — double the edit override of 2 — all must pass the
      # limiter. Asserted positively (each frame reaches its post-limiter
      # outcome) rather than refuting "rate_limited": a refute with a timeout
      # also passes when the channel is starved and never replies, so it could
      # not tell "not rate limited" from "not run". The two reasons differ
      # because only step1 carries a state vector: <<0, 0, 0>> unwraps to an
      # EMPTY vector, which safe_wire_frame?/1 fails closed on, while step2
      # takes the always-allowed non-step1 path and reaches the absent doc_id.
      for {b64, reason} <- [
            {step1_b64, "implausible_state_vector"},
            {step1_b64, "implausible_state_vector"},
            {step2_b64, "note_not_found"},
            {step2_b64, "note_not_found"}
          ] do
        ref = push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => b64})
        assert_reply ref, :error, %{reason: ^reason}, 3000
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

      # The sibling tests await each reply so the three pushes do not share one
      # window. That is not available HERE: a `<<0, 0, 0>>` frame is the point of
      # this test (it classes as :handshake) and the state-vector guard DROPS it
      # with no reply at all, so the first two are unobservable. The channel
      # processes its mailbox in order, so the third reply still proves all
      # three were seen — the only lever is the window, and 3s was too tight for
      # a loaded sync suite (observed twice: empty mailbox, i.e. the limiter
      # working perfectly and reported as a limiter bug).
      push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => step1_b64})
      push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => step1_b64})
      ref = push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => step1_b64})

      assert_reply ref, :error, %{reason: "rate_limited"}, 10_000
    end

    @tag capture_log: true
    test "crdt_catchup_since shares the handshake budget and is rejected once exhausted",
         %{socket: socket} do
      Application.put_env(:engram, :crdt_hs_rate_limit_override, 2)
      on_exit(fn -> Application.delete_env(:engram, :crdt_hs_rate_limit_override) end)

      # Await each reply rather than firing three and asserting only the last
      # (the sibling per-device test below already does this, for this reason):
      # the three pushes otherwise SHARE one 3s window, so a loaded scheduler
      # makes the assertion fail with an empty mailbox — the limiter working
      # perfectly, reported as a limiter bug. Observed twice in this file.
      ref1 = push(socket, "crdt_catchup_since", %{})
      assert_reply ref1, :ok, _, 3000
      ref2 = push(socket, "crdt_catchup_since", %{})
      assert_reply ref2, :ok, _, 3000
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

      # Await each reply rather than firing three and asserting only the last
      # (the sibling per-device test below already does this, for this reason):
      # the three pushes otherwise SHARE one 3s window, so a loaded scheduler
      # makes the assertion fail with an empty mailbox — the limiter working
      # perfectly, reported as a limiter bug. Observed twice in this file.
      ref1 = push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      assert_reply ref1, :error, %{reason: "note_not_found"}, 3000
      ref2 = push(socket, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      assert_reply ref2, :error, %{reason: "note_not_found"}, 3000
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

      # Await each reply (see the user-scoped test below for why): the two
      # allowed frames are asserted ALLOWED, and each frame gets its own
      # timeout instead of all three sharing one 3s window.
      ref_a1 = push(sock_a, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      assert_reply ref_a1, :error, %{reason: "note_not_found"}, 3000
      ref_a2 = push(sock_a, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      assert_reply ref_a2, :error, %{reason: "note_not_found"}, 3000
      ref_a = push(sock_a, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      assert_reply ref_a, :error, %{reason: "rate_limited"}, 3000

      # Device B — SAME user, different device — has a fresh budget: its first
      # frame must NOT be rate-limited (a per-user bucket would already be spent).
      {:ok, _, sock_b} =
        user_socket(user)
        |> Phoenix.Socket.assign(:device_id, "dev-b")
        |> subscribe_and_join(EngramWeb.CrdtChannel, topic, %{"crdt_proto" => 2})

      Sandbox.allow(Repo, self(), sock_b.channel_pid)

      # Positive assertion, not a refute: device B's frame must be seen to be
      # ALLOWED (it passes check_rate and reaches ensure_room, which answers
      # note_not_found for the absent doc_id). A refute with a timeout passes
      # vacuously when the channel is starved and replies nothing at all.
      ref_b = push(sock_b, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      assert_reply ref_b, :error, %{reason: "note_not_found"}, 3000
    end

    @tag capture_log: true
    test "buckets are user-scoped: a forged device_id cannot drain another user's budget",
         %{socket: socket, user: user, other_user: other_user} do
      tiny_b64 = Base.encode64(<<0>>)
      absent = Ecto.UUID.generate()

      # Attacker (other_user) forges device_id to the VICTIM's user id, trying to
      # land in the victim's rate bucket, and hammers from their OWN vault.
      insert(:user_limit_override, user: other_user, key: "vaults_cap", value: %{"v" => -1})
      {:ok, atk_vault, _} = Vaults.register_vault(other_user, "AtkVault", Ecto.UUID.generate())

      {:ok, _, atk_sock} =
        user_socket(other_user)
        |> Phoenix.Socket.assign(:device_id, to_string(user.id))
        |> subscribe_and_join(
          EngramWeb.CrdtChannel,
          "crdt:#{other_user.id}:#{atk_vault.id}",
          %{"crdt_proto" => 2}
        )

      Sandbox.allow(Repo, self(), atk_sock.channel_pid)

      # Attacker exhausts its OWN (user-scoped) bucket (override = 2). Each
      # reply is awaited before the next push: the two allowed frames must be
      # seen to be ALLOWED (they reach ensure_room and come back note_not_found
      # for the absent doc_id), which the previous fire-and-forget form never
      # checked — an off-by-one that rejected frame 1 still left frame 3
      # rate_limited and the test green. Awaiting also gives each frame its own
      # timeout budget instead of requiring all three inside one 3s window,
      # where a scheduler-starved channel produced an empty mailbox and a flake.
      ref1 = push(atk_sock, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      assert_reply ref1, :error, %{reason: "note_not_found"}, 3000
      ref2 = push(atk_sock, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      assert_reply ref2, :error, %{reason: "note_not_found"}, 3000
      ref_atk = push(atk_sock, "crdt_msg", %{"doc_id" => absent, "b64" => tiny_b64})
      assert_reply ref_atk, :error, %{reason: "rate_limited"}, 3000

      # The victim's bucket is untouched — the server-derived user_id prefix
      # means the forged device_id landed in the attacker's own tenant. Assert
      # the frame was ALLOWED (note_not_found: it passed check_rate and reached
      # ensure_room) rather than refuting a rate_limited reply: a refute with a
      # timeout passes vacuously when the channel is starved and never replies
      # at all, so it could not distinguish "not rate limited" from "not run".
      victim_absent = Ecto.UUID.generate()
      ref_victim = push(socket, "crdt_msg", %{"doc_id" => victim_absent, "b64" => tiny_b64})
      assert_reply ref_victim, :error, %{reason: "note_not_found"}, 3000
    end
  end

  # ---------------------------------------------------------------------------
  # crdt_create rate lane — genesis size gate (#1409)
  #
  # Mirrors "a LARGE STEP2 pays the edit budget" above, for crdt_create's own
  # b64: small (or absent) rides :handshake, a genesis frame over
  # @hs_genesis_max_b64 pays the :edit budget instead — same override=2 setup
  # so the edit lane's ceiling is cheap to exhaust in a test.
  # ---------------------------------------------------------------------------

  describe "crdt_create rate lane (genesis size gate)" do
    setup do
      Application.put_env(:engram, :crdt_msg_rate_limit_override, 2)
      # Also bound the HANDSHAKE lane to 2 (#1409). Without this, "a small (or
      # absent) genesis body stays on the handshake lane" below would pass
      # vacuously even if the size gate were deleted entirely: with
      # genesis_create_class/1 hardcoded to :handshake, the two "oversized"
      # pushes would land on the (otherwise near-unbounded) handshake lane
      # too and never exhaust anything, so the small-body probe would succeed
      # either way. Bounding both lanes to the same size means a classifier
      # that misroutes the oversized pushes onto :handshake instead of :edit
      # spends the SAME budget the small body then needs, so the probe can
      # actually go the other way and prove the routing is real.
      Application.put_env(:engram, :crdt_hs_rate_limit_override, 2)
      EngramWeb.RateLimiter.reset_buckets!()

      on_exit(fn ->
        Application.delete_env(:engram, :crdt_msg_rate_limit_override)
        Application.delete_env(:engram, :crdt_hs_rate_limit_override)
        EngramWeb.RateLimiter.reset_buckets!()
      end)
    end

    test "a small (or absent) genesis body stays on the handshake lane", %{socket: socket} do
      # Exhaust the EDIT lane (override = 2) FIRST, with oversized creates —
      # which DO count against it (see the next test), and must NOT count
      # against the (also override = 2) handshake lane. A small-body create
      # afterwards succeeding is then real evidence it rides a separate,
      # still-full lane: if genesis_create_class/1 were hardcoded to
      # :handshake, these two "oversized" pushes would instead spend the
      # handshake budget themselves, and the small-body probe below would be
      # denied (see the sabotage proof in the #1409 report).
      oversized_b64 = Base.encode64(:binary.copy(<<0>>, 25_000))

      push(socket, "crdt_create", %{
        "doc_id" => Ecto.UUID.generate(),
        "path" => "Notes/o1.md",
        "b64" => oversized_b64
      })

      push(socket, "crdt_create", %{
        "doc_id" => Ecto.UUID.generate(),
        "path" => "Notes/o2.md",
        "b64" => oversized_b64
      })

      # The edit lane is now spent, and the handshake lane hasn't been
      # touched. A THIRD create, this time with a small b64 genesis seed,
      # must still succeed — proving small-body creates ride the separate,
      # still-full handshake lane rather than the exhausted edit lane.
      id = Ecto.UUID.generate()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/n3.md",
          "b64" => frame_for_content("small body")
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: true}, 3000
    end

    test "a genesis body over the size gate pays the edit budget", %{socket: socket} do
      # Same shape as "a LARGE STEP2 pays the edit budget": not a valid Yjs
      # frame, just oversized. genesis_create_class/1 classifies on byte_size
      # alone, before any decode is attempted, so this is enough to exercise
      # the rate lane without needing a well-formed frame.
      oversized_b64 = Base.encode64(:binary.copy(<<0>>, 25_000))
      assert byte_size(oversized_b64) > 32_768

      push(socket, "crdt_create", %{
        "doc_id" => Ecto.UUID.generate(),
        "path" => "Notes/o1.md",
        "b64" => oversized_b64
      })

      push(socket, "crdt_create", %{
        "doc_id" => Ecto.UUID.generate(),
        "path" => "Notes/o2.md",
        "b64" => oversized_b64
      })

      # The edit budget (2) is now spent — a third oversized create is denied,
      # same as a third large STEP2 crdt_msg would be.
      ref =
        push(socket, "crdt_create", %{
          "doc_id" => Ecto.UUID.generate(),
          "path" => "Notes/o3.md",
          "b64" => oversized_b64
        })

      assert_reply ref, :error, %{reason: "rate_limited"}, 3000
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

  # Append a durable tail-log row for `note_id` carrying `text` on its own Yjs
  # lineage — what `CrdtPersistence.update_v1/4` writes for one client delta,
  # without needing a live room to produce it.
  defp insert_tail_row(user, vault, note_id, text) do
    doc = CrdtBridge.new_doc()
    :ok = CrdtBridge.ingest_plaintext(doc, text)
    {:ok, update} = Yex.encode_state_as_update(doc)
    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(update, user, note_id)

    {:ok, row} =
      Repo.with_tenant(user.id, fn ->
        %CrdtUpdateLog{}
        |> CrdtUpdateLog.changeset(%{
          note_id: note_id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: nonce
        })
        |> Repo.insert!()
      end)

    row
  end

  # A base64 Yjs update that, applied to a fresh empty doc, ingests `content`
  # as full note plaintext — i.e. the frame a client sends as `crdt_create`'s
  # `b64` genesis payload for a brand-new note.
  defp frame_for_content(content) do
    doc = CrdtBridge.new_doc()
    :ok = CrdtBridge.ingest_plaintext(doc, content)
    {:ok, update} = Yex.encode_state_as_update(doc)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_update, update}})
    Base.encode64(frame)
  end

  # Poll get_note_by_id until the row's decrypted content matches (or flunk).
  # `deadline` (absolute monotonic ms, as `wait_until/2` takes) defaults to
  # `wait_until/2`'s own 500ms when omitted.
  defp assert_note_content_eventually(user, vault, note_id, content, deadline \\ nil) do
    wait_until(
      fn ->
        case Notes.get_note_by_id(user, vault, note_id) do
          {:ok, note} -> note.content == content
          _ -> false
        end
      end,
      deadline
    )
  end

  defp wait_until(condition, deadline \\ nil) do
    now = System.monotonic_time(:millisecond)
    deadline = deadline || now + 500
    do_wait_until(condition, deadline, deadline - now)
  end

  # `budget_ms` is captured once, in wait_until/2, from the deadline actually
  # in effect (default 500ms or a caller-supplied one) — so the flunk message
  # below reports what this call was really given, not a hardcoded default.
  defp do_wait_until(condition, deadline, budget_ms) do
    if condition.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk("wait_until: condition never became true within #{budget_ms}ms")
      else
        Process.sleep(10)
        do_wait_until(condition, deadline, budget_ms)
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
