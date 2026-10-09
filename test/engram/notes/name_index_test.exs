defmodule Engram.Notes.NameIndexTest do
  use Engram.DataCase, async: false

  import Engram.Fixtures, only: [insert_note!: 3]

  alias Engram.Notes
  alias Engram.Notes.NameIndex

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    insert_note!(user, vault, path: "Projects/Engram.md", title: "Engram", content: "x")
    insert_note!(user, vault, path: "Daily/2026-10-09.md", title: "Thursday", content: "x")
    on_exit(fn -> NameIndex.clear() end)
    %{user: user, vault: vault}
  end

  defp paths(user, vault, q) do
    {:ok, paths, _total} = NameIndex.search(user, vault, q, 100)
    paths
  end

  defp tree_rows(user, vault),
    do: Repo.with_tenant!(user.id, fn -> Notes.raw_tree_note_rows(user, vault) end)

  defp put_building(vault, user, builder, started \\ System.monotonic_time(:millisecond)) do
    ref = Process.monitor(builder)

    :sys.replace_state(NameIndex, fn state ->
      put_in(state.building[vault.id], %{
        builder: {builder, ref},
        user_id: user.id,
        waiters: [],
        events: [],
        started: started
      })
    end)
  end

  # Patches arrive as PubSub messages to the owner; give them a moment.
  defp eventually(fun, tries \\ 50) do
    if fun.() or tries == 0,
      do: assert(fun.()),
      else: Process.sleep(20) && eventually(fun, tries - 1)
  end

  test "fuzzy search over paths and titles", %{user: user, vault: vault} do
    assert paths(user, vault, "engr") == ["Projects/Engram.md"]
    assert paths(user, vault, "prjeng") == ["Projects/Engram.md"]
    assert paths(user, vault, "thursday") == ["Daily/2026-10-09.md"]
    assert paths(user, vault, "zzzz") == []
  end

  test "a rename is reflected without a rebuild", %{user: user, vault: vault} do
    assert paths(user, vault, "engr") == ["Projects/Engram.md"]
    {:ok, _} = Notes.rename_note(user, vault, "Projects/Engram.md", "Archive/Memory.md")

    eventually(fn -> paths(user, vault, "memory") == ["Archive/Memory.md"] end)
    assert paths(user, vault, "projects") == []
  end

  test "a new note and a delete are reflected", %{user: user, vault: vault} do
    assert paths(user, vault, "daily") == ["Daily/2026-10-09.md"]

    {:ok, _} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "Ideas/Fresh.md", "content" => "y", "mtime" => 1.0},
        actor: "api"
      )

    eventually(fn -> paths(user, vault, "fresh") == ["Ideas/Fresh.md"] end)

    _ = Notes.delete_note(user, vault, "Daily/2026-10-09.md")
    eventually(fn -> paths(user, vault, "daily") == [] end)
  end

  test "a burst on a cold vault builds once", %{user: user, vault: vault} do
    me = self()
    handler = "name-index-build-#{inspect(me)}"

    :telemetry.attach(
      handler,
      [:engram, :nif, :call, :stop],
      fn
        _, _, %{nif: :name_index_build}, _ -> send(me, :built)
        _, _, _, _ -> :ok
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    tasks =
      for _ <- 1..10 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, me, self())
          NameIndex.search(user, vault, "engr", 10)
        end)
      end

    results = Task.await_many(tasks, 30_000)

    assert_received :built
    refute_received :built

    # Only the newest of the waiting searches runs; the rest stand down.
    assert Enum.any?(results, &match?({:ok, ["Projects/Engram.md"], 1}, &1))
    assert Enum.all?(results, &(match?({:ok, _, _}, &1) or &1 == :superseded))
  end

  test "users never see each other's names" do
    other = insert(:user)
    {:ok, other} = Engram.Crypto.ensure_user_dek(other)
    {:ok, ov, _} = Engram.Vaults.register_vault(other, "Other", Ecto.UUID.generate())
    insert_note!(other, ov, path: "Secret/Plan.md", content: "x")

    assert paths(other, ov, "plan") == ["Secret/Plan.md"]
    assert paths(other, ov, "engr") == []
  end

  test "a note created in Obsidian (CRDT genesis) reaches the index", %{user: user, vault: vault} do
    assert paths(user, vault, "obsidian") == []

    {:ok, _} =
      Notes.genesis_crdt_note(user, vault, Ecto.UUID.generate(), "Inbox/From Obsidian.md")

    eventually(fn -> paths(user, vault, "obsidian") == ["Inbox/From Obsidian.md"] end)
  end

  test "announce/4 patches a cached index (checkpoint title changes)", %{user: user, vault: vault} do
    assert paths(user, vault, "renamedtitle") == []
    [{_, raw, _, _, _, _, _} | _] = tree_rows(user, vault)
    {:ok, id} = Ecto.UUID.load(raw)
    {:ok, note} = Notes.get_note_by_id(user, vault, id)

    NameIndex.announce(vault.id, id, note.path, "RenamedTitle")
    eventually(fn -> paths(user, vault, "renamedtitle") == [note.path] end)
  end

  test "changes during a build are buffered and replayed", %{user: user, vault: vault} do
    # Hold the vault mid-build with a stand-in builder, then land a change.
    builder = spawn(fn -> Process.sleep(:infinity) end)
    put_building(vault, user, builder)
    # The stand-in never subscribed the owner, so deliver the event directly.
    send(NameIndex, {:name_index_put, vault.id, Ecto.UUID.generate(), "Late/Arrival.md", ""})
    :sys.get_state(NameIndex)

    {:ok, dek} = Engram.Crypto.get_dek(user)
    bound = Engram.Crypto.row_version_aad_bound()

    rows =
      for {_, raw, v, ct, nonce, _, _} <- tree_rows(user, vault),
          do: {raw, v >= bound, ct, nonce, nil, nil}

    {:ok, handle, bytes} =
      Engram.Native.name_index_build(
        dek,
        Engram.Crypto.aad_prefix(:notes, :path),
        Engram.Crypto.aad_prefix(:notes, :title),
        rows
      )

    :ok = GenServer.call(NameIndex, {:built, vault.id, handle, bytes})
    assert paths(user, vault, "arrival") == ["Late/Arrival.md"]
    assert paths(user, vault, "engr") == ["Projects/Engram.md"]
  end

  test "a builder that dies leaves no subscription behind", %{user: user, vault: vault} do
    owner = Process.whereis(NameIndex)
    topic = "sync:#{user.id}:#{vault.id}"

    for _ <- 1..3 do
      {pid, ref} =
        spawn_monitor(fn -> :build = GenServer.call(NameIndex, {:claim, user.id, vault.id}) end)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}
    end

    # The owner's own DOWN races our messages (different senders): poll.
    eventually(fn ->
      not Enum.any?(Registry.lookup(Engram.PubSub, topic), fn {p, _} -> p == owner end) and
        :sys.get_state(NameIndex).building == %{}
    end)
  end

  test "latest-wins is per client: another client is never superseded", %{
    user: user,
    vault: vault
  } do
    {:ok, _, _} = NameIndex.search(user, vault, "engr", 10, :client_a)
    assert {:ok, ["Projects/Engram.md"], 1} = NameIndex.search(user, vault, "engr", 10, :client_b)
  end

  test "an oversized query is cut, not run whole" do
    me = self()
    handler = "name-query-bound-#{inspect(me)}"

    :telemetry.attach(
      handler,
      [:engram, :nif, :call, :stop],
      fn
        _, m, %{nif: :name_index_search}, _ -> send(me, {:searched, m.input_bytes})
        _, _, _, _ -> :ok
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, h, _} = Engram.Native.name_index_build(:crypto.strong_rand_bytes(32), "", "", [])

    # 2,000 atoms took 4 s at 50k names before the bound. Ends mid-codepoint too.
    query = String.duplicate("a ", 5_000) <> <<0xE2, 0x82>>
    {[], 0} = Engram.Native.name_index_search(h, query, 10_000)

    assert_received {:searched, bytes}
    assert bytes <= 16, "8 one-letter words, got #{bytes} bytes"
  end

  test "a claim that timed out is withdrawn, so the vault is not wedged", %{
    user: user,
    vault: vault
  } do
    me = self()
    :sys.suspend(NameIndex)

    # A caller that stays alive (a keep-alive connection) and gives up early.
    caller =
      spawn(fn ->
        try do
          GenServer.call(NameIndex, {:claim, user.id, vault.id}, 50)
        catch
          :exit, {:timeout, _} -> GenServer.cast(NameIndex, {:cancel, vault.id, self()})
        end

        send(me, :gave_up)
        Process.sleep(:infinity)
      end)

    assert_receive :gave_up, 1_000
    :sys.resume(NameIndex)
    :sys.get_state(NameIndex)

    assert paths(user, vault, "engr") == ["Projects/Engram.md"]
    Process.exit(caller, :kill)
  end

  test "a builder stuck past the timeout is replaced", %{user: user, vault: vault} do
    stuck = spawn(fn -> Process.sleep(:infinity) end)
    put_building(vault, user, stuck, System.monotonic_time(:millisecond) - 31_000)

    assert paths(user, vault, "engr") == ["Projects/Engram.md"]
    Process.exit(stuck, :kill)
  end

  test "the cached index keeps answering while a rebuild runs", %{user: user, vault: vault} do
    assert paths(user, vault, "engr") == ["Projects/Engram.md"]
    rebuilding = spawn(fn -> Process.sleep(:infinity) end)
    put_building(vault, user, rebuilding)

    # Would block for the 30 s build timeout if it waited on the rebuild.
    {micros, result} = :timer.tc(fn -> NameIndex.search(user, vault, "engr", 10) end)
    assert {:ok, ["Projects/Engram.md"], 1} = result
    assert micros < 5_000_000
    Process.exit(rebuilding, :kill)
  end

  test "a checkpoint that changes the title announces it after commit", %{
    user: user,
    vault: vault
  } do
    Phoenix.PubSub.subscribe(Engram.PubSub, "name_index:#{vault.id}")

    # No heading: the title is the filename until the merged edit adds one.
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Ck/Note.md", "content" => "plain body\n"},
        actor: "api"
      )

    doc = Engram.Notes.CrdtBridge.new_doc()
    text = Yex.Doc.get_text(doc, Engram.Notes.CrdtBridge.text_name())
    Yex.Text.insert(text, 0, "# After Heading\nbody")

    :ok = Engram.Notes.CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    note_id = note.id
    assert_receive {:name_index_put, _, ^note_id, "Ck/Note.md", title}, 2_000
    assert title =~ "After"
  end

  describe "native" do
    test "batch decrypt matches per-row decrypt, and fails whole on a bad row", %{
      user: user,
      vault: vault
    } do
      rows = Repo.with_tenant!(user.id, fn -> Notes.raw_tree_note_rows(user, vault) end)
      {:ok, dek} = Engram.Crypto.get_dek(user)

      batch = Notes.decrypt_tree_note_rows(rows, dek) |> Enum.map(& &1.path) |> Enum.sort()
      assert batch == ["Daily/2026-10-09.md", "Projects/Engram.md"]

      [{_, raw, v, ct, nonce, _, _} | _] = rows
      prefix = Engram.Crypto.aad_prefix(:notes, :path)
      bound = Engram.Crypto.row_version_aad_bound()

      assert {:ok, [_]} =
               Engram.Crypto.Envelope.decrypt_many(dek, prefix, [{raw, v >= bound, ct, nonce}])

      assert :error =
               Engram.Crypto.Envelope.decrypt_many(dek, prefix, [
                 {:crypto.strong_rand_bytes(16), true, ct, nonce}
               ])
    end

    test "search and batch decrypt do not leak native memory", %{user: user, vault: vault} do
      {:ok, _, _} = NameIndex.search(user, vault, "engr", 10)
      [{_, _, handle, _, _, _}] = :ets.lookup(:engram_name_index, vault.id)

      Engram.NativeLeak.assert_no_leak(fn ->
        Engram.Native.name_index_search(handle, "eng", 10)
      end)

      rows = Repo.with_tenant!(user.id, fn -> Notes.raw_tree_note_rows(user, vault) end)
      {:ok, dek} = Engram.Crypto.get_dek(user)
      Engram.NativeLeak.assert_no_leak(fn -> Notes.decrypt_tree_note_rows(rows, dek) end)
    end
  end
end
