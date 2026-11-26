defmodule Engram.KeywordStore.TantivyBulkTest do
  @moduledoc """
  The kwsearch bulk path (roadmap P2 tasks 3 and 5, security F2/F3): the
  locked read and its stamps (the Elixir half of the bulk ordering contract;
  kwsearch's half is `native/kwsearch` `shard_tests`), what a push sends, the
  reconcile walk (full load, diff, orphan repair, rebuild hand-off), the
  Welcome note guard, one tokenizing pass, stamped-or-absent bare deletes,
  and the shadow compare. kwsearch and the vector store are Bypass stubs.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.RlsCase
  import Mox

  alias Engram.Indexing
  alias Engram.KeywordStore.Shadow
  alias Engram.KeywordStore.Tantivy.Bulk
  alias Engram.KeywordStore.Tantivy.Feed
  alias Engram.Maintenance.Cursor
  alias Engram.Notes
  alias Engram.ServiceConfig
  alias Engram.Vaults.WelcomeNote
  alias Engram.Workers.ReconcileKeywordIndex

  setup :verify_on_exit!

  @key "test-token-key-0123456789abcdef01234567"
  @ops Feed.ops()

  setup do
    qdrant = Bypass.open()
    kw = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{qdrant.port}")
    ServiceConfig.put_override(:keyword_feed, true)

    ServiceConfig.put_override(:kwsearch,
      url: "http://localhost:#{kw.port}",
      allow_http: true,
      token_keys: [@key],
      timeout_ms: 5_000
    )

    Bypass.stub(qdrant, :any, :any, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

      if String.ends_with?(conn.request_path, "/points/query"),
        do: json(conn, 200, %{"result" => %{"points" => []}}),
        else: json(conn, 200, %{"result" => true})
    end)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)
    %{kw: kw, qdrant: qdrant, user: user, vault: vault}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  # kwsearch stub: `/notes` answers `listing` (`[[note, vault, count]]`),
  # `/bulk` records each request body, `/cursor` reports `epoch`.
  defp kwsearch(kw, listing \\ [], epoch \\ %{"epoch" => "e1", "rebuilding" => true}) do
    test_pid = self()

    Bypass.stub(kw, :any, :any, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 20_000_000)
      ["Bearer " <> token] = Plug.Conn.get_req_header(conn, "authorization")
      body = if raw == "", do: nil, else: Jason.decode!(raw)

      case conn.request_path do
        "/bulk" ->
          send(test_pid, {:bulk, token, body})
          notes = length(body["notes"])
          json(conn, 200, %{"applied" => notes, "stale" => 0, "tomb" => 0, "malformed" => 0})

        "/notes" ->
          json(conn, 200, %{"notes" => listing})

        "/cursor" ->
          json(conn, 200, Map.merge(%{"xid" => "1", "seq" => 1}, epoch))

        "/rebuilt" ->
          send(test_pid, {:rebuilt, body["epoch"]})
          json(conn, 200, %{"ok" => true})
      end
    end)
  end

  defp indexed_note!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => 1.0},
        actor: "api"
      )

    {:ok, _} = Indexing.index_note(note, vault)
    note
  end

  defp chunk_points(note) do
    %{rows: rows} =
      Repo.query!(
        "SELECT qdrant_point_id::text FROM chunks WHERE note_id = $1 AND qdrant_point_id IS NOT NULL",
        [Ecto.UUID.dump!(note.id)]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp feed_count, do: hd(hd(Repo.query!("SELECT count(*) FROM keyword_feed").rows))

  defp feed_rows(note_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT op, stamp FROM keyword_feed WHERE note_id = $1 ORDER BY xid, seq",
        [Ecto.UUID.dump!(note_id)]
      )

    for [op, stamp] <- rows, do: %{op: op, stamp: stamp}
  end

  defp pushed_notes do
    receive do
      {:bulk, _token, body} -> body["notes"] ++ pushed_notes()
    after
      0 -> []
    end
  end

  defp keep(n), do: n["keep_b64"] |> Base.decode64!() |> ids()
  defp ids(<<>>), do: []
  defp ids(<<id::binary-16, rest::binary>>), do: [Ecto.UUID.load!(id) | ids(rest)]

  describe "the locked read (ordering against live traffic)" do
    test "the batch's stamp sits between the passes before and after its read", %{
      user: user,
      vault: vault
    } do
      note = indexed_note!(user, vault, "Iron.md", "# Iron\n\nFerritin levels are low.")
      [before | _] = feed_rows(note.id) |> Enum.map(& &1.stamp)

      read = Bulk.read(to_string(user.id), [note.id])
      bulk = read.stamps[note.id]
      assert bulk > before, "a pass committed before the read must be older than the batch"

      # A live edit and a trash after the read: both newer than the batch,
      # so kwsearch drops the batch against either (Shard::bulk).
      scope = %{user_id: user.id, vault_id: vault.id, note_id: note.id}
      :ok = Feed.note_pass(scope, :current, [])
      :ok = Feed.delete_note(scope)
      after_read = note.id |> feed_rows() |> Enum.map(& &1.stamp) |> Enum.filter(&(&1 > before))
      assert length(after_read) >= 2 and Enum.all?(after_read, &(&1 > bulk))

      assert Enum.sort(Enum.map(Map.fetch!(read.rows, note.id), &elem(&1, 1))) ==
               chunk_points(note)

      assert is_integer(read.xmax) and read.xmax > 0
    end

    test "RLS: as engram_app the read sees the user's rows under its own tenant", %{
      user: user,
      vault: vault
    } do
      note = indexed_note!(user, vault, "Iron.md", "# Iron\n\nFerritin levels are low.")
      assert chunk_points(note) != []

      assert {:returned, read} = as_prod_role(fn -> Bulk.read(to_string(user.id), [note.id]) end)
      assert Map.has_key?(read.notes, note.id)
      assert length(Map.fetch!(read.rows, note.id)) == length(chunk_points(note))
    end

    test "CONTROL: engram_app with no tenant sees zero chunk and note rows", %{
      user: user,
      vault: vault
    } do
      _note = indexed_note!(user, vault, "Iron.md", "# Iron\n\nFerritin levels are low.")

      assert {:returned, [[0, 0]]} =
               as_prod_role(fn ->
                 Repo.query!("SELECT (SELECT count(*) FROM chunks), (SELECT count(*) FROM notes)").rows
               end)
    end
  end

  describe "push and the reconcile walk" do
    test "a full load pushes every note whole through /bulk and writes no keyword_feed row (F2)",
         %{kw: kw, user: user, vault: vault} do
      a = indexed_note!(user, vault, "A.md", "# A\n\nFerritin levels are low.\n\n## B\n\nIron.")
      b = indexed_note!(user, vault, "B.md", "# B\n\nMagnesium.")
      kwsearch(kw)
      before = feed_count()

      assert :ok = ReconcileKeywordIndex.sync_user(to_string(user.id), "full")
      assert feed_count() == before, "the backfill wrote keyword_feed rows"

      pushed = Map.new(pushed_notes(), &{&1["note"], &1})
      assert Map.keys(pushed) |> Enum.sort() == Enum.sort([a.id, b.id])

      for note <- [a, b] do
        n = pushed[note.id]
        assert Enum.sort(keep(n)) == chunk_points(note)
        assert Enum.sort(Enum.map(n["docs"], & &1["point"])) == chunk_points(note)
        assert Enum.all?(n["docs"], &(byte_size(Base.decode64!(&1["terms_b64"])) > 0))
        assert n["vault"] == vault.id and n["stamp"] > 0 and n["xmax"] > 0
      end

      assert_received_nothing_else()
    end

    test "the token names the user; the body never does", %{kw: kw, user: user, vault: vault} do
      _ = indexed_note!(user, vault, "A.md", "# A\n\nFerritin.")
      kwsearch(kw)
      :ok = ReconcileKeywordIndex.sync_user(to_string(user.id), "full")
      assert_received {:bulk, token, body}
      refute Map.has_key?(body, "user")

      assert {:ok, %{"s" => "bulk", "u" => u}} =
               Engram.KeywordStore.Tantivy.Token.verify(token, [@key])

      assert u == to_string(user.id)
    end

    test "diff: only notes whose counts differ, and kwsearch's orphans with an empty set",
         %{kw: kw, user: user, vault: vault} do
      a = indexed_note!(user, vault, "A.md", "# A\n\nFerritin levels are low.")
      b = indexed_note!(user, vault, "B.md", "# B\n\nMagnesium.")
      c = indexed_note!(user, vault, "C.md", "# C\n\nZinc.")
      :ok = Notes.delete_note(user, vault, "C.md")
      gone = Ecto.UUID.generate()

      kwsearch(kw, [
        [a.id, vault.id, length(chunk_points(a))],
        [b.id, vault.id, 0],
        [c.id, vault.id, 1],
        [gone, vault.id, 2]
      ])

      :ok = ReconcileKeywordIndex.sync_user(to_string(user.id), "diff")
      pushed = Map.new(pushed_notes(), &{&1["note"], &1})

      assert Enum.sort(Map.keys(pushed)) == Enum.sort([b.id, c.id, gone]),
             "an equal count is left alone"

      assert Enum.sort(keep(pushed[b.id])) == chunk_points(b)
      # The trashed note and the vanished one: their docs go (orphan pass).
      for id <- [c.id, gone],
          do: assert(pushed[id]["keep_b64"] == "" and pushed[id]["docs"] == [])
    end

    test "a full walk over every user tells a rebuilding kwsearch, then idles", %{
      kw: kw,
      user: user,
      vault: vault
    } do
      _ = indexed_note!(user, vault, "A.md", "# A\n\nFerritin.")
      kwsearch(kw)
      epoch = %{id: "e1", rebuilding: true}

      assert ReconcileKeywordIndex.run(epoch, 1_000) == :done
      assert_received {:rebuilt, "e1"}
      assert [_ | _] = pushed_notes()

      assert %{"target" => "e1:1", "mode" => "full", "done_at" => 1_000} =
               Cursor.get("keyword_reconcile")

      assert ReconcileKeywordIndex.run(%{epoch | rebuilding: false}, 2_000) == :idle
      assert pushed_notes() == []

      # A new epoch (a gap, a new index) is a full reload with no operator step.
      assert ReconcileKeywordIndex.run(%{id: "e2", rebuilding: true}, 3_000) == :done
      assert_received {:rebuilt, "e2"}
      assert [_ | _] = pushed_notes()
      # A day later: a diff walk.
      assert ReconcileKeywordIndex.run(%{id: "e2", rebuilding: false}, 3_000 + 86_400) == :done
      refute_received {:rebuilt, _}
    end

    test "a user mid DEK rotation halts the walk before it can report done", %{
      kw: kw,
      user: user
    } do
      kwsearch(kw)

      Repo.update_all(Engram.Accounts.User |> where(id: ^user.id),
        set: [dek_rotation_locked_at: DateTime.utc_now()]
      )

      assert ReconcileKeywordIndex.run(%{id: "e1", rebuilding: true}, 1_000) == :halted
      refute_received {:rebuilt, _}
      refute Map.has_key?(Cursor.get("keyword_reconcile") || %{}, "done_at")
    end

    test "off by default: no feed, no walk", %{kw: kw} do
      ServiceConfig.put_override(:keyword_feed, false)
      kwsearch(kw)
      assert :ok = perform_job(ReconcileKeywordIndex, %{})
      assert Cursor.get("keyword_reconcile") == nil
    end
  end

  describe "the Welcome note (security F3)" do
    test "unedited it has no keyword terms anywhere; once edited it does", %{
      kw: kw,
      user: user,
      vault: vault
    } do
      seed = WelcomeNote.content()
      note = indexed_note!(user, vault, WelcomeNote.path(), seed)
      assert chunk_points(note) != [], "precondition: the note has chunk rows"

      ops = note.id |> feed_rows() |> Enum.map(& &1.op)
      assert @ops.delete_note_except in ops
      refute @ops.upsert in ops, "the seeded Welcome note wrote keyword terms"

      kwsearch(kw)
      :ok = ReconcileKeywordIndex.sync_user(to_string(user.id), "full")
      assert [%{"docs" => []}] = pushed_notes()

      edited = indexed_note!(user, vault, WelcomeNote.path(), seed <> "\n\nMy own line.")
      assert @ops.upsert in Enum.map(feed_rows(edited.id), & &1.op)

      :ok = ReconcileKeywordIndex.sync_user(to_string(user.id), "full")
      [n] = pushed_notes()
      assert Enum.sort(Enum.map(n["docs"], & &1["point"])) == chunk_points(edited)
    end

    test "unedited?/1: the seed's body under any frontmatter, nothing else" do
      seed = WelcomeNote.content(~D[2026-01-02])
      assert WelcomeNote.unedited?(%{path: WelcomeNote.path(), content: seed})
      # The store rewrites the frontmatter block (flow list to block list).
      stored = String.replace(seed, "tags: [example]", "tags:\n  - example", global: false)

      assert stored != seed and
               WelcomeNote.unedited?(%{path: WelcomeNote.path(), content: stored})

      refute WelcomeNote.unedited?(%{path: WelcomeNote.path(), content: seed <> "x"})
      refute WelcomeNote.unedited?(%{path: "Other.md", content: seed})
    end
  end

  describe "index pass" do
    test "one tokenizing pass: feed entries carry the encoder's terms, never the text (review #13)",
         %{user: user, vault: vault} do
      Engram.KeywordStoreRecorder.install()
      _ = indexed_note!(user, vault, "Iron.md", "# Iron\n\nFerritin levels are low.")
      assert_received {:keyword_store, :index, [_scope, [_ | _] = entries]}
      assert Enum.all?(entries, &(is_binary(&1.terms) and not Map.has_key?(&1, :text)))
    end

    test "an edit's stale points write no unstamped bare point delete (review #16)", %{
      user: user,
      vault: vault
    } do
      note = indexed_note!(user, vault, "Iron.md", "# Iron\n\nFerritin.\n\n## Two\n\nMagnesium.")
      _ = indexed_note!(user, vault, "Iron.md", "# Iron\n\nFerritin.\n\n## Two\n\nZinc instead.")
      ops = note.id |> feed_rows() |> Enum.map(& &1.op)
      assert Enum.count(ops, &(&1 == @ops.delete_note_except)) == 2

      %{rows: [[bare]]} =
        Repo.query!("SELECT count(*) FROM keyword_feed WHERE op = $1", [@ops.delete_points])

      assert bare == 0
    end
  end

  describe "shadow compare (P2 task 8)" do
    setup %{user: user} do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "shadow-#{inspect(ref)}",
        [:engram, :search, :keyword_shadow],
        fn _e, m, meta, _ -> send(test_pid, {:shadow, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("shadow-#{inspect(ref)}") end)
      %{opts: [user_id: user.id, limit: 5]}
    end

    test "overlap: the share of the sparse top 10 kwsearch also found" do
      set = &MapSet.new/1
      assert Shadow.overlap(set.(~w(a b)), set.(~w(a b c d))) == 0.5
      assert Shadow.overlap(set.([]), set.([])) == 1.0
      assert Shadow.overlap(set.(~w(a)), set.([])) == 0.0
    end

    test "off by default: no compare runs, the search is unchanged", %{opts: opts} do
      assert ServiceConfig.get(:keyword_shadow_rate, 0.0) == 0.0
      assert :ok = Shadow.maybe_compare(%{indices: [1], values: [1.0]}, opts)
      refute_receive {:shadow, _, _}, 50
    end

    test "a kwsearch failure is a shadow error, never a live fallback", %{kw: kw, opts: opts} do
      Bypass.down(kw)
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :search, :keyword_fallback]])

      :ok =
        Shadow.compare(
          %{indices: [1], values: [1.0]},
          Keyword.put(opts, :vault_id, Ecto.UUID.generate())
        )

      assert_received {:shadow, %{overlap: +0.0}, %{outcome: :error}}
      refute_received {[:engram, :search, :keyword_fallback], ^ref, _, _}
    end
  end

  defp assert_received_nothing_else, do: refute_received({:bulk, _, _})
end
