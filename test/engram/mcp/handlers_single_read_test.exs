defmodule Engram.MCP.HandlersSingleReadTest do
  # Not async: QueryRecorder's telemetry handler is global.
  use EngramWeb.ConnCase, async: false

  alias Engram.Notes.CrdtBridge
  alias Engram.Notes.CrdtRegistry
  alias Engram.QueryRecorder

  setup %{conn: conn} do
    EngramWeb.RateLimiter.reset_buckets!()
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Single Read", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)

    {:ok, _} =
      Engram.Notes.upsert_note(
        user,
        vault,
        %{"path" => "a.md", "content" => "# A\n\n## Body\n\nbody text\n", "mtime" => 1.0},
        actor: "api"
      )

    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user, vault: vault}
  end

  defp tool_ok!(conn) do
    assert conn.status == 200
    body = json_response(conn, 200)
    refute body["result"]["isError"], inspect(body)
    conn
  end

  defp selects(qs, source),
    do: Enum.filter(qs, &(&1.source == source and String.starts_with?(&1.sql, "SELECT")))

  defp assert_single_read(qs) do
    report = QueryRecorder.format(qs)
    assert length(selects(qs, "notes")) == 1, "notes read more than once:\n" <> report
    assert length(selects(qs, "crdt_update_log")) <= 1, "tail read more than once:\n" <> report

    refute Enum.any?(qs, &(&1.sql =~ ~s/SELECT count(*) FROM "crdt_update_log"/)),
           "tail count(*) diagnostic still runs:\n" <> report
  end

  test "append reads the note once", %{conn: conn} do
    conn |> call_tool("append_to_note", %{"path" => "a.md", "text" => "warm"}) |> tool_ok!()

    {_, qs} =
      QueryRecorder.record(fn ->
        conn |> call_tool("append_to_note", %{"path" => "a.md", "text" => "more"}) |> tool_ok!()
      end)

    assert_single_read(qs)
  end

  for {mode, args} <- [
        {"replace_text", %{"find" => "body text", "replace" => "new text"}},
        {"replace_section", %{"heading" => "Body", "content" => "replaced"}},
        {"insert_section", %{"heading" => "Body", "content" => "inserted"}}
      ] do
    test "edit_note #{mode} reads the note once", %{conn: conn} do
      conn |> call_tool("append_to_note", %{"path" => "a.md", "text" => "warm"}) |> tool_ok!()
      args = Map.merge(%{"path" => "a.md", "mode" => unquote(mode)}, unquote(Macro.escape(args)))

      {_, qs} = QueryRecorder.record(fn -> conn |> call_tool("edit_note", args) |> tool_ok!() end)

      assert_single_read(qs)
    end
  end

  test "get_note_for_update refuses to run outside a tenant transaction", ctx do
    assert_raise ArgumentError, fn ->
      Engram.Notes.get_note_for_update(ctx.user, ctx.vault, "a.md")
    end

    assert {:ok, %{path: "a.md"}} =
             Engram.Repo.with_tenant!(ctx.user.id, fn ->
               Engram.Notes.get_note_for_update(ctx.user, ctx.vault, "a.md")
             end)
  end

  test "append to a missing note still creates it", %{conn: conn, user: user, vault: vault} do
    conn |> call_tool("append_to_note", %{"path" => "new.md", "text" => "fresh"}) |> tool_ok!()

    {:ok, note} = Engram.Notes.get_note(user, vault, "new.md")
    assert note.content == "# new\n\nfresh"
  end

  test "fanout does not re-read the note", %{conn: conn, user: user, vault: vault} do
    conn
    |> call_tool("write_note", %{"path" => "a.md", "content" => "# A\n\nwarm\n"})
    |> tool_ok!()

    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    {_, qs} =
      QueryRecorder.record(fn ->
        conn
        |> call_tool("write_note", %{"path" => "a.md", "content" => "# A\n\nfanned\n"})
        |> tool_ok!()
      end)

    write = Enum.find_index(qs, &(&1.source == "notes" and String.starts_with?(&1.sql, "UPDATE")))
    assert write, QueryRecorder.format(qs)
    after_write = Enum.drop(qs, write + 1)
    report = QueryRecorder.format(qs)

    refute Enum.any?(after_write, &(&1.source == "users")), "users re-read:\n" <> report
    assert selects(after_write, "notes") == [], "notes re-read after the write:\n" <> report

    # The fanout still carries the committed state.
    assert_receive %Phoenix.Socket.Broadcast{
      event: "note_yjs_update",
      payload: %{"b64" => b64}
    }

    {:ok, doc} = CrdtBridge.doc_from_state(Base.decode64!(b64))
    assert CrdtBridge.project_doc(doc) =~ "fanned"
  end

  # The append's rebuild runs on the tail-inclusive text, so the merge must not
  # treat the tail's edits as new inserts relative to the older snapshot.
  test "append keeps an unfolded tail edit exactly once", %{conn: conn, user: user, vault: vault} do
    {:ok, note} = Engram.Notes.get_note(user, vault, "a.md")

    prev = Application.get_env(:engram, Engram.Notes.CrdtCheckpointTimer, [])

    Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer,
      settle_ms: 600_000,
      ceiling_ms: 600_000,
      eager_ms: 600_000
    )

    on_exit(fn -> Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer, prev) end)

    {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)

    :ok =
      Yex.Sync.SharedDoc.update_doc(room, fn doc ->
        text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
        CrdtBridge.diff_into_text(text, Yex.Text.to_string(text) <> "TAILEDIT\n")
      end)

    conn |> call_tool("append_to_note", %{"path" => "a.md", "text" => "APPENDED"}) |> tool_ok!()

    {:ok, fresh} = Engram.Notes.get_note(user, vault, "a.md")
    {:ok, text} = Engram.Notes.authoritative_content(user, fresh)
    assert length(String.split(text, "TAILEDIT")) == 2, inspect(text)
    assert length(String.split(text, "APPENDED")) == 2, inspect(text)
  end
