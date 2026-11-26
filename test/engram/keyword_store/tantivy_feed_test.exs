defmodule Engram.KeywordStore.TantivyFeedTest do
  @moduledoc """
  The kwsearch feed's write side: `keyword_feed` rows and the
  `keyword_deletions` log, under enforced RLS (run as `engram_app` through
  `Engram.RlsCase`, docs/context/rls-enforcement-testing-traps.md), and the
  index pass writing its feed rows in the chunk-row transaction.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase
  import Mox

  alias Engram.Indexing
  alias Engram.KeywordStore
  alias Engram.KeywordStore.FeedKey
  alias Engram.KeywordStore.Tantivy
  alias Engram.KeywordStore.Tantivy.Feed
  alias Engram.Notes
  alias Engram.ServiceConfig

  setup :verify_on_exit!

  setup do
    ServiceConfig.put_override(:keyword_feed, true)
    a = insert(:user)
    b = insert(:user)
    %{a: a, va: insert(:vault, user: a), b: b, vb: insert(:vault, user: b)}
  end

  @ops Feed.ops()

  # Read back as the superuser: every row of the table, any tenant.
  defp feed_rows do
    %{rows: rows} =
      Repo.query!(
        "SELECT user_id::text, op, vault_id::text, note_id::text, point_id::text, stamp, " <>
          "terms, (SELECT array_agg(k::text) FROM unnest(keep) k) FROM keyword_feed ORDER BY xid, seq"
      )

    for [u, op, v, n, p, stamp, terms, keep] <- rows,
        do: %{
          user: u,
          op: op,
          vault: v,
          note: n,
          point: p,
          stamp: stamp,
          terms: terms,
          keep: keep
        }
  end

  defp deletion_rows do
    Repo.query!("SELECT user_id::text, op, vault_id::text, note_id::text FROM keyword_deletions").rows
  end

  defp chunk!(user, note, point_id, position) do
    Repo.query!(
      "INSERT INTO chunks (note_id, user_id, vault_id, position, char_start, char_end, qdrant_point_id) " <>
        "VALUES ($1, $2, $3, $4, 0, 1, $5)",
      Enum.map([note.id, user.id, note.vault_id], &Ecto.UUID.dump!/1) ++
        [position, Ecto.UUID.dump!(point_id)]
    )
  end

  describe "RLS" do
    test "CONTROL: engram_app with no tenant sees zero feed and deletion rows", %{a: a, va: va} do
      # Precondition: rows exist (written as the superuser), so zero below is
      # the policy filtering, not an empty table.
      :ok = Feed.delete_vault(to_string(a.id), to_string(va.id))
      assert length(feed_rows()) == 1 and length(deletion_rows()) == 1

      assert {:returned, [[0, 0]]} =
               as_prod_role(fn ->
                 Repo.query!(
                   "SELECT (SELECT count(*) FROM keyword_feed), (SELECT count(*) FROM keyword_deletions)"
                 ).rows
               end)
    end

    test "a delete runs under its own user's tenant as engram_app and writes both tables",
         %{a: a, va: va} do
      assert {:returned, {feed, log}} =
               as_prod_role(fn ->
                 :ok = Feed.delete_vault(to_string(a.id), to_string(va.id))

                 Repo.with_tenant!(to_string(a.id), fn ->
                   {Repo.query!("SELECT user_id::text, op, vault_id::text FROM keyword_feed").rows,
                    Repo.query!("SELECT user_id::text, op FROM keyword_deletions").rows}
                 end)
               end)

      assert feed == [[to_string(a.id), @ops.delete_vault, to_string(va.id)]]
      assert log == [[to_string(a.id), @ops.delete_vault]]
    end

    test "a row naming another user is refused under a tenant (WITH CHECK)", %{a: a, b: b} do
      assert {:raised, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               as_prod_role(fn ->
                 Repo.with_tenant!(to_string(a.id), fn ->
                   Repo.query!("INSERT INTO keyword_feed (user_id, op) VALUES ($1, 5)", [
                     Ecto.UUID.dump!(to_string(b.id))
                   ])
                 end)
               end)
    end

    test "the app role cannot move the trim horizon (seeded, maintenance only)" do
      assert [["0", 0]] = Repo.query!("SELECT xid::text, seq FROM keyword_feed_horizon").rows

      assert {:raised, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               as_prod_role(fn ->
                 Repo.query!("UPDATE keyword_feed_horizon SET seq = 99")
               end)

      assert {:raised, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               as_prod_role(fn -> Repo.query!("DELETE FROM keyword_feed_horizon") end)
    end
  end

  describe "note ops" do
    test "delete_note_except comes FIRST with the full keep set; upserts follow with one stamp",
         %{a: a, va: va} do
      note = insert(:note, user: a, vault: va)
      scope = %{user_id: to_string(a.id), vault_id: to_string(va.id), note_id: note.id}
      [p1, p2, p3] = for _ <- 1..3, do: Ecto.UUID.generate()

      :ok = Feed.note_pass(scope, {:given, [p1, p2, p3]}, [{p3, <<1::little-32, 2::little-32>>}])

      assert [except, upsert] = feed_rows()

      assert except.op == @ops.delete_note_except and
               Enum.sort(except.keep) == Enum.sort([p1, p2, p3])

      assert upsert.op == @ops.upsert and upsert.point == p3 and upsert.keep == nil
      assert upsert.stamp == except.stamp and except.stamp > 0
    end

    test "each later pass of a note takes a higher stamp", %{a: a, va: va} do
      note = insert(:note, user: a, vault: va)
      scope = %{user_id: to_string(a.id), vault_id: to_string(va.id), note_id: note.id}

      :ok = Feed.note_pass(scope, {:given, []}, [])
      :ok = KeywordStore.delete_note(a.id, va.id, note.id, [], :deleted)
      :ok = Feed.note_pass(scope, :current, [])

      stamps = Enum.map(feed_rows(), & &1.stamp)
      assert stamps == Enum.sort(stamps) and length(Enum.uniq(stamps)) == 3
    end

    # Review #1: resparse read its points, an index pass committed, then the
    # resparse wrote. Before the fix its keep set was the stale read and its
    # upsert brought back a point the index pass had dropped.
    test "a rewrite reads the keep set under the lock: an index pass in between is never undone",
         %{a: a, va: va} do
      note = insert(:note, user: a, vault: va)
      scope = %{user_id: to_string(a.id), vault_id: to_string(va.id), note_id: note.id}
      [old, kept, new] = for _ <- 1..3, do: Ecto.UUID.generate()
      chunk!(a, note, old, 0)
      chunk!(a, note, kept, 1)

      # The resparse matched {old, kept} and encoded both.
      stale_upserts = [
        {old, <<1::little-32, 1::little-32>>},
        {kept, <<2::little-32, 1::little-32>>}
      ]

      # An index pass commits meanwhile: `old` goes, `new` arrives.
      Repo.query!("DELETE FROM chunks WHERE qdrant_point_id = $1", [Ecto.UUID.dump!(old)])
      chunk!(a, note, new, 2)
      :ok = Tantivy.in_commit(scope, [kept, new], [{new, <<3::little-32, 1::little-32>>}])

      # Then the resparse writes.
      :ok = Feed.note_pass(scope, :current, stale_upserts)

      last = feed_rows() |> Enum.group_by(& &1.stamp) |> Enum.max_by(&elem(&1, 0)) |> elem(1)
      assert [%{op: 6, keep: keep} | upserts] = last
      assert Enum.sort(keep) == Enum.sort([kept, new]), "the index pass's point must stay kept"
      assert Enum.map(upserts, & &1.point) == [kept], "the dropped point must not come back"
    end

    test "a floor pass's post-commit cleanup and a rebuild purge write nothing (in_commit is authoritative)",
         %{a: a, va: va} do
      note = insert(:note, user: a, vault: va)
      :ok = KeywordStore.delete_note(a.id, va.id, note.id, [Ecto.UUID.generate()], :replaced)
      :ok = KeywordStore.delete_note(a.id, va.id, note.id, [], :rebuild)
      assert feed_rows() == [] and deletion_rows() == []
    end

    test "only a deleted note is logged (review #15)", %{a: a, va: va} do
      note = insert(:note, user: a, vault: va)
      :ok = KeywordStore.delete_note(a.id, va.id, note.id, [], :deleted)

      assert deletion_rows() == [[to_string(a.id), @ops.delete_note, to_string(va.id), note.id]]
      assert [%{op: 3}] = feed_rows()
    end

    test "bare point deletes carry the user; a tenant-less one writes nothing", %{a: a} do
      p = Ecto.UUID.generate()
      :ok = KeywordStore.delete_points(a.id, [p])
      :ok = KeywordStore.delete_points(nil, [p])
      assert [%{op: 2, point: ^p, user: u}] = feed_rows()
      assert u == to_string(a.id)
    end
  end

  describe "user and vault deletes (review #6, #7)" do
    test "the reversible soft deletes write no tombstone; the purges do", %{a: a, va: va} do
      :ok = KeywordStore.delete_user(a.id, :soft)
      :ok = KeywordStore.delete_vault(a.id, va.id, :soft)
      assert feed_rows() == [] and deletion_rows() == []

      :ok = KeywordStore.delete_vault(a.id, va.id, :purge)
      :ok = KeywordStore.delete_user(a.id, :purge)
      assert Enum.map(feed_rows(), & &1.op) == [@ops.delete_vault, @ops.delete_user]
    end

    test "a legacy user id spelling writes one tombstone under the canonical id", %{a: a} do
      id = to_string(a.id)
      undashed_upper = id |> String.replace("-", "") |> String.upcase()

      :ok = KeywordStore.delete_user(undashed_upper, :purge)
      :ok = KeywordStore.delete_user(id, :purge)
      :ok = KeywordStore.delete_user("not-a-uuid", :purge)

      assert [%{op: 5, user: ^id}] = feed_rows()
      assert [[^id, 5, nil, nil]] = deletion_rows()
    end
  end

  describe "modes (review #3)" do
    test "a feed key never shows its filter key in inspect output" do
      key = %FeedKey{filter_key: "very-secret-filter-key-bytes-0001", language: "en"}
      refute inspect(key) =~ "very-secret"
      assert inspect(key) =~ "en"
    end

    test "feed off: the default writes and reads the sparse store only", %{a: a, va: va} do
      ServiceConfig.put_override(:keyword_feed, false)
      note = insert(:note, user: a, vault: va)
      refute KeywordStore.feed?()
      assert KeywordStore.read() == :sparse
      assert FeedKey.new(<<0::256>>, "en") == nil

      :ok = KeywordStore.delete_user(a.id, :purge)
      :ok = KeywordStore.delete_note(a.id, va.id, note.id, [], :deleted)
      :ok = KeywordStore.in_commit(%{user_id: a.id, vault_id: va.id, note_id: note.id}, [], [])
      assert feed_rows() == []
    end

    test "dual-write: the sparse store still gets every write, and the feed too", %{a: a} do
      Engram.KeywordStoreRecorder.install()
      ServiceConfig.put_override(:keyword_feed, true)
      user_id = to_string(a.id)

      :ok = KeywordStore.delete_user(user_id, :purge)
      assert_received {:keyword_store, :delete_user, [^user_id, :purge]}
      assert [%{op: 5}] = feed_rows()
    end

    test "reads: tantivy needs the feed on, and rolling back to sparse is one key" do
      ServiceConfig.put_override(:keyword_feed, false)
      ServiceConfig.put_override(:keyword_read, :tantivy)
      assert KeywordStore.feed?(), "reading kwsearch keeps the feed written"
      ServiceConfig.put_override(:keyword_read, :sparse)
      assert KeywordStore.read() == :sparse
    end
  end

  describe "index pass" do
    setup do
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      test_pid = self()

      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

        if conn.method == "PUT" and String.ends_with?(conn.request_path, "/points"),
          do: send(test_pid, {:upsert, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      stub(Engram.MockEmbedder, :embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      :ok
    end

    test "feed off: the sparse store sees no plaintext and no filter key (review #12)",
         %{a: a, va: va} do
      ServiceConfig.put_override(:keyword_feed, false)
      Engram.KeywordStoreRecorder.install()

      {:ok, note} =
        Notes.upsert_note(a, va, %{"path" => "N.md", "content" => "# N\n\nbody", "mtime" => 1.0},
          actor: "api"
        )

      assert {:ok, _} = Indexing.index_note(note, va)
      assert_received {:keyword_store, :index, [scope, [_ | _] = entries]}
      assert Map.keys(scope) |> Enum.sort() == [:note_id, :user_id, :vault_id]
      refute Enum.any?(entries, &Map.has_key?(&1, :text))
      assert feed_rows() == []
    end

    test "dual-write: points keep their sparse vector; feed rows commit with the chunk rows",
         %{a: a, va: va} do
      {:ok, note} =
        Notes.upsert_note(
          a,
          va,
          %{
            "path" => "Iron.md",
            "content" => "# Iron\n\nFerritin levels are low.",
            "mtime" => 1.0
          },
          actor: "api"
        )

      assert {:ok, count} = Indexing.index_note(note, va)
      assert count > 0

      # The sparse store is still written: every upserted point has its keyword vector.
      assert_received {:upsert, %{"points" => [_ | _] = points}}
      assert Enum.all?(points, &Map.has_key?(&1["vector"], "keyword"))

      %{rows: chunk_points} =
        Repo.query!("SELECT qdrant_point_id::text FROM chunks WHERE note_id = $1", [
          Ecto.UUID.dump!(note.id)
        ])

      chunk_points = Enum.sort(List.flatten(chunk_points))
      rows = Enum.filter(feed_rows(), &(&1.note == note.id))
      upserts = Enum.filter(rows, &(&1.op == @ops.upsert))
      assert Enum.sort(Enum.map(upserts, & &1.point)) == chunk_points

      [stamp] = upserts |> Enum.map(& &1.stamp) |> Enum.uniq()
      assert [except | ^upserts] = Enum.filter(rows, &(&1.stamp == stamp))
      assert except.op == @ops.delete_note_except and Enum.sort(except.keep) == chunk_points
      assert Enum.all?(upserts, &(byte_size(&1.terms) > 0 and rem(byte_size(&1.terms), 8) == 0))

      # A rebuild purge wrote no deletion-log row (review #15).
      assert deletion_rows() == []
    end
  end
end
