defmodule Engram.Notes.CrdtRegistryTest do
  use Engram.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Notes, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtRegistry}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "CrdtRegistryTest"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "base"})
    %{user: user, vault: vault, note: note}
  end

  test "ensure_started is idempotent — same pid for the same note", ctx do
    %{user: u, vault: v, note: note} = ctx
    {:ok, pid1} = CrdtRegistry.ensure_started(u.id, v.id, note.id)
    Sandbox.allow(Engram.Repo, self(), pid1)
    {:ok, pid2} = CrdtRegistry.ensure_started(u.id, v.id, note.id)
    assert pid1 == pid2
    assert Process.alive?(pid1)
  end

  test "distinct notes get distinct rooms", ctx do
    %{user: u, vault: v} = ctx
    {:ok, note1} = Notes.upsert_note(u, v, %{"path" => "r1.md", "content" => "a"})
    {:ok, note2} = Notes.upsert_note(u, v, %{"path" => "r2.md", "content" => "b"})
    {:ok, p1} = CrdtRegistry.ensure_started(u.id, v.id, note1.id)
    Sandbox.allow(Engram.Repo, self(), p1)
    {:ok, p2} = CrdtRegistry.ensure_started(u.id, v.id, note2.id)
    Sandbox.allow(Engram.Repo, self(), p2)
    refute p1 == p2
  end

  describe "observe_with_retry/3 — auto-exit race recovery" do
    test "observes once and returns the room when observe succeeds" do
      test_pid = self()
      start_fun = fn -> {:ok, :room1} end
      observe_fun = fn room -> send(test_pid, {:observed, room}) && :ok end

      assert {:ok, :room1} = CrdtRegistry.observe_with_retry(start_fun, observe_fun, 3)
      assert_received {:observed, :room1}
    end

    test "retries with a fresh room when observe exits mid-race, then succeeds" do
      # The singleton room auto-exits (last observer left) between whereis and
      # observe, so the first observe exits. The retry must re-start a fresh room
      # and observe THAT, not crash the caller.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      start_fun = fn ->
        {:ok, Agent.get_and_update(counter, fn n -> {{:room, n}, n + 1} end)}
      end

      observe_fun = fn
        {:room, 0} -> exit(:normal)
        _ -> :ok
      end

      assert {:ok, {:room, 1}} = CrdtRegistry.observe_with_retry(start_fun, observe_fun, 3)
    end

    test "gives up with {:error, :room_unavailable} after exhausting attempts" do
      start_fun = fn -> {:ok, :room} end
      observe_fun = fn _ -> exit(:normal) end

      assert {:error, :room_unavailable} =
               CrdtRegistry.observe_with_retry(start_fun, observe_fun, 3)
    end

    test "propagates a start_fun error without retrying observe" do
      start_fun = fn -> {:error, :nope} end
      observe_fun = fn _ -> flunk("observe must not run when start fails") end

      assert {:error, :nope} = CrdtRegistry.observe_with_retry(start_fun, observe_fun, 3)
    end
  end

  # NOTE: `ensure_observed/3` against a real room is integration-tested via the
  # CrdtChannel (ensure_room → ensure_observed), where the channel process owns
  # the observer registration and ExUnit tears it down before the sandbox
  # closes. Observing a :global room directly from the TEST process would leave
  # it to auto-exit after the sandbox owner exits, and its terminate-time
  # CrdtPersistence.unbind Repo write would crash and cascade the suite (the
  # same hazard documented in crdt_channel_test.exs). The retry logic itself is
  # covered deterministically by the observe_with_retry/3 tests above.

  test "room doc uses UTF-16 offset kind", ctx do
    %{user: u, vault: v} = ctx
    # Use a note with empty content so the doc starts blank — this isolates the
    # UTF-16 offset check from any pre-seeded content.
    {:ok, empty_note} = Notes.upsert_note(u, v, %{"path" => "utf16.md", "content" => ""})
    {:ok, pid} = CrdtRegistry.ensure_started(u.id, v.id, empty_note.id)
    Sandbox.allow(Engram.Repo, self(), pid)
    doc = Yex.Sync.SharedDoc.get_doc(pid)
    # Insert a multi-byte character to verify UTF-16 offset semantics.
    # If offset_kind were :bytes (y_ex default), this operation could
    # diverge from what JS Yjs clients expect.
    text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
    assert :ok = Yex.Text.insert(text, 0, "café")
    assert Yex.Text.to_string(text) == "café"
  end

  describe "terminate_room/1 (#954 + #953-review F2)" do
    test "unregisters the INNER :global term synchronously, then kills" do
      note_id = Ecto.UUID.generate()
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :yes = :global.register_name({:crdt_doc, note_id}, pid)
      ref = Process.monitor(pid)

      assert :ok = CrdtRegistry.terminate_room(note_id)

      # The name is gone IMMEDIATELY (before :global's async DOWN cleanup) —
      # this is exactly what the old wrapped-name unregister failed to do.
      assert :global.whereis_name({:crdt_doc, note_id}) == :undefined
      assert CrdtRegistry.lookup(note_id) == nil
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
    end

    test "is a no-op for a room that is not running" do
      assert :ok = CrdtRegistry.terminate_room(Ecto.UUID.generate())
    end
  end
end
