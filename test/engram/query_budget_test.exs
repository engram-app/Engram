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
  @budgets %{
    "mcp get_notes" => 6,
    "mcp write_note update" => 16,
    "mcp append_to_note" => 16,
    "mcp edit_note" => 16,
    "mcp delete_note" => 14,
    "GET sync/manifest" => 11,
    "GET notes/*path" => 11,
    "POST notes update" => 28,
    "POST notes create" => 34,
    "POST notes/append" => 22,
    "POST notes/rename" => 46,
    "DELETE notes/*path" => 18,
    "GET /api/bootstrap" => 22,
    "GET folders" => 10,
    "GET tags" => 5,
    # Task 7b. The old "crdt_msg update" (40) was a keystroke (7) plus a
    # checkpoint tick (33) that a timer happened to fire inside the window.
    # Split, and the tick is driven by hand so both counts are exact.
    # delta: the one-statement append in its tenant txn.
    "CRDT delta" => 5,
    # tick: one checkpoint txn (11: note read, next_seq, note write, tail
    # prune, revisions read + 2 inserts) plus the dispatcher job insert and
    # Oban's pg_notify.
    "CRDT checkpoint tick" => 13,
    # idle (was 48): bind 6 + delta 5 + the exit checkpoint 13.
    "CRDT crdt_doc_update idle" => 24,
    # open (was 25 at bee71923): the channel's note_in_vault? 5 + bind 6 +
    # the announce's path read 5.
    "CRDT room open" => 16
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
  defp measure(name, warm, fun) do
    Engram.DataCase.clear_request_caches()
    if warm == true, do: fun.(), else: warm.()
    {result, qs} = QueryRecorder.record(fun)
    budget = Map.fetch!(@budgets, name)
    report = "#{name}: #{length(qs)} queries (budget #{budget})\n" <> QueryRecorder.format(qs)

    assert length(qs) == budget, report
    result
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
      measure("POST notes/rename", fn -> get(conn, "/api/sync/manifest") end, fn ->
        conn
        |> post("/api/notes/rename", %{old_path: "Home/Third.md", new_path: "Home/Third2.md"})
        |> ok!()
      end)
    end

    test "DELETE notes/*path", %{conn: conn} do
      measure("DELETE notes/*path", fn -> get(conn, "/api/sync/manifest") end, fn ->
        conn |> delete("/api/notes/Home/Third.md") |> ok!()
      end)
    end

    test "GET /api/bootstrap", %{conn: conn} do
      measure("GET /api/bootstrap", true, fn -> conn |> get("/api/bootstrap") |> ok!() end)
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
