defmodule Engram.SearchLargeFolderRecallTest do
  @moduledoc """
  Recall of the large-folder post-filter (`NoteFilter.post_filter_ids/0`):
  the same folder-scoped hybrid searches through the id path (the kill
  switch) and through the post-filter, top 10 compared.

  The vector store is a Bypass that scores exactly: every point, both legs,
  the `n` scope applied as Qdrant applies it. So the id path is the true
  filtered top k, and any difference is the post-filter's pool (oversample,
  widen) and fusion over the wider candidate set. Each test owns its points:
  no collection-wide statistic (keyword IDF,
  docs/context/search-baseline-drift-collection-idf.md) is shared.

  A 4,000-note vault (folders of 2,000, 1,000, 500 and 250, the rest at the
  root), so the post-filter pool is a small part of it as in prod. The
  threshold is 128 here, the shares are prod's: a folder of 1/4, one at the
  1/8 bound (the worst case that post-filters), and one of 1/16 over the
  threshold (a small share of a big vault), which must keep its ids.

  Measured (15 queries each): 1/4 folder 0.993 mean overlap (worst query
  0.9), 1/8 folder 0.987 (0.9), 1/16 folder 1.0 (id path). Without
  `Qdrant.fuse/4`'s `:scope_first` (fusing the tenant's ranks, not the
  scope's) the 1/4 folder measured 0.887 (0.7) and the 1/8 one 0.9 (0.8):
  this test fails without it.
  """
  use Engram.DataCase, async: false

  import Engram.Fixtures, only: [insert_chunk!: 4, insert_notes!: 3]

  alias Engram.QdrantStub
  alias Engram.Repo
  alias Engram.Search
  alias Engram.ServiceConfig
  alias Engram.Vector.FilterId

  @dims 16
  @k 10
  @queries 15
  @min_recall 0.95
  @threshold 128
  @total 4_000
  @folders [{"Half", 2_000}, {"Quarter", 1_000}, {"Edge", 500}, {"Small", 250}]
  @resolve [:engram, :search, :filter_resolve]

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)

    QdrantStub.stub_healthy(bypass, "engram_notes",
      payload_schema: fn -> %{"n" => %{"data_type" => "uuid"}} end
    )

    QdrantStub.stub_retrieve(bypass)

    Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts ->
      {:ok, Enum.map(texts, &query_vector/1)}
    end)

    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    insert(:user_limit_override, user: user, key: "ai_searches_per_day", value: %{"v" => -1})
    ref = :telemetry_test.attach_event_handlers(self(), [@resolve])
    on_exit(fn -> :telemetry.detach(ref) end)
    %{bypass: bypass, user: user, vault: vault, ref: ref}
  end

  # The neutral case: a note's relevance to a query is independent of its
  # folder. One test per folder (each seeds its own vault and points).
  for {folder, size, path} <- [
        {"Quarter", 1_000, :post_filter},
        {"Edge", 500, :post_filter},
        {"Small", 250, :ids}
      ] do
    @tag timeout: 300_000
    test "#{folder} (#{size} of #{@total}): top #{@k} keeps >= 95% of the id path's, via #{path}",
         ctx do
      points = seed!(ctx, unquote(folder))
      serve!(ctx.bypass, points)
      {recall, worst, path} = recall(ctx, unquote(folder))

      IO.puts(
        "recall #{unquote(folder)} #{unquote(size)}/#{@total} #{path}: mean #{recall} worst #{worst}"
      )

      assert path == unquote(path)
      assert recall >= @min_recall, "recall #{recall} < #{@min_recall}"
    end
  end

  # Mean and worst top-k overlap of the post-filter against the id path over
  # @queries queries, and the path the new search took.
  defp recall(ctx, folder) do
    overlaps =
      for i <- 1..@queries do
        query = "#{folder} q#{i}"
        ServiceConfig.put_override(:folder_post_filter_ids, 1_000_000)
        old = top(ctx, query, folder)
        assert_received {@resolve, _, _, %{path: :ids}}
        assert length(old) == @k

        ServiceConfig.put_override(:folder_post_filter_ids, @threshold)
        new = top(ctx, query, folder)
        assert_received {@resolve, _, _, %{path: path}}
        Process.put(:path, path)

        MapSet.size(MapSet.intersection(MapSet.new(old), MapSet.new(new))) / @k
      end

    {Float.round(Enum.sum(overlaps) / @queries, 3), Enum.min(overlaps), Process.get(:path)}
  end

  defp top(ctx, query, folder) do
    {:ok, hits} =
      Search.search(ctx.user, ctx.vault, query, folder: folder, limit: @k, mode: :hybrid)

    hits |> Enum.map(& &1.source_path) |> Enum.uniq()
  end

  # The vault: each folder's notes, the rest at the root, one point a note.
  # Only the searched folder's notes get chunk rows (the ones a hit reads):
  # every other point has none, so a post-filter drops it as it drops a note
  # outside the folder, and it still competes for the pool.
  defp seed!(ctx, searched) do
    in_folders = Enum.sum(for {_f, n} <- @folders, do: n)

    {:ok, _} =
      Engram.Folders.create_markers(ctx.user, ctx.vault, Enum.map(@folders, &elem(&1, 0)))

    folder_notes =
      for {folder, n} <- @folders do
        ids = insert_notes!(ctx.user, ctx.vault, for(i <- 1..n, do: note(folder, searched, i)))

        Repo.with_tenant!(ctx.user.id, fn ->
          [%{id: ref}] = Engram.Folders.Rows.subtree_refs(ctx.user, ctx.vault.id, [folder])

          Repo.update_all(from(n in Engram.Notes.Note, where: n.id in ^ids),
            set: [folder_ref_id: ref]
          )
        end)

        {folder, ids}
      end

    rest =
      insert_notes!(
        ctx.user,
        ctx.vault,
        for(i <- 1..(@total - in_folders), do: note(nil, searched, i))
      )

    :rand.seed(:exsss, {7, 11, 13})

    for {folder, ids} <- folder_notes ++ [{nil, rest}], id <- ids do
      point = Ecto.UUID.generate()

      if folder == searched,
        do: insert_chunk!(ctx.user, %{id: id, vault_id: ctx.vault.id}, point, text: "text")

      point(point, id)
    end
  end

  # The searched folder's notes are real (a hit decrypts them); every other
  # note only counts, so it is a factory row (placeholder ciphertext, no
  # encryption cost).
  defp note(folder, folder, i), do: %{path: "#{folder}/n#{i}.md", content: "n", title: "n#{i}"}
  defp note(_folder, _searched, _i), do: build(:note)

  defp point(id, note_id),
    do: %{id: id, n: FilterId.uuid(note_id), dense: unit(), keyword: unit()}

  defp unit do
    v = for _ <- 1..@dims, do: :rand.normal()
    norm = :math.sqrt(Enum.sum(Enum.map(v, &(&1 * &1))))
    Enum.map(v, &(&1 / norm))
  end

  # A query's embedding: a unit vector seeded by its text, so the same
  # query embeds the same on both paths.
  defp query_vector(text) do
    {v, _} =
      Enum.map_reduce(1..@dims, :rand.seed_s(:exsss, :erlang.phash2(text)), fn _, s ->
        :rand.normal_s(s)
      end)

    v
  end

  # Both legs of a hybrid batch, exact: the dense leg scores the query
  # vector against `dense`, the keyword leg against `keyword` (a second,
  # independent ranking), each over the points its filter keeps.
  defp serve!(bypass, points) do
    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/query/batch", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 64_000_000)
      %{"searches" => [dense, keyword]} = Jason.decode!(raw)
      q = dense["query"]

      body =
        QdrantStub.batch(
          conn,
          %{"result" => ranked(points, dense, q, :dense)},
          ranked(points, keyword, q, :keyword)
        )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)
  end

  defp ranked(points, leg, q, field) do
    keep? = scope(leg["filter"])

    points
    |> Enum.filter(&keep?.(&1.n))
    |> Enum.map(&%{"id" => &1.id, "score" => dot(q, Map.fetch!(&1, field))})
    |> Enum.sort_by(&{-&1["score"], &1["id"]})
    |> Enum.take(leg["limit"])
  end

  defp dot(a, b), do: a |> Enum.zip_with(b, &(&1 * &2)) |> Enum.sum()

  # The note scope on `n` (`Qdrant.note_scope/2`): a `should` of `match.any`
  # blocks (ids) or a `must_not` of them (the complement). The tenant
  # conditions hold for every point here.
  defp scope(%{"must" => must}) do
    Enum.reduce(must, fn _n -> true end, fn
      %{"should" => any}, acc -> n_in(any, acc, true)
      %{"must_not" => any}, acc -> n_in(any, acc, false)
      _tenant, acc -> acc
    end)
  end

  defp n_in(conditions, acc, member?) do
    case for(%{"key" => "n", "match" => %{"any" => ids}} <- conditions, id <- ids, do: id) do
      [] when member? ->
        acc

      ids ->
        set = MapSet.new(ids)
        fn n -> acc.(n) and MapSet.member?(set, n) == member? end
    end
  end
end
