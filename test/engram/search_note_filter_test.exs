defmodule Engram.SearchNoteFilterTest do
  @moduledoc """
  The note-id reader (immutable chunk index, Engram#2263). Once the
  collection has its `n` index and the user's `n` backfill is done (checked
  automatically, no flag), a filtered search resolves its filters in
  Postgres (`:note_filter`, the resolver seam, stubbed here) and Qdrant gets
  the tenant plus note ids on `n`. Until both hold ("switch off" below), the
  resolver is never called and the request is today's.
  """
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Engram.FieldCatalogHelpers, only: [write_indexed!: 4]
  import Engram.Fixtures, only: [insert_chunk!: 4, insert_note!: 3]
  import Mox

  alias Engram.DataMigrations
  alias Engram.DataMigrations.NotePayloadStamps
  alias Engram.Indexing.PayloadV6
  alias Engram.Search
  alias Engram.ServiceConfig
  alias Engram.Vector.FilterId
  alias Engram.Vector.Qdrant

  setup :verify_on_exit!

  defmodule StubFilter do
    @moduledoc false
    # The resolver contract: `{:ok, {:ids, _} | {:exclude, _} | :too_wide}`,
    # and `within:` answers `{:ok, {:ids, subset}}`. Answers come from the
    # calling (test) process; every call is reported back to it.
    # Search hands over its whole opts; like the resolver, only filter keys count.
    @keys ~w(folder tags type fields created_after created_before updated_after updated_before)a
    def any?(opts), do: Enum.any?(opts, fn {k, v} -> k in @keys and v not in [nil, [], ""] end)

    # With `sample:`, `:too_wide` carries its `{matched, sampled}` sample:
    # `Process.get(:count)`, by default half matching (a 4x oversample). The
    # answer funs and the reported opts see the opts without `:sample`.
    def resolve(_user, vault, filter, opts) do
      {sample, opts} = Keyword.pop(opts, :sample)
      send(self(), {:resolve, vault, filter, opts})

      case Process.get(:resolve).(opts) do
        {:ok, :too_wide} when sample != nil -> {:ok, {:too_wide, Process.get(:count, {1, 2})}}
        out -> out
      end
    end
  end

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:note_filter, StubFilter)

    # Switch on by default: the collection holds the `n` index, and the `n`
    # backfill is done (its ledger). Both verdicts are cached per node.
    Engram.Cache.clear_local(:note_id_filter)
    on_exit(fn -> Engram.Cache.clear_local(:note_id_filter) end)
    {:ok, schema} = Agent.start_link(fn -> %{"n" => %{"data_type" => "uuid"}} end)

    Bypass.stub(bypass, "GET", "/collections/engram_notes", fn conn ->
      info = %{"status" => "green", "payload_schema" => Agent.get(schema, & &1)}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{result: info, status: "ok"}))
    end)

    DataMigrations.mark_done(NotePayloadStamps.name(), NotePayloadStamps.version())

    {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)
    %{bypass: bypass, user: user, vault: vault, schema: schema}
  end

  # Switch off: a release before the `n` payload version.
  defp switch_off, do: ServiceConfig.put_override(:payload_version, PayloadV6.baseline())

  defp answer(fun), do: Process.put(:resolve, fun)

  defp embed(times \\ 1),
    do: expect(Engram.MockEmbedder, :embed_texts, times, fn _, _ -> {:ok, [[0.1, 0.1, 0.1]]} end)

  # Captures each query body and answers `points`.
  defp expect_query(bypass, points) do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:query, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{result: %{points: points}}))
    end)
  end

  defp tenant_keys(must), do: must |> inspect() |> then(&{&1 =~ ~s("u"), &1 =~ ~s("v")})

  defp note_with_point(user, vault, path) do
    note = insert_note!(user, vault, %{path: path})
    point = Ecto.UUID.generate()
    insert_chunk!(user, note, point, text: "ferritin in #{path}")
    {note, point}
  end

  test "{:ids, ids}: the query sends n any, no folder condition",
       %{bypass: bypass, user: user, vault: vault} do
    [a, b] = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    answer(fn [] -> {:ok, {:ids, [a, b]}} end)
    embed()
    expect_query(bypass, [])

    assert {:ok, []} = Search.search(user, vault, "q", folder: "Health", mode: :vector)

    assert_received {:resolve, ^vault, filter_opts, []}
    assert filter_opts[:folder] == "Health"
    assert_received {:query, %{"filter" => filter}}
    assert tenant_keys(filter["must"]) == {true, true}

    assert [%{"should" => [%{"key" => "n", "match" => %{"any" => any}}]}] =
             Enum.filter(filter["must"], &match?(%{"should" => [%{"key" => "n"} | _]}, &1))

    assert any == Enum.map([a, b], &FilterId.uuid/1)
    refute inspect(filter) =~ "folder_hmac"
    refute inspect(filter) =~ ~s("f")
  end

  test "{:ids, []}: no note matches, so no embed and no Qdrant request",
       %{user: user, vault: vault} do
    answer(fn [] -> {:ok, {:ids, []}} end)
    assert {:ok, []} = Search.search(user, vault, "q", tags: ["none"], mode: :vector)
  end

  test "{:exclude, ids}: the ids go under must_not", %{bypass: bypass, user: user, vault: vault} do
    a = Ecto.UUID.generate()
    answer(fn [] -> {:ok, {:exclude, [a]}} end)
    embed()
    expect_query(bypass, [])

    assert {:ok, []} = Search.search(user, vault, "q", type: "note", mode: :vector)

    assert_received {:query, %{"filter" => filter}}
    assert filter["must_not"] == [%{"key" => "n", "match" => %{"any" => [FilterId.uuid(a)]}}]
  end

  test ":too_wide: u + v only at 4x the fetch, then the within: post-filter",
       %{bypass: bypass, user: user, vault: vault} do
    {keep, kept_point} = note_with_point(user, vault, "Health/keep.md")
    {drop, dropped_point} = note_with_point(user, vault, "Health/drop.md")

    answer(fn
      [] -> {:ok, :too_wide}
      [within: _] -> {:ok, {:ids, [keep.id]}}
    end)

    embed()

    expect_query(bypass, [
      %{"id" => dropped_point, "score" => 0.9},
      %{"id" => kept_point, "score" => 0.8}
    ])

    # diversity 0: the fetch is the page (5), so 4x is 20.
    assert {:ok, [hit]} =
             Search.search(user, vault, "q", folder: "Health", mode: :vector, diversity: 0.0)

    assert hit.source_path == "Health/keep.md"

    assert_received {:query, %{"filter" => filter, "limit" => limit}}
    assert limit == 5 * 4
    assert filter == Jason.decode!(Jason.encode!(Qdrant.build_tenant_filter(tenant(user, vault))))

    assert_received {:resolve, _, _, []}
    assert_received {:resolve, _, _, [within: within]}
    assert Enum.sort(within) == Enum.sort([keep.id, drop.id])
  end

  describe ":too_wide round cap (bounded per-search cost)" do
    setup %{bypass: bypass, user: user, vault: vault} do
      drop = insert_note!(user, vault, %{path: "Other/drop.md"})

      drop_points =
        for pos <- 0..15 do
          point = Ecto.UUID.generate()
          insert_chunk!(user, drop, point, text: "ferritin #{pos}", position: pos)
          %{"id" => point, "score" => 0.9 - pos / 100}
        end

      {keep, keep_point} = note_with_point(user, vault, "Health/keep.md")

      answer(fn
        [] -> {:ok, :too_wide}
        [within: ids] -> {:ok, {:ids, Enum.filter(ids, &(&1 == keep.id))}}
      end)

      test_pid = self()
      ref = make_ref()
      event = [:engram, :search, :post_filter]

      :telemetry.attach_many(
        {__MODULE__, ref},
        [event, [:engram, :search, :hits]],
        fn
          ^event, m, meta, _ -> send(test_pid, {:post_filter, m, meta})
          [:engram, :search, :hits], m, _, _ -> send(test_pid, {:hits, m.count})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      # Answers each query with its first `limit` points of `pool.(limit)`.
      respond = fn pool ->
        Bypass.expect(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"limit" => limit} = Jason.decode!(body)
          send(test_pid, {:limit, limit})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{result: %{points: Enum.take(pool.(limit), limit)}})
          )
        end)
      end

      keep_hit = %{"id" => keep_point, "score" => 0.1}
      %{drop_points: drop_points, keep_hit: keep_hit, respond: respond}
    end

    test "short at 4x widens ONCE to 16x and embeds once",
         %{user: user, vault: vault, drop_points: drops, keep_hit: keep_hit, respond: respond} do
      embed(1)
      # The 4x page is all non-matching; the 16x page reaches the match.
      respond.(fn _limit -> Enum.take(drops, 4) ++ [keep_hit] ++ Enum.drop(drops, 4) end)

      assert {:ok, [hit]} =
               Search.search(user, vault, "q",
                 folder: "H",
                 mode: :vector,
                 diversity: 0.0,
                 limit: 1
               )

      assert hit.source_path == "Health/keep.md"
      assert_received {:limit, 4}
      assert_received {:limit, 16}
      refute_received {:limit, _}
      assert_received {:post_filter, %{count: 1}, %{rounds: 2, short: false}}
      # Postgres loads (and decrypts) only the one survivor, once, over both
      # rounds: the hit counters see one read of one hit.
      assert_received {:hits, 1}
      refute_received {:hits, _}
    end

    test "still short at 16x: stops after two rounds and counts a short page",
         %{user: user, vault: vault, drop_points: drops, respond: respond} do
      embed(1)
      respond.(fn _limit -> drops end)

      assert {:ok, []} =
               Search.search(user, vault, "q",
                 folder: "H",
                 mode: :vector,
                 diversity: 0.0,
                 limit: 1
               )

      assert_received {:limit, 4}
      assert_received {:limit, 16}
      refute_received {:limit, _}
      assert_received {:post_filter, %{count: 1}, %{rounds: 2, short: true}}
    end

    test "a page under the Qdrant limit is the whole tenant: no widen",
         %{user: user, vault: vault, drop_points: drops, respond: respond} do
      embed(1)
      respond.(fn _limit -> Enum.take(drops, 3) end)

      assert {:ok, []} =
               Search.search(user, vault, "q",
                 folder: "H",
                 mode: :vector,
                 diversity: 0.0,
                 limit: 1
               )

      assert_received {:limit, 4}
      refute_received {:limit, _}
      assert_received {:post_filter, %{count: 1}, %{rounds: 1, short: false}}
    end
  end

  # The first round is sized by the matching fraction: 20% of the vault
  # matches, so a 5-hit page fetches 2 / 0.2 = 10x (50 points) and finds
  # all 5 in one round, where a fixed 4x (20 points) came back short.
  test ":too_wide sizes the oversample by the matching fraction: full top-k in one round",
       %{bypass: bypass, user: user, vault: vault} do
    drop = insert_note!(user, vault, %{path: "Other/drop.md"})
    keeps = for i <- 1..5, do: note_with_point(user, vault, "Health/keep#{i}.md")
    keep_ids = Enum.map(keeps, fn {note, _} -> note.id end)

    # Every 5th point matches: 4 drops, then a keep.
    pool =
      for {{_note, keep_point}, i} <- Enum.with_index(keeps), reduce: [] do
        acc ->
          drops =
            for d <- 0..3 do
              point = Ecto.UUID.generate()
              insert_chunk!(user, drop, point, text: "ferritin", position: i * 4 + d)
              point
            end

          acc ++ drops ++ [keep_point]
      end

    points =
      pool
      |> Enum.with_index()
      |> Enum.map(fn {id, i} -> %{"id" => id, "score" => 1 - i / 100} end)

    test_pid = self()

    Bypass.expect(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"limit" => limit} = Jason.decode!(body)
      send(test_pid, {:limit, limit})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{result: %{points: Enum.take(points, limit)}}))
    end)

    Process.put(:count, {2_000, 10_000})

    answer(fn
      [] -> {:ok, :too_wide}
      [within: ids] -> {:ok, {:ids, Enum.filter(ids, &(&1 in keep_ids))}}
    end)

    embed()

    assert {:ok, hits} =
             Search.search(user, vault, "q", folder: "Health", mode: :vector, diversity: 0.0)

    assert hits |> Enum.map(& &1.source_path) |> Enum.sort() ==
             Enum.map(1..5, &"Health/keep#{&1}.md")

    assert_received {:limit, 50}
    refute_received {:limit, _}
  end

  test ":too_wide oversample: a tiny or zero fraction is 16x, never more",
       %{bypass: bypass, user: user, vault: vault} do
    for count <- [{1, 2_048}, {0, 2_048}] do
      Process.put(:count, count)

      answer(fn
        [] -> {:ok, :too_wide}
        [within: _] -> {:ok, {:ids, []}}
      end)

      embed()
      expect_query(bypass, [])

      assert {:ok, []} =
               Search.search(user, vault, "q", folder: "Health", mode: :vector, diversity: 0.0)

      assert_received {:query, %{"limit" => 80}}
      refute_received {:query, _}
    end
  end

  test ":too_wide counts a point with no chunk row as a dropped hit, once",
       %{bypass: bypass, user: user, vault: vault} do
    {keep, point} = note_with_point(user, vault, "Health/keep.md")
    test_pid = self()
    ref = make_ref()
    event = [:engram, :search, :hit_dropped]

    :telemetry.attach(
      {__MODULE__, ref},
      event,
      fn ^event, m, meta, _ -> send(test_pid, {:dropped, m.count, meta.reason}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    answer(fn
      [] -> {:ok, :too_wide}
      [within: _] -> {:ok, {:ids, [keep.id]}}
    end)

    embed()
    # A short page (2 < 20): no widen, so one round.
    expect_query(bypass, [
      %{"id" => Ecto.UUID.generate(), "score" => 0.9},
      %{"id" => point, "score" => 0.8}
    ])

    assert {:ok, [_hit]} =
             Search.search(user, vault, "q", folder: "Health", mode: :vector, diversity: 0.0)

    assert_received {:dropped, 1, :no_chunk_row}
    refute_received {:dropped, _, _}
  end

  test ":too_wide counts a rowless point once when the search widens to a second round",
       %{bypass: bypass, user: user, vault: vault} do
    {keep, keep_point} = note_with_point(user, vault, "Health/keep.md")
    drop = insert_note!(user, vault, %{path: "Other/drop.md"})

    drops =
      for pos <- 0..13 do
        point = Ecto.UUID.generate()
        insert_chunk!(user, drop, point, text: "ferritin #{pos}", position: pos)
        point
      end

    rowless = Ecto.UUID.generate()
    pool = Enum.with_index([rowless | drops] ++ [keep_point])
    points = Enum.map(pool, fn {id, i} -> %{"id" => id, "score" => 1 - i / 100} end)
    test_pid = self()
    ref = make_ref()
    event = [:engram, :search, :hit_dropped]

    :telemetry.attach(
      {__MODULE__, ref},
      event,
      fn ^event, m, meta, _ -> send(test_pid, {:dropped, m.count, meta.reason}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    # Round 1 (4 points) holds the rowless point and no match; round 2 (16)
    # holds it again and the match.
    Bypass.expect(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"limit" => limit} = Jason.decode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{result: %{points: Enum.take(points, limit)}}))
    end)

    answer(fn
      [] -> {:ok, :too_wide}
      [within: ids] -> {:ok, {:ids, Enum.filter(ids, &(&1 == keep.id))}}
    end)

    embed()

    assert {:ok, [hit]} =
             Search.search(user, vault, "q", folder: "H", mode: :vector, diversity: 0.0, limit: 1)

    assert hit.source_path == "Health/keep.md"
    assert_received {:dropped, 1, :no_chunk_row}
    refute_received {:dropped, _, _}
  end

  test ":too_wide with nothing kept by within: is an empty page",
       %{bypass: bypass, user: user, vault: vault} do
    {_note, point} = note_with_point(user, vault, "Health/a.md")

    answer(fn
      [] -> {:ok, :too_wide}
      [within: _] -> {:ok, {:ids, []}}
    end)

    embed()
    expect_query(bypass, [%{"id" => point, "score" => 0.9}])

    assert {:ok, []} = Search.search(user, vault, "q", folder: "Health", mode: :vector)
  end

  test "a resolver error is the search's error", %{user: user, vault: vault} do
    answer(fn [] -> {:error, {:unknown_field, "x"}} end)
    assert {:error, {:unknown_field, "x"}} = Search.search(user, vault, "q", folder: "H")
  end

  test "no filter: the resolver is not called", %{bypass: bypass, user: user, vault: vault} do
    answer(fn _ -> flunk("resolver called for an unfiltered search") end)
    embed()
    expect_query(bypass, [])

    assert {:ok, []} = Search.search(user, vault, "q", mode: :vector)
    assert_received {:query, %{"filter" => filter}}
    refute inspect(filter) =~ ~s("n")
  end

  # Switch off, every filter at once: the search opts, and the opts main's
  # builders take for them (the payload conditions of today's path). Any
  # resolver call fails the test.
  defp switch_off_filters(user) do
    switch_off()
    answer(fn _ -> flunk("resolver called with the switch off") end)
    embed()

    {:ok, dek} = Engram.Crypto.get_dek(user)
    {:ok, fk} = Engram.Crypto.dek_filter_key(user)
    names = %{FilterId.key_hmac(fk, "Phase") => "Phase"}
    {_ids, 0} = Engram.Notes.FrontmatterKeys.resolve(user.id, dek, names)
    fields = [%{"key" => "phase", "op" => "eq", "value" => "Draft"}]
    {:ok, attr_filters} = Engram.Search.FieldFilters.to_conditions(user.id, fk, fields)

    dates = [
      created_after: ~U[2026-01-01 00:00:00Z],
      created_before: ~U[2026-02-01 00:00:00Z],
      updated_after: ~U[2026-03-01 00:00:00Z],
      updated_before: ~U[2026-04-01 00:00:00Z]
    ]

    hmac = &Base.encode64(Engram.Crypto.hmac_field(fk, &1))
    unix = &DateTime.to_unix(dates[&1])

    payload = [
      folder_hmac: hmac.("Health"),
      tags_hmac: Enum.map(["a", "b"], hmac),
      type_hmac: hmac.("playbook"),
      fm_timestamp_gte: unix.(:updated_after),
      fm_timestamp_lte: unix.(:updated_before),
      fm_created_gte: unix.(:created_after),
      fm_created_lte: unix.(:created_before),
      attr_filters: attr_filters
    ]

    {[folder: "Health", tags: ["a", "b"], type: "Playbook", fields: fields] ++ dates, payload}
  end

  # The one vector query body of a switch-off search.
  defp vector_body(bypass, user, vault, opts) do
    expect_query(bypass, [])
    assert {:ok, []} = Search.search(user, vault, "q", opts)
    assert_received {:query, body}
    refute_received {:query, _}
    refute inspect(body) =~ ~s("n")
    body
  end

  defp vector_today(user, body, scope, payload) do
    today =
      Qdrant.search_body(
        body["query"],
        scope ++
          [limit: 5] ++
          payload ++
          [
            with_vector: false,
            full_precision: Engram.Search.SearchProfile.resolve(user).full_precision,
            tenant_idf: false
          ]
      )

    Jason.decode!(Jason.encode!(today))
  end

  test "switch off, vector: the body is today's",
       %{bypass: bypass, user: user, vault: vault} do
    {opts, payload} = switch_off_filters(user)
    body = vector_body(bypass, user, vault, opts ++ [mode: :vector, diversity: 0.0])
    assert body == vector_today(user, body, tenant(user, vault), payload)
  end

  test "switch off, cross-vault vault_ids: the body is today's",
       %{bypass: bypass, user: user, vault: vault} do
    other = insert(:vault, user: user)
    {opts, payload} = switch_off_filters(user)

    body =
      vector_body(
        bypass,
        user,
        nil,
        opts ++ [mode: :vector, diversity: 0.0, vault_ids: [vault.id, other.id]]
      )

    scope = [user_id: to_string(user.id), vault_id: [to_string(vault.id), to_string(other.id)]]
    assert body == vector_today(user, body, scope, payload)
  end

  # Every filter at once, hybrid: the whole request body is what main's
  # builder makes from today's opts (the query vectors are the only inputs
  # taken from the request itself).
  test "switch off: the resolver is never called and the body is today's",
       %{bypass: bypass, user: user, vault: vault} do
    {opts, payload} = switch_off_filters(user)
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:batch, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": [{"points": []}, {"points": []}]}))
    end)

    assert {:ok, []} = Search.search(user, vault, "q", opts ++ [mode: :hybrid, diversity: 0.0])
    assert_received {:batch, %{"searches" => [dense, sparse]} = body}

    today =
      Qdrant.hybrid_search_body(
        dense["query"],
        %{indices: sparse["query"]["indices"], values: sparse["query"]["values"]},
        tenant(user, vault) ++
          [limit: 5] ++
          payload ++
          [
            with_vector: false,
            full_precision: Engram.Search.SearchProfile.resolve(user).full_precision,
            tenant_idf: Search.tenant_idf?(user)
          ]
      )

    assert body == Jason.decode!(Jason.encode!(today))
    refute inspect(body) =~ ~s("n")
  end

  # `folder` with a query: switch off (today), the one folder only, an exact
  # `folder_hmac` match; switch on, the real resolver's folder and subtree.
  # A blank-query listing (`NoteFilter.page/4`) is the subtree either way.
  describe "folder semantics with a query" do
    setup %{user: user, vault: vault} do
      top = write_indexed!(user, vault, "Health/a.md", "body\n")
      sub = write_indexed!(user, vault, "Health/Sub/b.md", "body\n")
      _beside = write_indexed!(user, vault, "Other/c.md", "body\n")
      look_alike = write_indexed!(user, vault, "Healthy/d.md", "body\n")
      %{top: top, sub: sub, look_alike: look_alike}
    end

    test "switch off: only the folder itself, an exact folder_hmac match",
         %{bypass: bypass, user: user, vault: vault} do
      switch_off()
      answer(fn _ -> flunk("resolver called with the switch off") end)
      embed()
      expect_query(bypass, [])

      assert {:ok, []} = Search.search(user, vault, "q", folder: "Health", mode: :vector)
      assert_received {:query, %{"filter" => filter}}

      {:ok, fk} = Engram.Crypto.dek_filter_key(user)
      exact = Base.encode64(Engram.Crypto.hmac_field(fk, "Health"))
      today = Qdrant.build_tenant_filter(tenant(user, vault) ++ [folder_hmac: exact])
      assert filter == Jason.decode!(Jason.encode!(today))
      refute inspect(filter) =~ ~s("n")
    end

    test "switch on: the folder and its whole subtree, via the real resolver",
         %{bypass: bypass, user: user, vault: vault, top: top, sub: sub, look_alike: look_alike} do
      ServiceConfig.put_override(:note_filter, Engram.Search.NoteFilter)
      embed()
      expect_query(bypass, [])

      assert {:ok, []} = Search.search(user, vault, "q", folder: "Health", mode: :vector)
      assert_received {:query, %{"filter" => filter}}

      assert [%{"should" => [%{"key" => "n", "match" => %{"any" => any}}]}] =
               Enum.filter(filter["must"], &match?(%{"should" => [%{"key" => "n"} | _]}, &1))

      assert Enum.sort(any) == Enum.sort(Enum.map([top.id, sub.id], &FilterId.uuid/1))
      refute FilterId.uuid(look_alike.id) in any
      assert tenant_keys(filter["must"]) == {true, true}
      refute inspect(filter) =~ "folder_hmac"
      refute inspect(filter) =~ ~s("f")
    end
  end

  # The switch is automatic (R2): both halves must hold, per user.
  describe "the switch turns on by itself" do
    test "no n index on the collection: today's filters",
         %{bypass: bypass, user: user, vault: vault, schema: schema} do
      Agent.update(schema, &Map.delete(&1, "n"))
      answer(fn _ -> flunk("resolver called without the n index") end)
      embed()
      expect_query(bypass, [])

      assert {:ok, []} = Search.search(user, vault, "q", folder: "Health", mode: :vector)
      assert_received {:query, %{"filter" => filter}}
      refute inspect(filter) =~ ~s("n")
    end

    test "a user with a note behind the n version: today's filters, until it is stamped",
         %{bypass: bypass, user: user, vault: vault} do
      DataMigrations.reopen(NotePayloadStamps.name(), NotePayloadStamps.version())
      {note, _point} = note_with_point(user, vault, "Health/a.md")
      answer(fn _ -> flunk("resolver called before the user's backfill") end)
      embed()
      expect_query(bypass, [])

      assert {:ok, []} = Search.search(user, vault, "q", folder: "Health", mode: :vector)
      assert_received {:query, %{"filter" => filter}}
      refute inspect(filter) =~ ~s("n")

      # Stamped, the user's backfill chain finished (its marker), and the
      # cached verdict expired.
      {1, _} =
        Repo.update_all(
          from(s in Engram.Notes.NoteIndexState, where: s.note_id == ^note.id),
          [set: [payload_version: PayloadV6.version()]],
          skip_tenant_check: true
        )

      # The marker's one Qdrant check: no point of the user lacks `n`.
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/count", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":{"count":0},"status":"ok"}))
      end)

      :ok = Engram.Workers.ReconcileNotePayloads.mark_backfilled(user.id)

      Engram.Cache.clear_local(:note_id_filter)
      answer(fn [] -> {:ok, {:ids, [note.id]}} end)
      embed()

      assert {:ok, []} = Search.search(user, vault, "q", folder: "Health", mode: :vector)
      assert_received {:resolve, _, _, []}
    end

    test "an unfiltered search checks nothing", %{bypass: bypass, user: user, vault: vault} do
      Bypass.stub(bypass, "GET", "/collections/engram_notes", fn _ -> flunk("checked") end)
      embed()
      expect_query(bypass, [])

      assert {:ok, []} = Search.search(user, vault, "q", mode: :vector)
    end
  end

  test "cross-vault: the resolver gets every vault the search covers",
       %{bypass: bypass, user: user, vault: vault} do
    other = insert(:vault, user: user)
    answer(fn [] -> {:ok, {:ids, [Ecto.UUID.generate()]}} end)
    embed()
    expect_query(bypass, [])

    assert {:ok, []} =
             Search.search(user, nil, "q",
               folder: "Health",
               mode: :vector,
               vault_ids: [vault.id, other.id]
             )

    assert_received {:resolve, vaults, _, []}
    assert Enum.sort(Enum.map(vaults, & &1.id)) == Enum.sort([vault.id, other.id])
  end

  defp tenant(user, vault), do: [user_id: to_string(user.id), vault_id: to_string(vault.id)]
end
