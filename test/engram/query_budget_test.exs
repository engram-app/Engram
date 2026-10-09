defmodule Engram.QueryBudgetTest do
  # Not async: telemetry handler is global and counts every process's queries.
  use EngramWeb.ConnCase, async: false

  import Phoenix.ChannelTest,
    only: [subscribe_and_join: 4, socket: 3, assert_reply: 4, assert_push: 3]

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Notes.CrdtBridge
  alias Engram.QueryRecorder

  # Path => max queries with a warm cache. Lowered by Tasks 5-8 toward the
  # spec §7 targets; Task 10 asserts the final numbers.
  @budgets %{
    "mcp get_notes" => 23,
    "mcp write_note update" => 46,
    "mcp append_to_note" => 62,
    "mcp edit_note" => 57,
    "mcp delete_note" => 39,
    "GET sync/manifest" => 28,
    "GET notes/*path" => 28,
    "POST notes update" => 51,
    "POST notes create" => 56,
    "POST notes/append" => 62,
    "POST notes/rename" => 62,
    "DELETE notes/*path" => 34,
    "GET /api/bootstrap" => 44,
    "GET folders" => 27,
    "GET tags" => 22,
    "CRDT crdt_msg update" => 47,
    "CRDT crdt_doc_update idle" => 55
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

  # One warm-up call (fills caches, as on a long-lived prod node), then the
  # measured call. Returns the measured call's result after asserting the budget.
  defp measure(name, warm_up, fun) do
    if warm_up, do: fun.()
    {result, qs} = QueryRecorder.record(fun)
    budget = Map.fetch!(@budgets, name)

    assert length(qs) <= budget,
           "#{name}: #{length(qs)} queries (budget #{budget})\n" <> QueryRecorder.format(qs)

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
      # Warm-up deletes the note; the measured call is the same path as on a warm node.
      call_tool(conn, "delete_note", %{"path" => "Work/Other.md"})

      measure("mcp delete_note", false, fn ->
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
      get(conn, "/api/sync/manifest")

      measure("POST notes/rename", false, fn ->
        conn
        |> post("/api/notes/rename", %{old_path: "Home/Third.md", new_path: "Home/Third2.md"})
        |> ok!()
      end)
    end

    test "DELETE notes/*path", %{conn: conn} do
      get(conn, "/api/sync/manifest")

      measure("DELETE notes/*path", false, fn ->
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

    test "CRDT crdt_msg update", %{user: user, vault: vault, notes: notes} do
      note = notes["p.md"]
      _ = join(user, vault)
      socket = join(user, vault)
      {_, frame} = delta_frame(socket, note.id, "A-")

      # Handshake first so the room is resident, as in prod.
      client = CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
      {:ok, step1} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
      chan_push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => Base.encode64(step1)})
      assert_push "crdt_msg", %{"doc_id" => _}, 3000

      measure("CRDT crdt_msg update", false, fn ->
        chan_push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => Base.encode64(frame)})
        Process.sleep(500)
      end)
    end

    test "CRDT crdt_doc_update idle", %{user: user, vault: vault, notes: notes} do
      idle = notes["idle.md"]
      _ = join(user, vault)
      socket = join(user, vault)
      {_, frame} = delta_frame(socket, idle.id, "B-")

      measure("CRDT crdt_doc_update idle", false, fn ->
        ref =
          chan_push(socket, "crdt_doc_update", %{
            "doc_id" => idle.id,
            "b64" => Base.encode64(frame)
          })

        assert_reply ref, :ok, _, 3000
        Process.sleep(500)
      end)
    end
  end
end
