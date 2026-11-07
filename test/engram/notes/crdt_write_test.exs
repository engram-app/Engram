defmodule Engram.Notes.CrdtWriteTest do
  # async: false: some tests start a real :global-registered room
  # (CrdtRegistry.ensure_started/3), the sandbox hazard documented in
  # Engram.DataCase.setup_sandbox/1 (#777).
  use Engram.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Fixtures, Notes, ServiceConfig, TenantQueryCounter}
  alias Engram.Notes.{CrdtBridge, CrdtPersistence, CrdtRegistry, CrdtWrite}
  alias Yex.Sync.SharedDoc

  # 300 lines, "row N: foo".
  @lines Enum.map(1..300, &"row #{&1}: foo\n")
  @text Enum.join(@lines)

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
    Notes.upsert_note(user, vault, %{"path" => path, "content" => text}, [actor: "mcp"] ++ opts)
  end

  defp served!(user, vault, path) do
    {:ok, note} = Notes.get_note(user, vault, path)
    note.content
  end

  # Snapshot plus tail: the doc a reader (or rmw) derives its text from.
  defp authority_doc!(user, note_id) do
    raw = Fixtures.raw_note!(note_id)
    {:ok, state} = Engram.Crypto.decrypt_crdt_state(raw, user)
    {:ok, doc} = CrdtBridge.doc_from_state(state)

    _ =
      Repo.with_tenant!(user.id, fn ->
        CrdtPersistence.replay_tail(doc, user, note_id, raw.vault_id)
      end)

    doc
  end

  # A client's edit landing in the tail roomless (as a disconnected device's
  # catch-up does): its own doc, its own client id, the one-span diff a
  # client makes for a word swap.
  defp tail_edit!(user, vault, note_id, fun) do
    doc = authority_doc!(user, note_id)
    sv = Yex.encode_state_vector!(doc)
    :ok = CrdtBridge.ingest_plaintext(doc, fun.(CrdtBridge.project_doc(doc)))
    delta = Yex.encode_state_as_update!(doc, sv)

    _ =
      CrdtPersistence.update_v1(
        %{user_id: user.id, vault_id: vault.id, note_id: note_id},
        delta,
        nil,
        doc
      )

    :ok
  end

  defp rewrite_2_and_200(text) do
    text
    |> String.replace("row 2: foo\n", "row 2: TWO\n")
    |> String.replace("row 200: foo\n", "row 200: TWO HUNDRED\n")
  end

  defp occurrences(text, part), do: length(String.split(text, part)) - 1

  describe "apply_text/4: a concurrent tail edit survives a rewrite" do
    # Mutation-checked: with the single-span diff (ingest_plaintext without
    # `diff: :hunks`) line 100 comes back as both "foo" and "bar"; authored
    # against the current doc instead of the base, the edit is reverted.
    test "an edit on line 100 landing after the read survives a rewrite of lines 2 and 200",
         %{user: user, vault: vault} do
      note = create!(user, vault, "big.md", @text)

      # The writer reads (rmw authority), then a device edits line 100.
      base = authority_doc!(user, note.id)
      new_text = rewrite_2_and_200(CrdtBridge.project_doc(base))
      tail_edit!(user, vault, note.id, &String.replace(&1, "row 100: foo", "row 100: bar"))

      row = Fixtures.raw_note!(note.id)

      assert {:ok, %{outcome: :applied}} =
               Repo.with_tenant!(user.id, fn ->
                 CrdtWrite.apply_text(user, row, new_text, actor: "mcp", base: {:doc, base})
               end)

      served = served!(user, vault, "big.md")
      assert occurrences(served, "row 100: bar\n") == 1
      assert occurrences(served, "row 100: foo") == 0
      assert served =~ "row 2: TWO\n"
      assert served =~ "row 200: TWO HUNDRED\n"
      assert occurrences(served, "row 150: foo\n") == 1
    end
  end

  describe "upsert_note/4 behind the switch" do
    # #2489: a no-base push of text that already holds an un-checkpointed
    # tail edit. The snapshot path diffed it against the snapshot, so the tail
    # edit and the push's copy of it both survived.
    test "a push that already carries a tail edit leaves one copy of it",
         %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "a.md", "alpha\n")
      tail_edit!(user, vault, note.id, &(&1 <> "beta\n"))

      assert {:ok, note} = write(user, vault, "a.md", "alpha\nbeta\ngamma\n")
      assert note.content == "alpha\nbeta\ngamma\n"
      assert served!(user, vault, "a.md") == "alpha\nbeta\ngamma\n"
    end

    test "the reply's content_hash is the hash the next read serves", %{user: user, vault: vault} do
      on!()
      create!(user, vault, "h.md", "one\n")
      {:ok, written} = write(user, vault, "h.md", "one\ntwo\n")
      {:ok, read} = Notes.get_note(user, vault, "h.md")
      assert written.content_hash == read.content_hash
      assert written.version == read.version
    end

    test "an unchanged re-push writes nothing", %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "n.md", "same\n")
      before = Fixtures.raw_note!(note.id)
      ref = attach_written()

      assert {:ok, _} = write(user, vault, "n.md", "same\n")

      after_ = Fixtures.raw_note!(note.id)
      assert {after_.seq, after_.version} == {before.seq, before.version}
      refute_received {:crdt_written, ^ref, _}
    end

    test "switch off: the write takes the snapshot path (no CrdtWrite step runs)",
         %{user: user, vault: vault} do
      create!(user, vault, "off.md", "one\n")
      ref = attach_written()

      assert {:ok, note} = write(user, vault, "off.md", "one\ntwo\n")
      assert note.content == "one\ntwo\n"
      refute_received {:crdt_written, ^ref, _}
    end

    test "the post-write seam runs once, after a successful write", %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "seam.md", "one\n")
      ref = attach_written()

      assert {:ok, _} = write(user, vault, "seam.md", "one\ntwo\n")

      assert_received {:crdt_written, ^ref, %{note_id: id}}
      assert id == note.id
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
  end

  describe "the head re-check under the lock" do
    # Two writers of the same text from the same base: the second must not
    # apply its own encoding of the same change, or the text doubles.
    # Mutation-checked: without the seq compare the second write applies.
    test "a write whose row moved since its read is refused, not applied twice",
         %{user: user, vault: vault} do
      note = create!(user, vault, "c.md", "base\n")
      stale = Fixtures.raw_note!(note.id)

      apply = fn row ->
        Repo.with_tenant!(user.id, fn ->
          CrdtWrite.apply_text(user, row, "base\nadded\n", actor: "mcp")
        end)
      end

      assert {:ok, %{outcome: :applied}} = apply.(stale)
      assert {:error, :stale_snapshot} = apply.(stale)
      assert served!(user, vault, "c.md") == "base\nadded\n"
    end
  end

  describe "rooms" do
    test "no room is started by a write", %{user: user, vault: vault} do
      on!()
      notes = for n <- 1..20, do: create!(user, vault, "r#{n}.md", "v1\n")
      active = fn -> DynamicSupervisor.count_children(Engram.Notes.CrdtDocSupervisor).active end
      before = active.()

      for n <- notes, do: {:ok, _} = write(user, vault, n.path, "v1\nv2\n")

      assert active.() == before
      assert Enum.all?(notes, &is_nil(CrdtRegistry.lookup(&1.id)))
    end

    test "a live room receives the write's ops, once, and rapid writes do not double",
         %{user: user, vault: vault} do
      on!()
      note = create!(user, vault, "live.md", "Iteration 0\n")
      {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)
      Sandbox.allow(Repo, self(), room)
      on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)

      for i <- 1..10 do
        text = "Iteration #{i}\n"
        assert {:ok, _} = write(user, vault, "live.md", text)
        assert CrdtBridge.project_doc(SharedDoc.get_doc(room)) == text
      end

      assert served!(user, vault, "live.md") == "Iteration 10\n"
    end
  end

  describe "cost per write" do
    # Constant in the vault: the statements a write issues do not grow with
    # the number of other notes. Cap: 40 statements per markdown update,
    # tail and checkpoint included.
    test "the statement count does not depend on vault size", %{user: user, vault: vault} do
      on!()
      create!(user, vault, "x.md", "one\n")
      small = statements(fn -> write(user, vault, "x.md", "one\ntwo\n") end)

      for n <- 1..30, do: create!(user, vault, "f#{n}.md", "filler #{n}\n")
      large = statements(fn -> write(user, vault, "x.md", "one\ntwo\nthree\n") end)

      assert small == large
      assert small <= 40
    end
  end

  defp statements(fun),
    do:
      length(TenantQueryCounter.count_matching_queries(fn -> {:ok, _} = fun.() end, &is_binary/1))

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
end
