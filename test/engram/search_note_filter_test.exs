defmodule Engram.SearchNoteFilterTest do
  @moduledoc """
  The note-id reader (immutable chunk index R1, Engram#2263). With
  `Qdrant.note_id_filter?/0` on, a filtered search resolves its filters in
  Postgres (`:note_filter`, the resolver seam, stubbed here) and Qdrant gets
  the tenant plus note ids on `n`. Off (the default until R2 backfills `n`),
  the resolver is never called and the request is today's.
  """
  use Engram.DataCase, async: false

  import Engram.Fixtures, only: [insert_chunk!: 4, insert_note!: 3]
  import Mox

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
    def any?(filter), do: Enum.any?(filter, fn {_k, v} -> v not in [nil, [], ""] end)

    def resolve(_user, vault, filter, opts) do
      send(self(), {:resolve, vault, filter, opts})
      Process.get(:resolve).(opts)
    end
  end

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:note_filter, StubFilter)
    ServiceConfig.put_override(:note_id_filter, true)

    {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)
    %{bypass: bypass, user: user, vault: vault}
  end

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

    assert_received {:resolve, ^vault, %{folder: "Health"}, []}
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

      :telemetry.attach(
        {__MODULE__, ref},
        event,
        fn ^event, m, meta, _ ->
          send(test_pid, {:post_filter, m, meta})
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

  test "switch off: the resolver is never called and the body is today's",
       %{bypass: bypass, user: user, vault: vault} do
    ServiceConfig.put_override(:note_id_filter, false)
    answer(fn _ -> flunk("resolver called with the switch off") end)
    embed()
    expect_query(bypass, [])

    assert {:ok, []} = Search.search(user, vault, "q", folder: "Health", mode: :vector)
    assert_received {:query, %{"filter" => filter}}

    {:ok, fk} = Engram.Crypto.dek_filter_key(user)
    folder_hmac = Base.encode64(Engram.Crypto.hmac_field(fk, "Health"))
    today = Qdrant.build_tenant_filter([folder_hmac: folder_hmac] ++ tenant(user, vault))

    assert filter == Jason.decode!(Jason.encode!(today))
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
