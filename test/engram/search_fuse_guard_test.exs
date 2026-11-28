defmodule Engram.SearchFuseGuardTest do
  @moduledoc """
  Guard for `Qdrant.fuse/4`'s `:scope_first` (post-filtered searches only):
  an unfiltered search and an id-scoped search rank exactly as before it, the
  plain reciprocal rank fusion of their legs (`Fusion.rrf/2`, k = 2). The
  legs are built so that ordering in-scope first WOULD change the page (the
  test checks that first), so the in-folder-first logic firing on either
  path fails it.
  """
  use Engram.DataCase, async: false

  import Engram.Fixtures, only: [insert_chunk!: 4, insert_note!: 3]

  alias Engram.QdrantStub
  alias Engram.Search
  alias Engram.Search.Fusion
  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)

    QdrantStub.stub_healthy(bypass, "engram_notes",
      payload_schema: fn -> %{"n" => %{"data_type" => "uuid"}} end
    )

    QdrantStub.stub_retrieve(bypass)
    Mox.stub(Engram.MockEmbedder, :embed_texts, fn _, _ -> {:ok, [[0.1, 0.2, 0.3]]} end)
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    %{bypass: bypass, user: user, vault: insert(:vault, user: user)}
  end

  # The fusion before `:scope_first`, verbatim: map, rrf, take.
  defp pre_change(legs, limit) do
    legs
    |> Enum.map(fn leg -> Enum.map(leg, &%{id: &1.qdrant_id, score: &1.score}) end)
    |> Fusion.rrf(2)
    |> Enum.take(limit)
    |> Enum.map(& &1.id)
  end

  # What in-scope-first ordering would make of the same legs.
  defp scope_first(legs, inside, limit) do
    first = fn hits ->
      Enum.split_with(hits, &(&1.id in inside)) |> then(&(elem(&1, 0) ++ elem(&1, 1)))
    end

    legs
    |> Enum.map(fn leg -> leg |> Enum.map(&%{id: &1.qdrant_id, score: &1.score}) |> first.() end)
    |> Fusion.rrf(2)
    |> first.()
    |> Enum.take(limit)
    |> Enum.map(& &1.id)
  end

  test "fuse/4 without :scope_first is byte-identical to the pre-change fusion" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..50 do
      ids = for _ <- 1..30, do: Ecto.UUID.generate()

      leg = fn ->
        ids
        |> Enum.shuffle()
        |> Enum.take(20)
        |> Enum.map(&%{qdrant_id: &1, score: :rand.uniform()})
      end

      legs = [leg.(), leg.()]

      {:ok, fused} = Qdrant.fuse(nil, legs, 12, [])
      assert Enum.map(fused, & &1.qdrant_id) == pre_change(legs, 12)
    end
  end

  # Fixed point ids: the run never depends on a random UUID's order.
  @points %{
    "a" => "00000000-0000-4000-8000-00000000000a",
    "b" => "00000000-0000-4000-8000-00000000000b",
    "c" => "00000000-0000-4000-8000-00000000000c",
    "x" => "00000000-0000-4000-8000-0000000000ff"
  }

  # In-scope notes A, B, C under Health; X is another folder's point that an
  # id scope lets through (`is_empty(n)`) or an unfiltered search ranks.
  defp seed!(ctx) do
    for name <- ~w(a b c x) do
      folder = if name == "x", do: "Other", else: "Health"
      note = insert_note!(ctx.user, ctx.vault, %{path: "#{folder}/#{name}.md"})
      point = @points[name]
      insert_chunk!(ctx.user, note, point, text: "text #{name}")
      {name, %{point: point, path: "#{folder}/#{name}.md"}}
    end
    |> Map.new()
  end

  defp legs!(ctx, seeded) do
    p = &seeded[&1].point

    # No fused score ties under either ordering (so the id tie-break never
    # decides): plain fusion gives b, a, c in scope; in-scope first gives
    # b, c, a.
    dense =
      for {n, s} <- [{"a", 0.9}, {"b", 0.8}, {"x", 0.7}, {"c", 0.6}],
          do: %{qdrant_id: p.(n), score: s}

    keyword =
      for {n, s} <- [{"b", 9.0}, {"x", 8.0}, {"c", 7.0}], do: %{qdrant_id: p.(n), score: s}

    Bypass.stub(ctx.bypass, "POST", "/collections/engram_notes/points/query/batch", fn conn ->
      wire = &Enum.map(&1, fn h -> %{"id" => h.qdrant_id, "score" => h.score} end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(QdrantStub.batch(conn, %{"result" => wire.(dense)}, wire.(keyword)))
      )
    end)

    [dense, keyword]
  end

  defp paths(ctx, opts) do
    {:ok, hits} =
      Search.search(ctx.user, ctx.vault, "q", [mode: :hybrid, diversity: 0.0, limit: 10] ++ opts)

    Enum.map(hits, & &1.source_path)
  end

  for {label, opts} <- [{"unfiltered", []}, {"id-scoped (folder ids on n)", [folder: "Health"]}] do
    test "#{label} hybrid search ranks as the pre-change fusion", ctx do
      seeded = seed!(ctx)
      legs = legs!(ctx, seeded)
      by_point = Map.new(seeded, fn {_n, s} -> {s.point, s.path} end)
      inside = for n <- ~w(a b c), do: seeded[n].point

      expected = legs |> pre_change(20) |> Enum.map(&by_point[&1])
      assert Enum.reject(expected, &(&1 =~ "Other")) == ~w(Health/b.md Health/a.md Health/c.md)
      # The legs are a real test: in-scope-first ordering changes this page.
      refute legs
             |> scope_first(inside, 20)
             |> Enum.map(&by_point[&1])
             |> Enum.reject(&(&1 =~ "Other")) ==
               Enum.reject(expected, &(&1 =~ "Other"))

      expected =
        if unquote(opts) == [], do: expected, else: Enum.reject(expected, &(&1 =~ "Other"))

      assert paths(ctx, unquote(opts)) == expected
    end
  end
end
