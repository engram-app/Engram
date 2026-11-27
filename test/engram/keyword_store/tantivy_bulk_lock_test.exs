defmodule Engram.KeywordStore.TantivyBulkLockTest do
  @moduledoc """
  The bulk read's note lock, proven with two real connections (review M8).
  The SQL sandbox shares one connection between processes, where a row lock
  never blocks, so this writes for real through `Sandbox.unboxed_run/2` and
  deletes its rows after, keeping the shared DB clean.

  A pass holds the note's row lock and has not taken its stamp yet; a bulk
  read of the same note must WAIT for it and then take a HIGHER stamp, or a
  batch could be ordered before a pass whose effects it does not hold.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Indexing.ChunkRows
  alias Engram.KeywordStore.Tantivy.Bulk
  alias Engram.Maintenance.Cursor
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.Workers.ReconcileKeywordIndex

  test "a bulk read waits for a pass holding the note lock, then stamps above it" do
    test_pid = self()
    {user_id, note_id} = setup_note()

    try do
      pass =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.with_tenant(user_id, fn ->
              :ok = ChunkRows.lock_notes!([note_id])
              send(test_pid, :locked)

              receive do
                :go -> :ok
              end

              %{rows: [[stamp]]} = Repo.query!("SELECT nextval('keyword_stamp_seq')", [])
              stamp
            end)
          end)
        end)

      assert_receive :locked, 5_000

      read =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn -> Bulk.read(user_id, [note_id]) end)
        end)

      refute Task.yield(read, 300), "the bulk read did not wait for the note lock"
      send(pass.pid, :go)
      {:ok, pass_stamp} = Task.await(pass, 5_000)
      read = Task.await(read, 5_000)
      assert read.stamps[note_id] > pass_stamp
    after
      Sandbox.unboxed_run(Repo, fn ->
        id = Ecto.UUID.dump!(user_id)

        for table <- ~w(notes vaults users) do
          column = if table == "users", do: "id", else: "user_id"
          Repo.query!("DELETE FROM #{table} WHERE #{column} = $1", [id])
        end
      end)
    end
  end

  # Review delta L6: the session advisory lock. A run while another
  # session holds it is a no-op: no walk, no `/bulk`, no `/rebuilt`, no
  # cursor written, no successor job.
  test "a reconcile job while another session holds the walk lock does nothing" do
    kw = Bypass.open()
    test_pid = self()
    ServiceConfig.put_override(:keyword_feed, true)

    ServiceConfig.put_override(:kwsearch,
      url: "http://localhost:#{kw.port}",
      allow_http: true,
      token_keys: ["test-token-key-0123456789abcdef01234567"],
      timeout_ms: 5_000
    )

    Bypass.stub(kw, :any, :any, fn conn ->
      send(test_pid, {:kwsearch, conn.request_path})

      body =
        if conn.request_path == "/cursor",
          do: %{"xid" => "1", "seq" => 1, "epoch" => "e1", "rebuilding" => true},
          else: %{"applied" => 0, "stale" => 0, "tomb" => 0, "malformed" => 0}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.checkout(fn ->
            Repo.query!("SELECT pg_advisory_lock(hashtextextended('keyword_reconcile', 0))")
            send(test_pid, :locked)

            receive do
              :go -> :ok
            end

            Repo.query!("SELECT pg_advisory_unlock(hashtextextended('keyword_reconcile', 0))")
          end)
        end)
      end)

    assert_receive :locked, 5_000

    try do
      assert :ok =
               Sandbox.unboxed_run(Repo, fn -> ReconcileKeywordIndex.perform(%Oban.Job{}) end)

      assert_received {:kwsearch, "/cursor"}
      refute_received {:kwsearch, _}, "the run went past the lock"

      assert Sandbox.unboxed_run(Repo, fn -> Cursor.get("keyword_reconcile") end) == nil
    after
      send(holder.pid, :go)
      Task.await(holder, 5_000)

      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM maintenance_cursors WHERE name = 'keyword_reconcile'")
      end)
    end
  end

  defp setup_note do
    Sandbox.unboxed_run(Repo, fn ->
      user =
        Engram.Factory.insert(:user,
          email: "kwlock_#{System.unique_integer([:positive])}@example.com"
        )

      vault = Engram.Factory.insert(:vault, user: user)
      note = Engram.Factory.insert(:note, user: user, vault: vault)
      {to_string(user.id), note.id}
    end)
  end
end
