defmodule Engram.MCP.HandlersSingleReadTest do
  # Not async: QueryRecorder's telemetry handler is global.
  use EngramWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.Notes.CrdtBridge
  alias Engram.Notes.CrdtRegistry
  alias Engram.QueryRecorder
  alias Yex.Sync.SharedDoc

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

  # Counting tests below clear the request caches, then warm them with one
  # call of the same kind, then measure: the warm state of a long-lived node.

  defp selects(qs, source),
    do: Enum.filter(qs, &(&1.source == source and String.starts_with?(&1.sql, "SELECT")))

  # Optimistic read-modify-write: one unlocked read (the rebuild runs on it),
  # then one locked re-read right before the write. Nothing else reads the row.
  defp assert_single_read(qs) do
    report = QueryRecorder.format(qs)
    reads = selects(qs, "notes")
    assert length(reads) == 2, "expected one unlocked + one locked note read:\n" <> report
    assert [_] = Enum.filter(reads, &(&1.sql =~ "FOR NO KEY UPDATE")), report
    assert length(selects(qs, "crdt_update_log")) <= 1, "tail read more than once:\n" <> report

    refute Enum.any?(qs, &(&1.sql =~ ~s/SELECT count(*) FROM "crdt_update_log"/)),
           "tail count(*) diagnostic still runs:\n" <> report
  end

  test "append reads the note once, then re-reads it locked", %{conn: conn} do
    Engram.DataCase.clear_request_caches()
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
    test "edit_note #{mode} reads the note once, then re-reads it locked", %{conn: conn} do
      Engram.DataCase.clear_request_caches()
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
    Engram.DataCase.clear_request_caches()

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

  # A room on a.md that never checkpoints, with `edit` typed into it, so the
  # edit exists only in the tail. Killed at exit (no unbind checkpoint).
  defp type_into_room(user, vault, edit) do
    {:ok, note} = Engram.Notes.get_note(user, vault, "a.md")
    prev = Application.get_env(:engram, Engram.Notes.CrdtCheckpointTimer, [])

    Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer,
      settle_ms: 600_000,
      ceiling_ms: 600_000,
      eager_ms: 600_000
    )

    on_exit(fn -> Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer, prev) end)
    {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)
    on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)

    :ok =
      SharedDoc.update_doc(room, fn doc ->
        text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
        CrdtBridge.diff_into_text(text, edit.(Yex.Text.to_string(text)))
      end)
  end

  defp text_of(user, vault, path) do
    {:ok, fresh} = Engram.Notes.get_note(user, vault, path)
    {:ok, text} = Engram.Notes.authoritative_content(user, fresh)
    text
  end

  defp count(text, part), do: length(String.split(text, part)) - 1

  # The append's rebuild runs on the tail-inclusive text, so the merge must not
  # treat the tail's edits as new inserts relative to the older snapshot.
  test "append keeps an unfolded tail edit exactly once", %{conn: conn, user: user, vault: vault} do
    type_into_room(user, vault, &(&1 <> "TAILEDIT\n"))

    conn |> call_tool("append_to_note", %{"path" => "a.md", "text" => "APPENDED"}) |> tool_ok!()

    text = text_of(user, vault, "a.md")
    assert count(text, "TAILEDIT") == 1, inspect(text)
    assert count(text, "APPENDED") == 1, inspect(text)
  end

  test "REST append keeps an unfolded tail edit exactly once", ctx do
    %{conn: conn, user: user, vault: vault} = ctx
    type_into_room(user, vault, &(&1 <> "TAILEDIT\n"))

    conn = post(conn, "/api/notes/append", %{path: "a.md", text: "APPENDED"})
    assert %{"created" => false} = json_response(conn, 200)

    text = text_of(user, vault, "a.md")
    assert count(text, "TAILEDIT") == 1, inspect(text)
    assert count(text, "APPENDED") == 1, inspect(text)
  end

  # The no-op shortcut compared the result with the FACADE hash, which lags an
  # un-checkpointed tail edit. Reverting that edit produces exactly the facade
  # text, so the write was skipped while the tool reported success.
  test "an edit that reverts an unfolded tail edit is written", ctx do
    %{conn: conn, user: user, vault: vault} = ctx
    type_into_room(user, vault, &(&1 <> "TAILEDIT\n"))

    conn
    |> call_tool("edit_note", %{
      "path" => "a.md",
      "mode" => "replace_text",
      "find" => "TAILEDIT\n",
      "replace" => ""
    })
    |> tool_ok!()

    text = text_of(user, vault, "a.md")
    assert count(text, "TAILEDIT") == 0, inspect(text)
  end

  # The snapshot and the tail must come from one statement. Read in two, a
  # checkpoint that folds the tail into a new snapshot and prunes it in
  # between gave the OLD snapshot with NO tail: the edit vanished.
  test "authoritative text survives a checkpoint between its reads", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, stale} = Engram.Notes.get_note(user, vault, "a.md")
    {:ok, base} = CrdtBridge.doc_from_state(snapshot_of(user, stale))
    {:ok, sv} = Yex.encode_state_vector(base)
    Yex.Text.insert(Yex.Doc.get_text(base, CrdtBridge.text_name()), 0, "FOLDED-")
    {:ok, upd} = Yex.encode_state_as_update(base, sv)

    st = %{user_id: user.id, vault_id: vault.id, note_id: stale.id}
    _ = Engram.Notes.CrdtPersistence.update_v1(st, upd, stale.id, base)

    ids =
      Engram.Repo.with_tenant!(user.id, fn ->
        Engram.Repo.all(
          from(l in Engram.Notes.CrdtUpdateLog, where: l.note_id == ^stale.id, select: l.id)
        )
      end)

    :ok =
      Engram.Notes.CrdtCheckpoint.checkpoint(user.id, vault.id, stale.id, base, prune_ids: ids)

    {result, qs} =
      QueryRecorder.record(fn -> Engram.Notes.authoritative_content(user, stale) end)

    assert {:ok, text} = result
    assert text =~ "FOLDED-", text

    # One statement reads the snapshot and the tail: a re-read split in two
    # would leave the gap open again.
    report = QueryRecorder.format(qs)

    reads =
      Enum.reject(qs, &(&1.source in ~w(tenant_txn tenant_enter tenant_exit tenant_exit_sandbox)))

    assert [%{sql: sql}] = reads, report
    assert sql =~ ~s(FROM "notes") and sql =~ "crdt_update_log", report
  end

  defp snapshot_of(user, note) do
    {:ok, state} = Engram.Crypto.decrypt_crdt_state(note, user)
    state
  end

  # A row with no crdt_state whose bind seeded the full text into the tail, plus
  # an edit after it: the tail is the newer text, so a rebuild must start there.
  test "a legacy note's pending tail edits are part of its text", ctx do
    %{conn: conn, user: user, vault: vault} = ctx
    {:ok, note} = Engram.Notes.get_note(user, vault, "a.md")

    {:ok, doc} = CrdtBridge.doc_from_state(nil)
    :ok = CrdtBridge.ingest_plaintext(doc, note.content <> "TAILEDIT\n")
    {:ok, update} = Yex.encode_state_as_update(doc)
    {:ok, {ct, nonce}} = Engram.Crypto.encrypt_crdt_state(update, user, note.id)

    Engram.Repo.with_tenant!(user.id, fn ->
      Engram.Repo.update_all(
        from(n in Engram.Notes.Note, where: n.id == ^note.id),
        set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
      )

      Engram.Repo.insert_all(Engram.Notes.CrdtUpdateLog, [
        %{
          id: Ecto.UUID.generate(),
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: nonce,
          inserted_at: DateTime.utc_now()
        }
      ])
    end)

    assert count(text_of(user, vault, "a.md"), "TAILEDIT") == 1

    conn |> call_tool("append_to_note", %{"path" => "a.md", "text" => "APPENDED"}) |> tool_ok!()

    text = text_of(user, vault, "a.md")
    assert count(text, "TAILEDIT") == 1, inspect(text)
    assert count(text, "APPENDED") == 1, inspect(text)
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
  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{CheckpointInterleave, Crypto, Notes, Repo}
  alias Engram.MCP.Tools
  alias Engram.Notes.{CrdtBridge, CrdtRegistry}
  alias EngramWeb.McpController
  alias Yex.Sync.SharedDoc

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

  defp append_task(tool, user, vault, text, path \\ "c.md") do
    Task.async(fn ->
      McpController.run_tool_handler(tool, user, vault, %{"path" => path, "text" => text})
    end)
  end

  defp current_text(user, vault, path \\ "c.md") do
    {:ok, note} = Notes.get_note(user, vault, path)
    {:ok, text} = Notes.authoritative_content(user, note)
    text
  end

  # Waits until some backend of this database is blocked on a lock (not a
  # sleep: a test that releases before the waiter got there proves nothing).
  defp await_lock_wait do
    assert eventually(fn ->
             %{rows: [[n]]} =
               Repo.query!(
                 "SELECT count(*) FROM pg_stat_activity " <>
                   "WHERE datname = current_database() AND wait_event_type = 'Lock'",
                 []
               )

             n > 0
           end),
           "no backend ever waited on a lock"
  end

  # An MCP-shaped read-modify-write in its own request transaction whose rebuild
  # parks on its FIRST call until released, reporting every text it saw.
  defp parked_rmw(user, vault, path, suffix) do
    test = self()
    calls = :counters.new(1, [:atomics])

    Task.async(fn ->
      Repo.with_tenant!(user.id, fn ->
        Engram.MCP.Handlers.rmw_upsert(user, vault, path, fn current ->
          send(test, {:rebuild_saw, current})
          :counters.add(calls, 1, 1)

          if :counters.get(calls, 1) == 1 do
            send(test, {:rebuild_parked, self()})
            assert_receive :release_rebuild, 15_000
          end

          current <> suffix
        end)
      end)
    end)
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

    await_lock_wait()
    CheckpointInterleave.release(:after_note_read, parked)

    assert_all_ok([Task.await(append, 30_000)])
    assert {:ok, _} = Task.await(rest, 30_000)
  end

  # The losing delete read the note live (unlocked), then waited on the
  # winner's vault seq lock; its tombstone UPDATE then matches no live row. It
  # must report :absent and enqueue / announce nothing.
  test "a delete that loses to a concurrent delete reports :absent", %{
    user: user,
    vault: vault,
    note: note
  } do
    test = self()

    winner =
      Task.async(fn ->
        Repo.with_tenant!(user.id, fn ->
          result = Notes.delete_note_reporting(user, vault, "c.md")
          send(test, :winner_deleted)
          assert_receive :commit, 15_000
          result
        end)
      end)

    assert_receive :winner_deleted, 15_000
    loser = Task.async(fn -> Notes.delete_note_reporting(user, vault, "c.md") end)
    await_lock_wait()
    send(winner.pid, :commit)

    assert Task.await(winner, 30_000) == :deleted
    assert Task.await(loser, 30_000) == :absent

    jobs =
      Repo.all(
        from(j in Oban.Job,
          where: fragment("? ->> 'note_id' = ?", j.args, ^note.id),
          where: j.worker == "Engram.Workers.DeleteNoteIndex"
        )
      )

    assert length(jobs) == 1
  end

  test "concurrent appends to a missing note all land", %{user: user, vault: vault, tool: tool} do
    results =
      1..@writers
      |> Enum.map(&append_task(tool, user, vault, "LINE-#{&1}", "missing.md"))
      |> Task.await_many(30_000)

    assert_all_ok(results)
    text = current_text(user, vault, "missing.md")
    for i <- 1..@writers, do: assert(text =~ "LINE-#{i}", text)
  end

  # The rebuild (a section parse can take up to 20 s) runs before any lock, so
  # it does not hold the vault's seq lock against every other writer.
  test "a slow rebuild on one note does not block a write to another note", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "other.md", "content" => "x"}, actor: "api")

    slow = parked_rmw(user, vault, "c.md", "SLOW\n")
    assert_receive {:rebuild_parked, parked}, 15_000

    other =
      Task.async(fn ->
        Notes.upsert_note(user, vault, %{"path" => "other.md", "content" => "y"}, actor: "api")
      end)

    assert {:ok, {:ok, _}} = Task.yield(other, 5_000),
           "a write to another note waited on the slow rebuild"

    send(parked, :release_rebuild)
    assert {:ok, _} = Task.await(slow, 30_000)
    assert current_text(user, vault) =~ "SLOW"
  end

  # A write that commits while the rebuild runs: the optimistic write must not
  # land over it, and the recompute under the lock must see it.
  test "the rebuild sees the current text after a concurrent write", ctx do
    %{user: user, vault: vault, tool: tool} = ctx

    slow = parked_rmw(user, vault, "c.md", "SLOW\n")
    assert_receive {:rebuild_saw, first}, 15_000
    assert_receive {:rebuild_parked, parked}, 15_000
    refute first =~ "FAST"

    assert_all_ok([Task.await(append_task(tool, user, vault, "FAST"), 30_000)])

    send(parked, :release_rebuild)
    assert {:ok, _} = Task.await(slow, 30_000)

    assert_receive {:rebuild_saw, second}, 1_000
    assert second =~ "FAST"
    text = current_text(user, vault)
    assert text =~ "FAST" and text =~ "SLOW", text
  end

  # A legacy row (no crdt_state) whose tail is empty at the read: a room that
  # binds and gets the client's seed plus a keystroke while the rebuild runs
  # puts both in the tail. Diffing the rebuilt text (which lacks the keystroke)
  # into that tail would delete the keystroke, so the write must recompute.
  test "a keystroke on a legacy note during the rebuild survives", ctx do
    %{user: user, vault: vault, note: note} = ctx

    prev = Application.get_env(:engram, Engram.Notes.CrdtCheckpointTimer, [])

    Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer,
      settle_ms: 600_000,
      ceiling_ms: 600_000,
      eager_ms: 600_000
    )

    on_exit(fn -> Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer, prev) end)

    Repo.with_tenant!(user.id, fn ->
      Repo.update_all(
        from(n in Engram.Notes.Note, where: n.id == ^note.id),
        set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
      )
    end)

    slow = parked_rmw(user, vault, "c.md", "APPENDED\n")
    assert_receive {:rebuild_parked, parked}, 15_000

    {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)
    on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)

    # The client's seed of the facade text, then a keystroke on it.
    :ok =
      SharedDoc.update_doc(room, fn doc ->
        CrdtBridge.ingest_plaintext(doc, "# C\n\nbase\n")
      end)

    :ok =
      SharedDoc.update_doc(room, fn doc ->
        doc |> Yex.Doc.get_text(CrdtBridge.text_name()) |> Yex.Text.insert(0, "KEY-")
      end)

    # Both update_v1 appends are in the room's mailbox ahead of this call.
    _ = :sys.get_state(room)

    send(parked, :release_rebuild)
    assert {:ok, _} = Task.await(slow, 30_000)

    text = current_text(user, vault)
    assert text =~ "KEY-", text
    assert text =~ "APPENDED", text
    assert length(String.split(text, "base")) == 2, text
  end

  # REST POST /api/notes/append had no guard at all: a concurrent append
  # committing between its read and write was erased by the merge.
  test "concurrent REST appends all land", %{user: user, vault: vault} do
    for i <- 1..@writers do
      Task.async(fn ->
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.assign(:current_user, user)
        |> Plug.Conn.assign(:current_vault, vault)
        |> EngramWeb.NotesController.append(%{"path" => "c.md", "text" => "REST-#{i}"})
      end)
    end
    |> Task.await_many(30_000)
    |> Enum.each(&assert(&1.status == 200, &1.resp_body))

    text = current_text(user, vault)
    for i <- 1..@writers, do: assert(text =~ "REST-#{i}", text)
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
            SharedDoc.update_doc(room, fn doc ->
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
