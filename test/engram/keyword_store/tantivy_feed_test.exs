defmodule Engram.KeywordStore.TantivyFeedTest do
  @moduledoc """
  The Tantivy keyword store's write side: `keyword_feed` rows and the
  `keyword_deletions` log, under enforced RLS (run as `engram_app` through
  `Engram.RlsCase`, docs/context/rls-enforcement-testing-traps.md), and the
  index pass writing its feed rows in the chunk-row transaction.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase
  import Mox

  alias Engram.Indexing
  alias Engram.KeywordStore
  alias Engram.KeywordStore.Tantivy
  alias Engram.KeywordStore.Tantivy.Feed
  alias Engram.Notes
  alias Engram.ServiceConfig

  setup :verify_on_exit!

  setup do
    ServiceConfig.put_override(:keyword_store, Tantivy)
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
    %{rows: rows} =
      Repo.query!(
        "SELECT user_id::text, op, vault_id::text, note_id::text FROM keyword_deletions"
      )

    rows
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

    test "a delete for user A naming B's vault is a row scoped to A only (kwsearch matches A's docs)",
         %{a: a, vb: vb} do
      :ok = Feed.delete_vault(to_string(a.id), to_string(vb.id))
      assert [%{user: user}] = feed_rows()
      assert user == to_string(a.id)
    end
  end

  describe "note ops" do
    test "delete_note_except comes FIRST with the full keep set; upserts follow with one stamp",
         %{a: a, va: va} do
      note = insert(:note, user: a, vault: va)
      scope = %{user_id: to_string(a.id), vault_id: to_string(va.id), note_id: note.id}
      [p1, p2, p3] = for _ <- 1..3, do: Ecto.UUID.generate()

      :ok = Feed.note_pass(scope, [p1, p2, p3], [{p3, <<1::little-32, 2::little-32>>}])

      assert [except, upsert] = feed_rows()

      assert except.op == @ops.delete_note_except and
               Enum.sort(except.keep) == Enum.sort([p1, p2, p3])

      assert upsert.op == @ops.upsert and upsert.point == p3 and upsert.keep == nil
      assert upsert.stamp == except.stamp and except.stamp > 0
    end

    test "each later pass of a note takes a higher stamp", %{a: a, va: va} do
      note = insert(:note, user: a, vault: va)
      scope = %{user_id: to_string(a.id), vault_id: to_string(va.id), note_id: note.id}

      :ok = Feed.note_pass(scope, [], [])
      :ok = KeywordStore.delete_note(a.id, va.id, note.id, [])
      :ok = Feed.note_pass(scope, [], [])

      stamps = Enum.map(feed_rows(), & &1.stamp)
      assert stamps == Enum.sort(stamps) and length(Enum.uniq(stamps)) == 3
    end

    test "a whole-note delete is logged; a partial one (keep set) is not", %{a: a, va: va} do
      note = insert(:note, user: a, vault: va)
      :ok = KeywordStore.delete_note(a.id, va.id, note.id, [Ecto.UUID.generate()])
      assert deletion_rows() == []

      :ok = KeywordStore.delete_note(a.id, va.id, note.id, [])

      assert deletion_rows() == [
               [to_string(a.id), @ops.delete_note, to_string(va.id), note.id]
             ]
    end

    test "delete_user and bare point deletes carry the user", %{a: a} do
      p = Ecto.UUID.generate()
      :ok = KeywordStore.delete_points(a.id, [p])
      :ok = KeywordStore.delete_points(nil, [p])
      :ok = KeywordStore.delete_user(a.id)

      assert [%{op: 2, point: ^p, user: u1}, %{op: 5, user: u2}] = feed_rows()
      assert u1 == to_string(a.id) and u2 == to_string(a.id)
      assert [[_, 5, nil, nil]] = deletion_rows()
    end
  end

  describe "index pass" do
    setup do
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      stub(Engram.MockEmbedder, :embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      :ok
    end

    test "feed rows commit with the chunk rows: keep = every chunk point, terms per new chunk",
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

      %{rows: points} =
        Repo.query!("SELECT qdrant_point_id::text FROM chunks WHERE note_id = $1", [
          Ecto.UUID.dump!(note.id)
        ])

      points = Enum.sort(List.flatten(points))
      rows = Enum.filter(feed_rows(), &(&1.note == note.id))
      upserts = Enum.filter(rows, &(&1.op == @ops.upsert))
      assert Enum.sort(Enum.map(upserts, & &1.point)) == points

      # The pass's own except row (same stamp) comes right before its upserts.
      [stamp] = upserts |> Enum.map(& &1.stamp) |> Enum.uniq()
      assert [except | ^upserts] = Enum.filter(rows, &(&1.stamp == stamp))
      assert except.op == @ops.delete_note_except and Enum.sort(except.keep) == points
      assert Enum.all?(upserts, &(&1.op == @ops.upsert and byte_size(&1.terms) > 0))
      assert Enum.all?(upserts, &(rem(byte_size(&1.terms), 8) == 0))

      # An unchanged note's next pass upserts nothing new.
      assert {:ok, ^count} = Indexing.index_note(note, va)
      again = Enum.filter(feed_rows(), &(&1.note == note.id and &1.op == @ops.upsert))
      assert length(again) == length(upserts)
    end
  end
end