end

defmodule Engram.MCP.HandlersSingleReadConcurrencyTest do
  @moduledoc """
  Concurrent MCP writes to one note on REAL connections. The sandbox runs every
  process on one connection, so it serializes whole transactions and can never
  show a lost update or a lock-order deadlock (see `Engram.CheckpointInterleave`).
  `:auto` gives every process, the room and its checkpoint timer included, its
  own pooled connection. Rows really commit, hence `cleanup/1`.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{CheckpointInterleave, Crypto, Notes, Repo}
  alias Engram.MCP.Tools
  alias Engram.Notes.{CrdtBridge, CrdtRegistry}
  alias EngramWeb.McpController

  @writers 6

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user =
      insert(:user,
        id: user_id,
        email: "single-read-#{System.unique_integer([:positive])}-#{System.os_time()}@test.com"
      )

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Concurrent", Ecto.UUID.generate())

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "c.md", "content" => "# C\n\nbase\n"},
        actor: "api"
      )

    {:ok, tool} = Tools.get("append_to_note")
    %{user: user, vault: vault, note: note, tool: tool}
  end

  defp append_task(tool, user, vault, text) do
    Task.async(fn ->
      McpController.run_tool_handler(tool, user, vault, %{"path" => "c.md", "text" => text})
    end)
  end

  defp current_text(user, vault) do
    {:ok, note} = Notes.get_note(user, vault, "c.md")
    {:ok, text} = Notes.authoritative_content(user, note)
    text
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end

  defp assert_all_ok(results) do
    for {result, status, _} <- results do
      assert status == :ok, inspect(result)
    end
  end

  test "concurrent appends both land", %{user: user, vault: vault, tool: tool} do
    results =
      1..@writers
      |> Enum.map(&append_task(tool, user, vault, "LINE-#{&1}"))
      |> Task.await_many(30_000)

    assert_all_ok(results)
    text = current_text(user, vault)
    for i <- 1..@writers, do: assert(text =~ "LINE-#{i}", text)
  end

  # Every other note writer (REST upsert, checkpoint, delete) takes the vault's
  # seq lock and then the note row: next_seq!, then UPDATE notes. A locked read
  # that took the note first would deadlock with them: Postgres aborts one side
  # after deadlock_timeout. The append parks holding its locks while a REST
  # write runs into them, then both must finish.
  test "a locked append and a REST write of the note do not deadlock", ctx do
    %{user: user, vault: vault, tool: tool} = ctx
    on_exit(CheckpointInterleave.arm(:after_note_read))

    append = append_task(tool, user, vault, "LINE-1")
    parked = CheckpointInterleave.await_parked(:after_note_read, append.pid)

    rest =
      Task.async(fn ->
        Notes.upsert_note(user, vault, %{"path" => "c.md", "content" => "# C\n\nrest\n"},
          actor: "api"
        )
      end)

    # Long enough for the REST write to reach its first lock wait.
    Process.sleep(300)
    CheckpointInterleave.release(:after_note_read, parked)

    assert_all_ok([Task.await(append, 30_000)])
    assert {:ok, _} = Task.await(rest, 30_000)
  end

  test "concurrent appends land with a live room typing on the note", ctx do
    %{user: user, vault: vault, note: note, tool: tool} = ctx

    prev = Application.get_env(:engram, Engram.Notes.CrdtCheckpointTimer, [])

    # No checkpoint ticks: a tick that commits just before cleanup enqueues
    # its Oban jobs just after it, and those committed rows break every later
    # suite that asserts on the queue. The race under test is the room's own
    # tail append (UPDATE notes SET crdt_head) against the locked row.
    Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer,
      settle_ms: 600_000,
      ceiling_ms: 600_000,
      eager_ms: 600_000
    )

    on_exit(fn -> Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer, prev) end)

    {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)
    # Killed, so no unbind checkpoint runs either. Runs before cleanup (on_exit
    # callbacks run in reverse order).
    on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)

    typist =
      Task.async(fn ->
        for i <- 1..@writers do
          :ok =
            Yex.Sync.SharedDoc.update_doc(room, fn doc ->
              doc
              |> Yex.Doc.get_text(CrdtBridge.text_name())
              |> Yex.Text.insert(0, "TYPED-#{i}\n")
            end)

          Process.sleep(5)
        end
      end)

    appends = Enum.map(1..@writers, &append_task(tool, user, vault, "LINE-#{&1}"))

    assert_all_ok(Task.await_many(appends, 30_000))
    Task.await(typist, 30_000)

    expected = Enum.flat_map(1..@writers, &["LINE-#{&1}", "TYPED-#{&1}"])

    assert eventually(fn ->
             text = current_text(user, vault)
             Enum.all?(expected, &String.contains?(text, &1))
           end),
           current_text(user, vault)
  end
end
