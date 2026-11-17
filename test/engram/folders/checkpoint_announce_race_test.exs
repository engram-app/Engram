defmodule Engram.Folders.CheckpointAnnounceRaceTest do
  # A checkpoint reads the path a note is shown at before its write locks
  # the vault. A folder move (S5) committing after that read but before the
  # post-commit announce left the announce on the pre-move path, and a
  # plugin handed it re-maps the note id there (sync.ts `discoverAnnouncedNote`,
  # 1.39.3 and 1.40.0). In a vault holding a moved folder the path is
  # re-read after the commit.
  #
  # async: false: the interleave seam is global app config.
  use EngramWeb.ConnCase, async: false

  alias Engram.{Crypto, Folders, Notes, Repo, ServiceConfig}
  alias Engram.Folders.WriteStop
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint}

  # A moved vault's checkpoint over an unmoved one: 1, the chain read with
  # the in-transaction shown path (before this re-read existed), plus 5 for
  # the post-commit re-read in its own tenant transaction (BEGIN, tenant
  # enter, chain read, tenant exit, COMMIT), none under the vault seq lock.
  @moved_extra 6

  setup :authed_api_conn

  setup %{user: user, vault: vault} do
    {:ok, user} = Crypto.ensure_user_dek(user)
    ServiceConfig.put_override(:folder_ops, true)
    on_exit(fn -> Application.delete_env(:engram, :checkpoint_interleave_hook) end)

    for p <- ["A/n1.md", "A/n2.md"] do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => p, "content" => p}, actor: "api")
    end

    assert WriteStop.on?()
    %{user: user, vault: vault}
  end

  # A folder move committing after the checkpoint read the shown path, but
  # before it announces: the announce must carry where the note is shown
  # NOW, or a plugin re-maps the id onto the pre-move path.
  test "re-reads the shown path when a move lands before the announce", ctx do
    %{user: u, vault: v} = ctx
    note = Notes.get_note(u, v, "A/n1.md") |> elem(1)
    assert {:ok, _} = Folders.rename(u, v, "A", "B")
    EngramWeb.Endpoint.subscribe("crdt:#{u.id}:#{v.id}")

    {:ok, raw} = Repo.with_tenant(u.id, fn -> Engram.Fixtures.raw_note!(note.id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "edited")

    me = self()

    Application.put_env(:engram, :checkpoint_interleave_hook, fn
      :post_commit when self() == me ->
        unless Process.get(:moved_once) do
          Process.put(:moved_once, true)
          {:ok, _} = Folders.rename(u, v, "B", "C")
        end

      _ ->
        :ok
    end)

    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc)

    assert_receive %Phoenix.Socket.Broadcast{
      event: "crdt_doc_ready",
      payload: %{"doc_id" => id, "path" => path}
    }

    assert {id, path} == {note.id, "C/n1.md"}
  end

  # A failed re-read (a DB error after the commit) must not drop the
  # announces: they go out on the path read before the lock, with a warning.
  test "a re-read that raises still announces, on the earlier path", ctx do
    %{user: u, vault: v} = ctx
    note = Notes.get_note(u, v, "A/n1.md") |> elem(1)
    assert {:ok, _} = Folders.rename(u, v, "A", "B")
    EngramWeb.Endpoint.subscribe("crdt:#{u.id}:#{v.id}")

    {:ok, raw} = Repo.with_tenant(u.id, fn -> Engram.Fixtures.raw_note!(note.id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "edited")

    me = self()

    Application.put_env(:engram, :checkpoint_interleave_hook, fn
      :reresolve when self() == me -> raise DBConnection.ConnectionError, "forced"
      _ -> :ok
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc)
      end)

    assert_receive %Phoenix.Socket.Broadcast{
      event: "crdt_doc_ready",
      payload: %{"doc_id" => id, "path" => path}
    }

    assert {id, path} == {note.id, "B/n1.md"}
    assert log =~ "announce path re-read failed"
  end

  # Only database errors fall back: a bug in the re-read raises as before
  # (the post-commit guard logs it and nothing is announced).
  test "a re-read that raises a non-database error is not swallowed", ctx do
    %{user: u, vault: v} = ctx
    note = Notes.get_note(u, v, "A/n1.md") |> elem(1)
    assert {:ok, _} = Folders.rename(u, v, "A", "B")
    EngramWeb.Endpoint.subscribe("crdt:#{u.id}:#{v.id}")

    {:ok, raw} = Repo.with_tenant(u.id, fn -> Engram.Fixtures.raw_note!(note.id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "edited")

    me = self()

    Application.put_env(:engram, :checkpoint_interleave_hook, fn
      :reresolve when self() == me -> raise ArgumentError, "a bug"
      _ -> :ok
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc)
      end)

    refute_receive %Phoenix.Socket.Broadcast{event: "crdt_doc_ready"}, 500
    assert log =~ "post-commit work failed"
    refute log =~ "announce path re-read failed"
  end

  # The re-read's cost lands only on a vault that holds a moved folder:
  # measured as the same checkpoint before and after the vault's first move.
  test "only a vault with a moved folder pays for the re-read", ctx do
    %{user: u, vault: v} = ctx
    note = Notes.get_note(u, v, "A/n1.md") |> elem(1)
    _ = count!(u, v, note, "warm")
    unmoved = count!(u, v, note, "one")
    assert {:ok, _} = Folders.rename(u, v, "A", "B")
    _ = count!(u, v, note, "warm2")
    moved = count!(u, v, note, "two")

    assert moved - unmoved == @moved_extra
  end

  defp count!(u, v, note, text) do
    {:ok, raw} = Repo.with_tenant(u.id, fn -> Engram.Fixtures.raw_note!(note.id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)

    {:ok, queries} =
      Engram.QueryRecorder.record(fn -> CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc) end)

    me = self()
    length(for %{pid: ^me} = q <- queries, do: q)
  end
end
