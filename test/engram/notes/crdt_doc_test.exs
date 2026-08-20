defmodule Engram.Notes.CrdtDocTest do
  use Engram.DataCase, async: false

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtRegistry, CrdtUpdateLog, Note}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "CrdtDocTest", Ecto.UUID.generate())
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "before"})
    %{user: user, vault: vault, note: note}
  end

  test "supervisor shutdown runs terminate → unbind → edits materialize", ctx do
    %{user: user, vault: vault, note: note} = ctx

    # Override the checkpoint timer to huge settle/ceiling/eager values so it
    # cannot fire during the synchronous update_doc → terminate_child window.
    # Large integers (not :infinity) because the timer's min/2 arithmetic would
    # misbehave on atoms. Must be set BEFORE the room starts so the timer's
    # init/1 picks up the overridden config.
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
        doc
        |> Yex.Doc.get_text(CrdtBridge.text_name())
        |> CrdtBridge.diff_into_text("before AND SHUTDOWN EDIT")
      end)

    # Simulate the deploy path: supervisor-initiated graceful shutdown.
    :ok = DynamicSupervisor.terminate_child(Engram.Notes.CrdtDocSupervisor, room)

    {:ok, {:ok, updated}} =
      Repo.with_tenant(user.id, fn ->
        Crypto.maybe_decrypt_note_fields(Repo.get!(Note, note.id), user)
      end)

    assert updated.content =~ "SHUTDOWN EDIT"
  end

  # #851. Rooms flush a full checkpoint in terminate/2. The OTP default of
  # 5_000 ms can brutal-kill that flush on a deploy, when every room terminates
  # at once and contends for the DB pool. Lossless (the tail-log still has every
  # update) but wasteful. Pinned so the grace is not silently dropped.
  test "child_spec grants terminate/2 enough shutdown grace to flush a checkpoint" do
    spec = Engram.Notes.CrdtDoc.child_spec(note_id: "n1", user_id: "u1", vault_id: "v1")

    assert spec.shutdown == 15_000
    # Still :temporary — a crashed room must not be resurrected observer-less.
    assert spec.restart == :temporary
  end

  # The timer's tick path (#1146 spec 0a). `do_checkpoint/1` now folds the
  # durable tail itself and passes the exact ids, because passing none used to
  # take the watermark branch and delete rows nothing folded.
  #
  # This exists because the fold was shipped UNTESTED: the 0a unit test drives
  # `CrdtCheckpoint.checkpoint/5` directly, so every checkpoint suite stayed
  # green while the timer path was never executed once. Review then found that
  # `replay_tail/3` issues a bare `Repo.all` and needs a tenant supplied by its
  # caller — without one the fold returns no ids and compaction silently stops.
  # A green suite that never runs the code is not coverage.
  test "a tick checkpoint compacts the tail it folded", ctx do
    %{user: user, vault: vault, note: note} = ctx

    prev = Application.get_env(:engram, Engram.Notes.CrdtCheckpointTimer, [])

    # Short enough that the tick fires on its own inside this test.
    Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer,
      settle_ms: 50,
      ceiling_ms: 200,
      eager_ms: 20
    )

    on_exit(fn -> Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer, prev) end)

    {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)

    # Goes through update_v1, which appends a tail row.
    :ok =
      Yex.Sync.SharedDoc.update_doc(room, fn doc ->
        doc
        |> Yex.Doc.get_text(CrdtBridge.text_name())
        |> CrdtBridge.diff_into_text("before AND TICKED")
      end)

    tail_count = fn ->
      {:ok, n} =
        Repo.with_tenant(user.id, fn ->
          Repo.aggregate(from(l in CrdtUpdateLog, where: l.note_id == ^note.id), :count)
        end)

      n
    end

    assert tail_count.() > 0, "expected update_v1 to have appended a tail row"

    # Wait for the tick to land rather than sleeping a fixed span.
    assert eventually(fn -> tail_count.() == 0 end),
           """
           the tick checkpoint did not compact the tail it folded. Either the
           fold produced no ids (a missing tenant makes replay_tail return
           nothing) or the checkpoint never ran.
           """

    {:ok, fresh} = Notes.get_note(user, vault, "p.md")
    assert fresh.content == "before AND TICKED"
  end

  # The tag is the whole point of the metric: `count` says how many rooms an
  # import allocated, `source` says which path allocated them. Asserted here
  # because a telemetry tag that is never read in a test is indistinguishable
  # from one that is never emitted.
  test "room_start carries the source that allocated the room", ctx do
    %{user: user, vault: vault, note: note} = ctx

    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "room-start-source-#{inspect(ref)}",
      [:engram, :crdt, :room_start],
      fn _event, measurements, metadata, _cfg ->
        send(test_pid, {ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("room-start-source-#{inspect(ref)}") end)

    {:ok, _room} =
      CrdtRegistry.ensure_started(user.id, vault.id, note.id, :handshake)

    assert_receive {^ref, %{count: 1}, %{source: :handshake}}, 2_000
  end

  # A room that already exists is resolved, not allocated, so it must not emit
  # at all — otherwise the counter measures lookups and the headline "rooms per
  # import" number is inflated by every subsequent frame.
  test "resolving an existing room emits no room_start", ctx do
    %{user: user, vault: vault, note: note} = ctx

    {:ok, _room} = CrdtRegistry.ensure_started(user.id, vault.id, note.id, :handshake)

    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "room-start-dup-#{inspect(ref)}",
      [:engram, :crdt, :room_start],
      fn _event, _m, meta, _cfg -> send(test_pid, {ref, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("room-start-dup-#{inspect(ref)}") end)

    {:ok, _same} = CrdtRegistry.ensure_started(user.id, vault.id, note.id, :edit)

    refute_receive {^ref, _}, 300
  end

  defp eventually(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end
end
