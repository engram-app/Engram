defmodule Engram.Notes.CrdtWriteTest do
  # async: false: some tests start a real :global-registered room
  # (CrdtRegistry.ensure_started/3), the sandbox hazard documented in
  # Engram.DataCase.setup_sandbox/1 (#777), and some arm app-env test seams.
  use Engram.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Fixtures, Notes, ServiceConfig, TenantQueryCounter}
  alias Engram.Notes.{CrdtBridge, CrdtPersistence, CrdtRegistry, CrdtRoom}
  alias Yex.Sync.SharedDoc

  # 300 lines, "row N: foo".
  @text Enum.map_join(1..300, &"row #{&1}: foo\n")

  setup do
    {:ok, user} = Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp on!, do: ServiceConfig.put_override(:crdt_write_apply_text, true)

  defp create!(user, vault, path, text) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => text}, actor: "api")

    note
  end

  defp write(user, vault, path, text, opts \\ []) do
    Notes.upsert_note(user, vault, %{"path" => path, "content" => text}, [actor: "sync"] ++ opts)
  end

  defp served!(user, vault, path) do
    {:ok, note} = Notes.get_note(user, vault, path)
    note.content
  end

  # A client's edit landing in the tail roomless (a disconnected device's
  # catch-up): its own doc, its own client id.
  defp tail_edit!(user, vault, note_id, fun) do
    raw = Fixtures.raw_note!(note_id)
    {:ok, doc, _} = Repo.with_tenant!(user.id, fn -> CrdtPersistence.load_doc(raw, user) end)
    sv = Yex.encode_state_vector!(doc)
    :ok = CrdtBridge.ingest_plaintext(doc, fun.(CrdtBridge.project_doc(doc)))

    _ =
      CrdtPersistence.update_v1(
        %{user_id: user.id, vault_id: vault.id, note_id: note_id},
        Yex.encode_state_as_update!(doc, sv),
        nil,
        doc
      )

    :ok
  end

  defp live_room!(user, vault, note) do
    {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)
    Sandbox.allow(Repo, self(), room)
    on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)
    room
  end

  defp room_text(room), do: CrdtBridge.project_doc(SharedDoc.get_doc(room))

  defp arm_hook(fun) do
    Application.put_env(:engram, :checkpoint_interleave_hook, fun)
    on_exit(fn -> Application.delete_env(:engram, :checkpoint_interleave_hook) end)
  end

  # The `notes` table's own copy, read past NoteBody (which prefers the body
  # row): a half-committed write differs here first.
  defp notes_row(note_id) do
    Repo.one!(
      from(n in "notes",
        where: n.id == type(^note_id, Ecto.UUID),
        select: %{
          content_hash: n.content_hash,
          crdt_state_nonce: n.crdt_state_nonce,
          version: n.version,
          seq: n.seq
        }
      ),
      skip_tenant_check: true
    )
  end

  # Tail appends: one per update a room (or a roomless write) takes in.
  defp attach_appends do
    ref = make_ref()
    me = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:engram, :crdt, :update_appended],
      fn _e, _m, _meta, _ -> send(me, {:appended, ref}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  defp drain(ref, n \\ 0) do
    receive do
      {:appended, ^ref} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  defp occurrences(text, part), do: length(String.split(text, part)) - 1

  defp attach_written do
    ref = make_ref()
    me = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:engram, :notes, :crdt_write, :written],
      fn _e, _m, meta, _ -> send(me, {:crdt_written, ref, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  describe "merging" do
    # Red-first: switch off (the snapshot merge's single span re-inserts the
    # old line 100 next to the edit) and with the single-span diff on this
    # path (`ingest_plaintext` without `diff: :hunks`).
    test "an edit on line 100 landing after an rmw read survives its rewrite of lines 2 and 200",
         %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "big.md", @text)

      rebuild = fn current ->
        # Runs after the authority read and before the write: a device edit
        # lands in that window, once.
        unless Process.put(:edited, true),
          do:
            tail_edit!(user, vault, note.id, &String.replace(&1, "row 100: foo", "row 100: bar"))

        current
        |> String.replace("row 2: foo\n", "row 2: TWO\n")
        |> String.replace("row 200: foo\n", "row 200: TWO HUNDRED\n")
      end

      assert {{:ok, _}, _} = Notes.rmw_note(user, vault, "big.md", rebuild, actor: "mcp")

      served = served!(user, vault, "big.md")
      assert occurrences(served, "row 100: bar\n") == 1
      assert occurrences(served, "row 100: foo") == 0
      assert served =~ "row 2: TWO\n"
      assert served =~ "row 200: TWO HUNDRED\n"
      assert occurrences(served, "row 150: foo\n") == 1
    end

    # #2489, red-first with the switch off: the snapshot-relative merge kept
    # both the tail edit and the push's copy of it.
    test "a push that already carries a tail edit leaves one copy of it",
         %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "a.md", "alpha\n")
      tail_edit!(user, vault, note.id, &(&1 <> "beta\n"))

      assert {:ok, written} = write(user, vault, "a.md", "alpha\nbeta\ngamma\n")
      assert written.content == "alpha\nbeta\ngamma\n"
      assert served!(user, vault, "a.md") == "alpha\nbeta\ngamma\n"
    end

    # The snapshot fence catches a second writer of the same text from the
    # same base: it re-reads, finds the text there and writes nothing.
    test "the same write committing under another writer lands once", %{user: user, vault: vault} do
      on!()
      create!(user, vault, "c.md", "base\n")

      arm_hook(fn
        :after_note_read ->
          unless Process.put(:raced, true),
            do: {:ok, _} = write(user, vault, "c.md", "base\nadded\n")

        _ ->
          :ok
      end)

      assert {:ok, _} = write(user, vault, "c.md", "base\nadded\n")
      assert served!(user, vault, "c.md") == "base\nadded\n"
    end

    # The doc (snapshot plus tail) already holds the pushed text, the row does
    # not. Red-first on 02c420935: the reply was the stale row (idempotent
    # repush), whose hash a client then sent back as a base and got a 409.
    test "a push the tail already holds answers with what a read serves",
         %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "t.md", "alpha\n")
      tail_edit!(user, vault, note.id, &(&1 <> "beta\n"))

      assert {:ok, reply} = write(user, vault, "t.md", "alpha\nbeta\n")
      {:ok, read} = Notes.get_note(user, vault, "t.md")

      assert reply.content == "alpha\nbeta\n"
      assert {reply.content_hash, reply.version} == {read.content_hash, read.version}
    end

    test "the reply's content_hash and version are what the next read serves",
         %{user: user, vault: vault} do
      on!()
      create!(user, vault, "h.md", "one\n")
      {:ok, written} = write(user, vault, "h.md", "one\ntwo\n")
      {:ok, read} = Notes.get_note(user, vault, "h.md")
      assert {written.content_hash, written.version} == {read.content_hash, read.version}
    end
  end

  describe "atomicity" do
    # Red-first against the previous revision of this path, whose write was a
    # checkpoint that rescued its own raise and let the transaction commit
    # half: a notes row with a new nonce over the old note_bodies ciphertext.
    test "a raise after the row update leaves notes and note_bodies unchanged",
         %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "r.md", "zero\n")

      # The seam sits on the path this write takes: the same write without the
      # raise is an ops-path write (its post-write step runs).
      ref = attach_written()
      assert {:ok, _} = write(user, vault, "r.md", "before\n")
      assert_received {:crdt_written, ^ref, _}

      body_before = Fixtures.raw_note!(note.id)
      row_before = notes_row(note.id)

      arm_hook(fn
        :after_fenced_write -> raise "injected"
        _ -> :ok
      end)

      assert_raise RuntimeError, "injected", fn -> write(user, vault, "r.md", "after\n") end

      body_after = Fixtures.raw_note!(note.id)
      row_after = notes_row(note.id)

      assert Map.take(body_after, [:content_hash, :crdt_state_nonce, :crdt_state_ciphertext, :seq]) ==
               Map.take(body_before, [
                 :content_hash,
                 :crdt_state_nonce,
                 :crdt_state_ciphertext,
                 :seq
               ])

      assert row_after == row_before

      assert served!(user, vault, "r.md") == "before\n"
    end

    # Only writes run under the vault seq lock: the diff, the doc load and the
    # encryption run before it. Counted from the `change_seq` UPDATE (the
    # vault lock) to the end of the call: the row update, its body, history
    # and the embed outbox job.
    test "no tail read or doc load runs under the vault lock", %{user: user, vault: vault} do
      on!()
      create!(user, vault, "l.md", @text)
      {:ok, _} = write(user, vault, "l.md", "warm\n" <> @text)

      queries =
        TenantQueryCounter.count_matching_queries(
          fn -> {:ok, _} = write(user, vault, "l.md", "warm\nmore\n" <> @text) end,
          &is_binary/1
        )

      {_before, under_lock} =
        Enum.split_while(queries, &(not (&1 =~ "UPDATE vaults SET change_seq")))

      assert [_lock | after_lock] = under_lock
      refute Enum.any?(after_lock, &(&1 =~ "crdt_update_log"))
      assert length(after_lock) <= 8
    end
  end

  describe "the post-write step and the switch" do
    test "runs once, after a write that applied ops", %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "seam.md", "one\n")
      ref = attach_written()

      assert {:ok, _} = write(user, vault, "seam.md", "one\ntwo\n")

      assert_received {:crdt_written, ^ref, %{note_id: id}}
      assert id == note.id
      refute_received {:crdt_written, ^ref, _}
    end

    test "an unchanged re-push writes nothing and runs no post-write step",
         %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "n.md", "same\n")
      before = Fixtures.raw_note!(note.id)
      ref = attach_written()

      assert {:ok, _} = write(user, vault, "n.md", "same\n")

      after_ = Fixtures.raw_note!(note.id)
      assert {after_.seq, after_.version} == {before.seq, before.version}
      refute_received {:crdt_written, ^ref, _}
    end

    test "rmw_note/5 (an MCP edit) goes through it", %{user: user, vault: vault} do
      on!()
      create!(user, vault, "r.md", "head\n")
      ref = attach_written()

      assert {{:ok, note}, _} =
               Notes.rmw_note(user, vault, "r.md", &(&1 <> "tail\n"), actor: "mcp")

      assert note.content == "head\ntail\n"
      assert_received {:crdt_written, ^ref, _}
    end

    test "switch off: the snapshot path, no post-write step", %{user: user, vault: vault} do
      create!(user, vault, "off.md", "one\n")
      ref = attach_written()

      assert {:ok, note} = write(user, vault, "off.md", "one\ntwo\n")
      assert note.content == "one\ntwo\n"
      refute_received {:crdt_written, ^ref, _}
    end
  end

  describe "rooms" do
    # Mutation-checked: swapping the non-creating CrdtRegistry.lookup/1 in
    # CrdtWrite for ensure_started/3 turns it red.
    test "no room is started by a write", %{user: user, vault: vault} do
      on!()
      notes = for n <- 1..20, do: create!(user, vault, "r#{n}.md", "v1\n")
      active = fn -> DynamicSupervisor.count_children(Engram.Notes.CrdtDocSupervisor).active end
      before = active.()

      for n <- notes, do: {:ok, _} = write(user, vault, n.path, "v1\nv2\n")

      assert active.() == before
      assert Enum.all?(notes, &is_nil(CrdtRegistry.lookup(&1.id)))
    end

    # Red-first with the switch off: the room holds an edit whose tail append
    # has not landed, the push echoes it, and the stored doc (which lacks it)
    # diffs it in a second time, which the room then unions with its own.
    test "a push echoing a room edit not yet in the tail leaves one copy",
         %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "echo.md", "x\n")
      room = live_room!(user, vault, note)

      prev = Application.get_env(:engram, :crdt_tail_append_fault)
      Application.put_env(:engram, :crdt_tail_append_fault, fn -> {:error, :injected} end)

      :ok =
        CrdtRoom.update_doc(room, fn doc -> CrdtBridge.ingest_plaintext(doc, "x\nEDIT\n") end,
          metadata: []
        )

      Application.put_env(:engram, :crdt_tail_append_fault, prev)

      assert {:ok, _} = write(user, vault, "echo.md", "x\nEDIT\nmore\n")

      assert room_text(room) == "x\nEDIT\nmore\n"
      assert served!(user, vault, "echo.md") == "x\nEDIT\nmore\n"
    end

    # One frame per write: the room takes in (and appends) exactly one update, and
    # rapid writes converge without doubling (crdt-lineage-doubling.md).
    test "a live room gets each write once and rapid writes do not double",
         %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "live.md", "Iteration 0\n")
      room = live_room!(user, vault, note)

      ref = attach_appends()

      for i <- 1..10 do
        assert {:ok, _} = write(user, vault, "live.md", "Iteration #{i}\n")
        assert room_text(room) == "Iteration #{i}\n"
        assert drain(ref) == 1
      end

      assert served!(user, vault, "live.md") == "Iteration 10\n"
    end

    # A room that raises (or times out) wrote nothing we can rely on: the write
    # reads again once, then answers a conflict (a 409 the writer retries)
    # instead of an opaque error. Nothing lands beside the room.
    test "a room that raises answers a version conflict, not a crash",
         %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "raise.md", "x\n")
      room = live_room!(user, vault, note)
      real_doc = :sys.get_state(room).doc
      :sys.replace_state(room, &%{&1 | doc: :not_a_doc})

      assert {:error, :version_conflict, conflict} = write(user, vault, "raise.md", "x\ny\n")
      assert conflict.id == note.id

      :sys.replace_state(room, &%{&1 | doc: real_doc})
      assert served!(user, vault, "raise.md") == "x\n"
    end

    # Red-first without the delivery fix: the result hashes like the row (the
    # facade never held the tail edit), so nothing was broadcast and the room
    # kept the edit the server had just dropped.
    test "an rmw that reverts a pending tail edit still reaches the room",
         %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "rev.md", "a\n")
      tail_edit!(user, vault, note.id, &(&1 <> "b\n"))
      room = live_room!(user, vault, note)
      assert room_text(room) == "a\nb\n"

      assert {{:ok, _}, _} =
               Notes.rmw_note(user, vault, "rev.md", &String.replace(&1, "b\n", ""), actor: "mcp")

      assert served!(user, vault, "rev.md") == "a\n"
      assert room_text(room) == "a\n"
    end
  end

  describe "cost per write" do
    # Constant in the vault: the statements a write issues do not grow with
    # the number of other notes. Cap: 20 per markdown update.
    test "the statement count does not depend on vault size", %{user: user, vault: vault} do
      on!()
      create!(user, vault, "x.md", "one\n")
      # Warm the per-node caches (user, entitlements, overrides) the first
      # write fills, so both measurements see the same cache state.
      {:ok, _} = write(user, vault, "x.md", "zero\n")
      small = statements(fn -> write(user, vault, "x.md", "one\ntwo\n") end)

      for n <- 1..30, do: create!(user, vault, "f#{n}.md", "filler #{n}\n")
      large = statements(fn -> write(user, vault, "x.md", "one\ntwo\nthree\n") end)

      assert small == large
      assert small <= 20
    end
  end

  defp statements(fun),
    do:
      length(TenantQueryCounter.count_matching_queries(fn -> {:ok, _} = fun.() end, &is_binary/1))
end
