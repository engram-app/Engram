defmodule Engram.QueryBudgetTest do
  # Not async: telemetry handler is global and counts every process's queries.
  use EngramWeb.ConnCase, async: false

  import Phoenix.ChannelTest,
    only: [subscribe_and_join: 4, socket: 3, assert_reply: 4, assert_push: 3]

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Notes.CrdtBridge
  alias Engram.QueryRecorder

  # Path => max queries with a warm cache. Lowered by Tasks 5-8 toward the
  # spec §7 targets; Task 10 asserts the final numbers. Non-GET paths (MCP is
  # always POST) carry +1 since the Task 5 fix round: RotationLockCheck
  # re-reads the rotation lock from the DB for writes, because the request's
  # user now comes from the :user cache. Task 6: each MCP tool call runs in ONE
  # tenant transaction, so the tool's separate with_tenant blocks merge (4 each)
  # and Oban's own begin/commit pairs nest into it. Task 7: MCP read-modify-
  # writes read the note once (locked) and replay the tail once; the tail's
  # count(*) diagnostic and deliver-out's users + notes re-read are gone.
  # Fix round 1: read-modify-writes are optimistic (unlocked read, locked
  # re-read before the write: +1), and REST append runs in one transaction.
  # Task 7b fix round: the read-modify-writes read the note and its tail in
  # one statement (-1).
  # Task 8: OriginStats.record is an ETS counter bumped in memory and flushed
  # by a timer (-1 on every MCP tools/call: the per-call upsert is gone).
  # Task 10a: a top-level with_tenant is 3 round trips, not 4 (BEGIN,
  # tenant_enter, COMMIT; the COMMIT resets tenant + role, so tenant_exit is
  # gone). Every path drops by its number of tenant transactions.
  # Task 10b: note_json's links read uses the request's (cached) user, not a
  # fresh users row (-1 on every REST path that renders a note). GET, upsert
  # and append run their DB work and note_json's links read in ONE tenant
  # transaction, so upsert's job inserts nest in it instead of each opening
  # its own (update -9, create -10, append -3, GET -3). The manifest's
  # change_seq read and GET folders' two reads share one transaction (-3).
  # delete_note finds and tombstones the note in one transaction (REST -3)
  # and reports whether it existed, so MCP no longer probes first (-1).
  # EmbedNote's max-wait clamp reads the burst start off the job Oban's
  # unique check returns, not a SELECT of its own (-1 per content write).
  # A read-only MCP tool trusts the cached user's rotation lock, as a GET
  # does (-1). Bootstrap answers from caches: the onboarding profile off the
  # cached user, the vault count off the cached vault list, and new caches for
  # onboarding actions, the live note count and vault content counts (-18).
  # DELETE and rename now warm up with a delete / rename of another note, so
  # the per-user plan-limit lookup they make is warm as in prod (-1 each: a
  # measurement fix, no code change). Task 10b fix round 1: bootstrap runs
  # its DB work in one tenant block (cold 29 -> 20, warm 0 -> 3: the block
  # opens even when every loader hits).
  @budgets %{
    # Read target 5. begin, tenant_enter, the note, commit.
    "mcp get_notes" => 4,
    # Write target 12; floor 14, each kept query required:
    #  1 rotation lock: a write reads it fresh from the DB (RotationGate).
    #  2, 3, 14 begin / tenant_enter / commit: the one tenant txn (RLS).
    #  4 note row: the write's base. 5 crdt tail: the merge replays it.
    #  6 vault change_seq bump: the seq the write is stamped with.
    #  7 note UPDATE: the write itself.
    #  8, 9 open revision read + touch: the revision row (history).
    #  10, 11 EmbedNote unique check + scheduled_at replace: the debounce.
    #  12, 13 ExtractNoteLinks / FinalizeRevision unique checks: Oban dedup.
    "mcp write_note update" => 14,
    # As write_note, with 4 the unlocked read and 5 the locked re-read of the
    # optimistic read-modify-write (Task 7 ruling F1) instead of the tail read
    # (the tail rides in the read statement).
    "mcp append_to_note" => 14,
    "mcp edit_note" => 14,
    # rotation lock, begin, enter, the note row (found once), seq bump,
    # tombstone, usage_meters, two job inserts + their pg_notify, commit.
    "mcp delete_note" => 12,
    # Read target 5; floor 6: begin, enter, change_seq (it decides whether the
    # rows are read at all), notes rows, attachments rows, commit.
    "GET sync/manifest" => 6,
    "GET notes/*path" => 5,
    # As "mcp write_note update" (1-13), plus the response's note_links read.
    "POST notes update" => 15,
    # Write target 12; floor 19: rotation lock, begin, enter, path lookup,
    # notes cap (usage_meters), path-collision probe, seq bump, INSERT, the
    # inserted row's re-read, usage_meters increment, EmbedNote and
    # ExtractNoteLinks unique check + insert (4), RebindNoteLinks insert +
    # pg_notify, the vault_populated probe, the response's links read, commit.
    "POST notes create" => 19,
    # As "mcp append_to_note" (1-13), plus the response's note_links read.
    "POST notes/append" => 15,
    # Not consolidated in Task 10b (no query-classify item; a rename claims its
    # path in the vault index room, which must commit before the row txn):
    #  1 rotation lock. 2-5 claim validation txn (note ids at the paths).
    #  6-12 index room fold (snapshot, tail, tail ids, snapshot upsert).
    #  13-24 rename txn (2 note reads, seq, UPDATE, tombstone INSERT, two job
    #  inserts + pg_notify). 25-30 post-commit jobs (one unique, own txn).
    #  31-35 idle-room fanout (fresh users row + note read). 36-39 links txn.
    "POST notes/rename" => 39,
    # rotation lock, begin, enter, the note row, seq bump, tombstone,
    # usage_meters, two job inserts + their pg_notify, commit.
    "DELETE notes/*path" => 12,
    # Warm: every loader is a cache hit; what remains is the controller's one
    # tenant block (begin, enter, commit), opened unconditionally (fix round 1
    # ruling: bootstrap's DB work runs in ONE block).
    "GET /api/bootstrap" => 3,
    # Bootstrap target 5; floor 22. Auth plug, before the controller (its own
    # cached lookups, cold after 60 s): 1-6 API key lookup (BEGIN, lookup role,
    # key row, role reset needed by 5, key's vault scope, COMMIT), 7 users row,
    # 8-11 subscription in its tenant block. Controller, one block: 12, 13, 22
    # begin / enter / commit; 14, 16, 19 vault list, read by has_vault?, the
    # vault count and the vaults payload (was 20: a load inside a transaction
    # is now stored only after commit, so the block's later reads miss too);
    # 15 onboarding actions; 17 indexed_notes_cap override (the cap decides
    # whether to count at all); 18 live note count; 20, 21 per-vault note and
    # attachment counts.
    "GET /api/bootstrap cold" => 22,
    "GET folders" => 5,
    "GET tags" => 4,
    # Task 7b. The old "crdt_msg update" (40) was a keystroke (7) plus a
    # checkpoint tick (33) that a timer happened to fire inside the window.
    # Split, and the tick is driven by hand so both counts are exact.
    # delta: the one-statement append in its tenant txn.
    "CRDT delta" => 4,
    # tick: one checkpoint txn (10: BEGIN, tenant_enter, note read, next_seq,
    # note write, tail prune, revisions read + 2 inserts, COMMIT) plus the
    # dispatcher job insert and Oban's pg_notify.
    "CRDT checkpoint tick" => 12,
    # idle (was 48): bind 5 + delta 4 + the exit checkpoint 12.
    "CRDT crdt_doc_update idle" => 21,
    # open (was 25 at bee71923): the channel's note_in_vault? 4 + bind 5 +
    # the announce's path read 4.
    "CRDT room open" => 13
  }

  setup %{conn: conn} do
    EngramWeb.RateLimiter.reset_buckets!()
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")

    notes =
      for path <- ["Work/Existing.md", "Work/Other.md", "Home/Third.md", "p.md", "idle.md"] do
        {:ok, note} =
          Engram.Notes.upsert_note(
            user,
            vault,
            %{
              "path" => path,
              "content" => "# #{path}\n\n## Body\n\nbody [[Other]]\n",
              "mtime" => 1_000.0
            },
            actor: "api"
          )

        {path, note}
      end
      |> Map.new()

    %{conn: authed, user: user, vault: vault, notes: notes}
  end

  # The request-lookup caches (`Engram.Cache`). Every count below is taken with
  # them in ONE stated state: cleared, then warmed by `warm` (the measured call
  # itself when `true`), as on a long-lived prod node. The file is async: false,
  # so no other test's setup can clear them between the warm-up and the
  # measurement.
  #
  # `tenant_exit_sandbox` is dropped from the count: the sandbox runs every
  # transaction as a savepoint, so `with_tenant` must reset tenant + role by
  # hand there, but in prod a top-level block's COMMIT does it for free (Task
  # 10a, pinned on a real pool by `Engram.Repo.TenantTxnCommitResetTest`). A
  # `tenant_exit` from a block nested in a plain transaction is real and
  # still counts.
  defp measure(name, warm, fun) do
    Engram.DataCase.clear_request_caches()

    cond do
      warm == :cold ->
        fun.()
        clear_short_ttl_caches()

      warm == true ->
        fun.()

      true ->
        warm.()
    end

    {result, recorded} = QueryRecorder.record(fun)
    qs = Enum.reject(recorded, &(&1.source == "tenant_exit_sandbox"))
    budget = Map.fetch!(@budgets, name)
    report = "#{name}: #{length(qs)} queries (budget #{budget})\n" <> QueryRecorder.format(qs)

    assert length(qs) == budget, report
    result
  end

  # Every cache with a TTL of 60 s or less: what a page load more than 60 s
  # after the last one finds empty on a long-lived node. The hour-plus caches
  # (DEK, plan, entitlement, terms, legal) stay warm, as they would be.
  defp clear_short_ttl_caches do
    Engram.DataCase.clear_request_caches()
    for c <- [:billing_override, :onboarding_gate], do: Engram.Cache.clear_local(c)
  end

  defp tool_ok!(conn) do
    assert conn.status == 200
    refute json_response(conn, 200)["result"]["isError"]
    conn
  end

  describe "MCP" do
    test "mcp get_notes", %{conn: conn} do
      measure("mcp get_notes", true, fn ->
        conn |> call_tool("get_notes", %{"paths" => ["Work/Existing.md"]}) |> tool_ok!()
      end)
    end

    test "mcp write_note update", %{conn: conn} do
      call_tool(conn, "write_note", %{"path" => "Work/New.md", "content" => "# New\n\nhello\n"})

      measure("mcp write_note update", true, fn ->
        conn
        |> call_tool("write_note", %{
          "path" => "Work/New.md",
          "content" => "# New\n\nv#{System.unique_integer()}\n"
        })
        |> tool_ok!()
      end)
    end

    test "mcp append_to_note", %{conn: conn} do
      measure("mcp append_to_note", true, fn ->
        conn
        |> call_tool("append_to_note", %{"path" => "Work/Existing.md", "text" => "appended"})
        |> tool_ok!()
      end)
    end

    test "mcp edit_note", %{conn: conn} do
      measure("mcp edit_note", true, fn ->
        conn
        |> call_tool("edit_note", %{
          "path" => "Work/Existing.md",
          "mode" => "insert_section",
          "heading" => "Body",
          "content" => "x"
        })
        |> tool_ok!()
      end)
    end

    test "mcp delete_note", %{conn: conn} do
      call_tool(conn, "write_note", %{"path" => "Work/New.md", "content" => "# New\n"})

      # Warm-up deletes another note; the measured call is the same path.
      warm = fn -> call_tool(conn, "delete_note", %{"path" => "Work/Other.md"}) end

      measure("mcp delete_note", warm, fn ->
        conn |> call_tool("delete_note", %{"path" => "Work/New.md"}) |> tool_ok!()
      end)
    end
  end

  describe "REST" do
    defp ok!(conn) do
      assert conn.status == 200
      conn
    end

    test "GET sync/manifest", %{conn: conn} do
      measure("GET sync/manifest", true, fn -> conn |> get("/api/sync/manifest") |> ok!() end)
    end

    test "GET notes/*path", %{conn: conn} do
      measure("GET notes/*path", true, fn ->
        conn |> get("/api/notes/Work/Existing.md") |> ok!()
      end)
    end

    test "POST notes update", %{conn: conn} do
      measure("POST notes update", true, fn ->
        conn
        |> post("/api/notes", %{
          path: "Work/Existing.md",
          content: "# E\n\nv#{System.unique_integer()}",
          mtime: 2_000.0
        })
        |> ok!()
      end)
    end

    test "POST notes create", %{conn: conn} do
      measure("POST notes create", true, fn ->
        conn
        |> post("/api/notes", %{
          path: "Work/New#{System.unique_integer([:positive])}.md",
          content: "# N\n",
          mtime: 2_000.0
        })
        |> ok!()
      end)
    end

    test "POST notes/append", %{conn: conn} do
      measure("POST notes/append", true, fn ->
        conn |> post("/api/notes/append", %{path: "Work/Other.md", text: "more"}) |> ok!()
      end)
    end

    test "POST notes/rename", %{conn: conn} do
      # Warm-up renames another note: the request's per-user lookups (e.g. the
      # plan limit the rename checks) are then warm, as on a long-lived node.
      warm = fn ->
        post(conn, "/api/notes/rename", %{old_path: "Work/Other.md", new_path: "Work/Other2.md"})
      end

      measure("POST notes/rename", warm, fn ->
        conn
        |> post("/api/notes/rename", %{old_path: "Home/Third.md", new_path: "Home/Third2.md"})
        |> ok!()
      end)
    end

    test "DELETE notes/*path", %{conn: conn} do
      # Warm-up deletes another note (see the rename test).
      measure("DELETE notes/*path", fn -> delete(conn, "/api/notes/Work/Other.md") end, fn ->
        conn |> delete("/api/notes/Home/Third.md") |> ok!()
      end)
    end

    test "GET /api/bootstrap", %{conn: conn} do
      measure("GET /api/bootstrap", true, fn -> conn |> get("/api/bootstrap") |> ok!() end)
    end

    # Warmed once, then every 60 s-TTL cache cleared: the same user's next
    # page load more than 60 s later (see clear_short_ttl_caches/0).
    test "GET /api/bootstrap cold", %{conn: conn} do
      measure("GET /api/bootstrap cold", :cold, fn -> conn |> get("/api/bootstrap") |> ok!() end)
    end

    test "GET folders", %{conn: conn} do
      measure("GET folders", true, fn -> conn |> get("/api/folders") |> ok!() end)
    end

    test "GET tags", %{conn: conn} do
      measure("GET tags", true, fn -> conn |> get("/api/tags") |> ok!() end)
    end
  end

  describe "CRDT channel" do
    # Plug.Conn also exports push/3, so go through the module.
    defp chan_push(socket, event, payload), do: Phoenix.ChannelTest.push(socket, event, payload)

    defp join(user, vault) do
      {:ok, _, joined} =
        subscribe_and_join(
          socket(EngramWeb.UserSocket, "user_#{user.id}", %{
            current_user: user,
            current_api_key: nil
          }),
          EngramWeb.CrdtChannel,
          "crdt:#{user.id}:#{vault.id}",
          %{"crdt_proto" => 2}
        )

      Sandbox.allow(Engram.Repo, self(), joined.channel_pid)
      joined
    end

    defp delta_frame(socket, doc_id, prefix) do
      ref = chan_push(socket, "crdt_doc_state", %{"doc_id" => doc_id})
      assert_reply ref, :ok, %{b64: b64}, 10_000
      {:ok, doc} = CrdtBridge.doc_from_state(Base.decode64!(b64))
      {:ok, sv} = Yex.encode_state_vector(doc)
      Yex.Text.insert(Yex.Doc.get_text(doc, "content"), 0, prefix)
      {:ok, update} = Yex.encode_state_as_update(doc, sv)
      {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_update, update}})
      {doc, frame}
    end

    # The room's own cached lookups, as a resident room on a warm node has them:
    # the user (bind, checkpoint) and its subscription (the history gate).
    defp warm_room_lookups(user) do
      Engram.Accounts.get_user(user.id)
      Engram.Billing.get_subscription(user)
    end

    # No timer-driven checkpoint lands in a measured window: the tick test
    # fires it by hand. Read by the timer at room start.
    setup do
      prev = Application.get_env(:engram, Engram.Notes.CrdtCheckpointTimer, [])
      on_exit(fn -> Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer, prev) end)

      Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer,
        settle_ms: 600_000,
        ceiling_ms: 600_000,
        eager_ms: 600_000
      )
    end

    defp step1(socket, doc_id) do
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(CrdtBridge.new_doc())
      {:ok, step1} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
      chan_push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(step1)})
      assert_push "crdt_msg", %{"doc_id" => _}, 3000
    end

    defp timer_of(room) do
      me = self()

      :ok =
        Yex.Sync.SharedDoc.update_doc(room, fn _ ->
          send(me, {:timer, Process.get(:crdt_timer_pid)})
        end)

      assert_receive {:timer, pid} when is_pid(pid)
      pid
    end

    defp await_no_room(note_id, attempts \\ 300) do
      cond do
        is_nil(Engram.Notes.CrdtRegistry.lookup(note_id)) -> :ok
        attempts == 0 -> flunk("room never exited")
        true -> Process.sleep(10) && await_no_room(note_id, attempts - 1)
      end
    end

    # A keystroke on a resident room: the room's tail append, acked after it.
    test "CRDT delta", %{user: user, vault: vault, notes: notes} do
      note = notes["p.md"]
      _ = join(user, vault)
      socket = join(user, vault)
      {_, warm_frame} = delta_frame(socket, note.id, "W-")
      {_, frame} = delta_frame(socket, note.id, "A-")
      step1(socket, note.id)

      warm = fn ->
        warm_room_lookups(user)

        ref =
          chan_push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => Base.encode64(warm_frame)})

        assert_reply ref, :ok, _, 3000
      end

      measure("CRDT delta", warm, fn ->
        ref = chan_push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => Base.encode64(frame)})
        assert_reply ref, :ok, _, 3000
      end)
    end

    # The room's debounced checkpoint, fired by hand after an edit.
    test "CRDT checkpoint tick", %{user: user, vault: vault, notes: notes} do
      note = notes["p.md"]
      _ = join(user, vault)
      socket = join(user, vault)
      {_, frame} = delta_frame(socket, note.id, "A-")
      step1(socket, note.id)
      ref = chan_push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => Base.encode64(frame)})
      assert_reply ref, :ok, _, 3000
      timer = timer_of(Engram.Notes.CrdtRegistry.lookup(note.id))

      measure("CRDT checkpoint tick", fn -> warm_room_lookups(user) end, fn ->
        send(timer, :tick)
        :sys.get_state(timer)
      end)
    end

    # A room-free write: a room starts for it, appends, checkpoints and exits.
    test "CRDT crdt_doc_update idle", %{user: user, vault: vault, notes: notes} do
      idle = notes["idle.md"]
      _ = join(user, vault)
      socket = join(user, vault)
      {_, frame} = delta_frame(socket, idle.id, "B-")

      measure("CRDT crdt_doc_update idle", fn -> warm_room_lookups(user) end, fn ->
        ref =
          chan_push(socket, "crdt_doc_update", %{
            "doc_id" => idle.id,
            "b64" => Base.encode64(frame)
          })

        assert_reply ref, :ok, _, 3000
        await_no_room(idle.id)
      end)
    end

    # A read-only open: the handshake that starts a room on an existing note.
    test "CRDT room open", %{user: user, vault: vault, notes: notes} do
      _ = join(user, vault)
      socket = join(user, vault)

      measure("CRDT room open", fn -> warm_room_lookups(user) end, fn ->
        step1(socket, notes["Work/Other.md"].id)
      end)
    end
  end
end
