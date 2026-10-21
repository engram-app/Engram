defmodule Engram.SearchFetchShapeTest do
  @moduledoc """
  Task 15.8: every search path asks Qdrant for an include list (never
  `with_payload: true`), and for dense vectors only when MMR runs, on the
  pool query itself. No path moves more bytes or makes more calls than
  before.

  The fake Qdrant answers exactly what each request asks for (a retrieve
  with no `with_payload` gets the whole payload, as Qdrant's default), so a
  path that stopped fetching a field it reads would rank or read
  differently. The golden ids were recorded on the code before this task.
  """
  use Engram.DataCase, async: false

  import Mox

  alias Engram.{Crypto, Notes, Search, ServiceConfig}
  alias Engram.Notes.{Chunk, ChunkPoint}

  setup :verify_on_exit!

  @dim 1024
  # 24 points, a full default pool (20) and then some. Point i belongs to
  # note div(i, 2). The dense leg ranks points in id order, the keyword leg
  # in this order.
  @n 24
  @keyword_order for i <- 0..(@n - 1), do: rem(i * 5 + 3, @n)
  # Directions for MMR: 0, 1 and 2 nearly the same, so diversity reorders.
  @directions [0, 0, 0, 1, 2, 1, 3, 2]

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)

    stub(Engram.MockEmbedder, :embed_texts, fn _texts, _opts ->
      {:ok, [List.duplicate(0.1, 3)]}
    end)

    {:ok, user} = insert(:user) |> Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)
    {:ok, dek} = Crypto.get_dek(user)

    notes =
      for n <- 0..(div(@n, 2) - 1) do
        {:ok, note} =
          Notes.upsert_note(
            user,
            vault,
            %{"path" => "N#{n}.md", "content" => "# N#{n}\n\nferritin", "mtime" => 1.0},
            actor: "api"
          )

        note
      end

    points =
      for i <- 0..(@n - 1) do
        id = point_id(i)
        note = Enum.at(notes, div(i, 2))
        # Even points have their text in Postgres; odd ones only in the
        # payload (rows written before the text columns).
        enc =
          if rem(i, 2) == 0,
            do: Crypto.encrypt_chunk_text(text(i), "H#{i}", dek, id),
            else: %{}

        {:ok, _} =
          Repo.with_tenant(user.id, fn ->
            %Chunk{}
            |> Chunk.changeset(%{
              note_id: note.id,
              user_id: user.id,
              vault_id: vault.id,
              position: rem(i, 2),
              char_start: 0,
              char_end: 1,
              qdrant_point_id: id
            })
            |> Repo.insert!()

            if enc != %{} do
              %ChunkPoint{point_id: id, note_id: note.id, user_id: user.id, position: rem(i, 2)}
              |> struct(enc)
              |> Repo.insert!()
            end
          end)

        {:ok, p} =
          Crypto.encrypt_qdrant_payload(
            %{text: text(i), title: "N#{div(i, 2)}", heading_path: "H#{i}"},
            user,
            "engram_notes",
            id
          )

        payload =
          p
          |> Map.take([:text, :text_nonce, :title, :title_nonce, :heading_path])
          |> Map.merge(%{heading_path_nonce: p.heading_path_nonce, aad_version: p.aad_version})
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
          |> Map.merge(%{"vault_id" => to_string(vault.id), "user_id" => to_string(user.id)})

        %{id: id, payload: payload, vector: vector(i)}
      end

    {:ok, corpus} = Agent.start_link(fn -> points end)
    fake_qdrant(bypass, corpus)
    %{user: user, vault: vault, corpus: corpus}
  end

  defp point_id(i), do: "00000000-0000-4000-8000-0000000000" <> pad(i)
  defp pad(i), do: i |> Integer.to_string() |> String.pad_leading(2, "0")

  # A realistic chunk: about 1.2 KB of text.
  defp text(i), do: "T#{i} ferritin " <> String.duplicate("iron stores lab value ", 55)

  # A unit vector near one of four directions, with float32-like noise in
  # every dimension so its JSON is the size Qdrant returns.
  defp vector(i) do
    dir = Enum.at(@directions, rem(i, 8))

    raw =
      for d <- 0..(@dim - 1) do
        base = if d == dir, do: 1.0, else: 0.0
        base + :math.sin(i * 7.0 + d) * 0.01
      end

    norm = :math.sqrt(Enum.reduce(raw, 0.0, &(&1 * &1 + &2)))
    Enum.map(raw, &Float.round(&1 / norm, 8))
  end

  # -- The fake Qdrant ---------------------------------------------------

  defp fake_qdrant(bypass, corpus) do
    pid = self()
    points = fn -> Agent.get(corpus, & &1) end

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {body, conn} = read(conn)
      reply(conn, pid, :query, body, %{"points" => answer(body, points.())})
    end)

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/query/batch", fn conn ->
      {body, conn} = read(conn)
      legs = Enum.map(body["searches"], &%{"points" => answer(&1, points.())})
      reply(conn, pid, :batch, body, legs)
    end)

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points", fn conn ->
      {body, conn} = read(conn)
      body = Map.put_new(body, "with_payload", true)
      found = for id <- body["ids"], p <- points.(), p.id == id, do: shape(p, body)
      reply(conn, pid, :retrieve, body, found)
    end)
  end

  defp read(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(raw), conn}
  end

  defp reply(conn, pid, kind, body, result) do
    json = Jason.encode!(%{"result" => result})
    no_vectors = Jason.encode!(%{"result" => strip_vectors(result)})

    send(
      pid,
      {:qdrant, kind, body,
       %{bytes: byte_size(json), vector_bytes: byte_size(json) - byte_size(no_vectors)}}
    )

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, json)
  end

  defp answer(body, points) do
    ranked =
      case body do
        %{"using" => "keyword"} ->
          Enum.map(@keyword_order, &Enum.at(points, &1))

        %{"query" => %{"recommend" => %{"positive" => pos}}} ->
          Enum.reject(points, &(&1.id in pos))

        _ ->
          points
      end

    ranked
    |> Enum.take(body["limit"])
    |> Enum.with_index()
    |> Enum.map(fn {p, rank} -> p |> shape(body) |> Map.put("score", 0.9 - rank * 0.05) end)
  end

  defp shape(p, body) do
    %{"id" => p.id}
    |> put_some("payload", payload(p.payload, body["with_payload"]))
    |> put_some(
      "vector",
      if(body["with_vector"] in [nil, false], do: nil, else: %{"dense" => p.vector})
    )
  end

  defp strip_vectors(%{"points" => points}), do: %{"points" => strip_vectors(points)}
  defp strip_vectors(list) when is_list(list), do: Enum.map(list, &strip_vectors/1)
  defp strip_vectors(%{"id" => _} = point), do: Map.delete(point, "vector")
  defp strip_vectors(other), do: other

  defp payload(_payload, keys) when keys in [nil, false], do: nil
  defp payload(payload, true), do: payload
  defp payload(payload, keys) when is_list(keys), do: Map.take(payload, keys)

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp requests do
    receive do
      {:qdrant, kind, body, bytes} -> [{kind, body, bytes} | requests()]
    after
      0 -> []
    end
  end

  # -- Searches ----------------------------------------------------------

  defp run(:vector, ctx, opts),
    do: Search.search(ctx.user, ctx.vault, "ferritin", [mode: :vector] ++ opts)

  defp run(:keyword, ctx, opts),
    do: Search.search(ctx.user, ctx.vault, "ferritin", [mode: :keyword] ++ opts)

  defp run(:hybrid, ctx, opts), do: Search.search(ctx.user, ctx.vault, "ferritin", opts)
  defp run(:similar, ctx, opts), do: Search.similar(ctx.user, ctx.vault, [point_id(0)], opts)

  defp ranked(:similar, {:ok, notes}), do: Enum.map(notes, & &1.source_path)
  defp ranked(_mode, {:ok, hits}), do: Enum.map(hits, &String.slice(&1.qdrant_id, -2, 2))

  # Every hit reads its own chunk's text, from Postgres or the payload.
  defp assert_texts({:ok, hits}) do
    for hit <- hits do
      assert String.starts_with?(hit.text, "T"), inspect(hit)
      [_, i] = Regex.run(~r/^T(\d+) /, hit.text)
      if hit[:qdrant_id], do: assert(hit.qdrant_id == point_id(String.to_integer(i)))
      assert hit.heading_path == "H#{i}", inspect(hit)
    end
  end

  @paths [
    {:vector, 0.3},
    {:vector, 0.0},
    {:keyword, 0.3},
    {:hybrid, 0.3},
    {:hybrid, 0.0},
    {:similar, 0.3}
  ]

  # Recorded on ed0564746 (before Task 15.8), the same for both
  # `:chunk_text_read` states.
  @golden %{
    {:vector, 0.3} => ["00", "03", "04", "06", "01"],
    {:vector, 0.0} => ["00", "01", "02", "03", "04"],
    {:keyword, 0.3} => ["03", "08", "23", "14", "13"],
    {:hybrid, 0.3} => ["03", "00", "04", "06", "08"],
    {:hybrid, 0.0} => ["03", "00", "01", "08", "02"],
    {:similar, 0.3} => ["N0.md", "N2.md", "N3.md", "N1.md", "N4.md"]
  }

  for read? <- [false, true] do
    test "ranked ids and texts are unchanged on every path (chunk_text_read #{read?})", ctx do
      ServiceConfig.put_override(:chunk_text_read, unquote(read?))

      actual =
        Map.new(@paths, fn {mode, d} = key ->
          result = run(mode, ctx, limit: 5, diversity: d)
          assert_texts(result)
          {key, ranked(mode, result)}
        end)

      assert actual == @golden
    end
  end

  # Response bytes and Qdrant calls per search on ed0564746, by
  # `:chunk_text_read`: {bytes, calls}.
  @before %{
    false => %{
      {:vector, 0.3} => {271_852, 1},
      {:vector, 0.0} => {9_925, 1},
      {:keyword, 0.3} => {271_876, 1},
      {:hybrid, 0.3} => {274_060, 2},
      {:hybrid, 0.0} => {10_474, 2},
      {:similar, 0.3} => {271_864, 1}
    },
    true => %{
      {:vector, 0.3} => {270_852, 1},
      {:vector, 0.0} => {9_675, 1},
      {:keyword, 0.3} => {270_876, 1},
      {:hybrid, 0.3} => {273_060, 2},
      {:hybrid, 0.0} => {10_224, 2},
      {:similar, 0.3} => {270_864, 1}
    }
  }

  # `MEASURE=1` prints the numbers (Task 15.8 PR body).
  for read? <- [false, true] do
    test "bytes and calls against before (chunk_text_read #{read?})", ctx do
      ServiceConfig.put_override(:chunk_text_read, unquote(read?))
      requests()

      for {mode, d} = key <- @paths do
        {:ok, _} = run(mode, ctx, limit: 5, diversity: d)
        reqs = requests()
        total = reqs |> Enum.map(&elem(&1, 2).bytes) |> Enum.sum()
        vectors = reqs |> Enum.map(&elem(&1, 2).vector_bytes) |> Enum.sum()
        {before, calls} = @before[unquote(read?)][key]

        if unquote(read?) do
          assert total <= before, "#{inspect(key)}: #{total} bytes, #{before} before"
          # A page holding rows without Postgres text adds ONE fallback
          # call; hybrid loses its fused retrieve when it has nothing to
          # fetch (no MMR).
          assert length(reqs) <= calls + 1, "#{inspect(key)}: #{length(reqs)} calls"
        else
          # Flag off is main, byte for byte and call for call.
          assert {total, length(reqs)} == {before, calls}, inspect(key)
        end

        if System.get_env("MEASURE"),
          do:
            IO.puts(
              "MEASURE read=#{unquote(read?)} #{inspect(key)} total=#{total} vectors=#{vectors} requests=#{length(reqs)}"
            )
      end
    end
  end

  # -- Request shapes ----------------------------------------------------

  defp requests_of(ctx, mode, opts) do
    requests()
    {:ok, result} = run(mode, ctx, opts)
    {result, Enum.map(requests(), fn {kind, body, _bytes} -> {kind, body} end)}
  end

  defp vector_request?({_kind, body}), do: body["with_vector"] not in [nil, false]

  @text_keys ~w(text text_nonce title title_nonce heading_path heading_path_nonce aad_version)

  for read? <- [false, true], {mode, d} <- @paths do
    test "#{mode} diversity #{d}, chunk_text_read #{read?}: include lists only", ctx do
      ServiceConfig.put_override(:chunk_text_read, unquote(read?))
      {_result, reqs} = requests_of(ctx, unquote(mode), limit: 5, diversity: unquote(d))

      for {_kind, body} <- reqs, b <- Map.get(body, "searches", [body]) do
        refute b["with_payload"] == true, "whole payload asked for: #{inspect(b)}"
      end

      # Vectors ride on the pool call (the ranked query, or hybrid's fused
      # retrieve), never on the hybrid legs.
      for {kind, body} = req <- reqs, vector_request?(req) do
        assert kind in [:query, :retrieve]
        assert body["with_vector"] == ["dense"]
      end

      for {:batch, body} <- reqs, leg <- body["searches"], do: refute(leg["with_vector"])
    end
  end

  test "chunk_text_read on: no text keys except a fallback for rows without text", ctx do
    ServiceConfig.put_override(:chunk_text_read, true)

    for {mode, d} <- @paths do
      {_result, reqs} = requests_of(ctx, mode, limit: 5, diversity: d)

      text_calls =
        Enum.count(reqs, fn {_k, b} ->
          Enum.any?(List.wrap(b["with_payload"]), &(&1 in @text_keys))
        end)

      assert text_calls == 1, "the fallback is one batched call per search"

      for {_kind, body} <- reqs, b <- Map.get(body, "searches", [body]) do
        keys = if is_list(b["with_payload"]), do: b["with_payload"], else: []

        if Enum.any?(keys, &(&1 in @text_keys)) do
          # Odd points are the rows written before the text columns.
          assert b["ids"] != nil and b["ids"] != []

          for id <- b["ids"] do
            assert rem(String.to_integer(String.slice(id, -2, 2)), 2) == 1,
                   "text fetched for a row that has it: #{id}"
          end
        else
          assert b["with_payload"] in [false, nil] or b["with_payload"] == []
        end
      end
    end
  end

  test "chunk_text_read off: result requests carry the text keys and vault_id", ctx do
    ServiceConfig.put_override(:chunk_text_read, false)
    {_result, reqs} = requests_of(ctx, :vector, limit: 5, diversity: 0.0)
    assert [{:query, body}] = reqs
    assert "vault_id" in body["with_payload"]
    assert Enum.all?(@text_keys, &(&1 in body["with_payload"]))
  end

  test "MMR: the vectors come with the pool, in the same call", ctx do
    for read? <- [false, true], {mode, d} <- @paths, d > 0 do
      ServiceConfig.put_override(:chunk_text_read, read?)
      {_result, reqs} = requests_of(ctx, mode, limit: 5, diversity: d)

      assert [{kind, body}] = Enum.filter(reqs, &vector_request?/1), inspect({mode, read?})

      # The pool: 20 (max(limit * 4, 20)).
      case kind do
        :query -> assert body["limit"] == 20
        :retrieve -> assert length(body["ids"]) == 20
      end
    end
  end

  test "no vectors when diversity is 0", ctx do
    for read? <- [false, true], {mode, d} <- @paths, d == 0.0 do
      ServiceConfig.put_override(:chunk_text_read, read?)
      {_result, reqs} = requests_of(ctx, mode, limit: 5, diversity: 0.0)
      refute Enum.any?(reqs, &vector_request?/1)
    end
  end
end
