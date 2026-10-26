defmodule Engram.SearchChunkTextSourceTest do
  @moduledoc """
  Task 11.3 + 15.7 step 2: search reads each
  hit's text, heading, vault and display fields from Postgres in ONE query
  keyed by the hit's point id, and the payload is only a fallback for rows
  written before the text columns. A hit with no chunk row (a stale point) is
  dropped, logged and counted, never a 500. The vault comes from the row, so
  Qdrant is no longer asked for `vault_id`.
  """
  use Engram.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Engram.{Crypto, Notes, Search, ServiceConfig}
  alias Engram.Notes.{Chunk, ChunkPoint}

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    stub(Engram.MockEmbedder, :embed_texts, fn _texts, _opts ->
      {:ok, [List.duplicate(0.1, 3)]}
    end)

    {:ok, user} = insert(:user) |> Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "Health/Iron.md", "content" => "# Iron\n\nFerritin.", "mtime" => 1.0},
        actor: "api"
      )

    {:ok, dek} = Crypto.get_dek(user)
    %{bypass: bypass, user: user, vault: vault, note: note, dek: dek}
  end

  defp insert_chunk!(ctx, point_id, pos, text \\ nil) do
    enc =
      if text,
        do: Crypto.encrypt_chunk_text(text, "Iron > Labs", ctx.dek, point_id),
        else: %{}

    {:ok, _} =
      Repo.with_tenant(ctx.user.id, fn ->
        %Chunk{}
        |> Chunk.changeset(%{
          note_id: ctx.note.id,
          user_id: ctx.user.id,
          vault_id: ctx.vault.id,
          position: pos,
          char_start: 0,
          char_end: 1,
          qdrant_point_id: point_id
        })
        |> Repo.insert!()

        # The point's `chunk_points` row holds the envelope; none = written
        # with the write flag off.
        if enc != %{}, do: insert_point!(ctx, point_id, pos, enc)
      end)
  end

  defp insert_point!(ctx, point_id, pos, fields) do
    %ChunkPoint{point_id: point_id, note_id: ctx.note.id, user_id: ctx.user.id, position: pos}
    |> struct(fields)
    |> Repo.insert!()
  end

  # A small note's row: a checksum, no envelope (Task 11.2 hybrid). Search
  # re-derives the chunk at `pos` from the note's current content.
  defp insert_sum_chunk!(ctx, point_id, pos, text) do
    {:ok, _} =
      Repo.with_tenant(ctx.user.id, fn ->
        %Chunk{}
        |> Chunk.changeset(%{
          note_id: ctx.note.id,
          user_id: ctx.user.id,
          vault_id: ctx.vault.id,
          position: pos,
          char_start: 0,
          char_end: byte_size(text),
          qdrant_point_id: point_id
        })
        |> Repo.insert!()

        ck = Crypto.dek_content_hash_key_from_bytes(ctx.dek)
        insert_point!(ctx, point_id, pos, slice_sum: Engram.Indexing.text_sum(ck, text))
      end)
  end

  # A v3/v4 point: encrypted payload text, AAD-bound.
  defp legacy_point(ctx, id, text, score) do
    {:ok, enc} =
      Crypto.encrypt_qdrant_payload(
        %{text: text, title: "Iron", heading_path: "Iron > Payload"},
        ctx.user,
        "engram_notes",
        id
      )

    %{
      "id" => id,
      "score" => score,
      "payload" =>
        enc
        |> Map.take([:text, :text_nonce, :title, :title_nonce, :heading_path])
        |> Map.merge(%{heading_path_nonce: enc.heading_path_nonce, aad_version: 2})
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put("vault_id", to_string(ctx.vault.id))
    }
  end

  # A v5 point: short keys only, no text and no `vault_id`.
  defp v5_point(ctx, id, score),
    do: %{"id" => id, "score" => score, "payload" => %{"u" => to_string(ctx.user.id)}}

  # Both the ranked query and a retrieve (Task 15.8: the payload fallback,
  # or hybrid's fused retrieve) answer only the payload keys they ask for.
  # `retrieved` defaults to `points`; a test passes fewer to delete a point
  # between the two calls.
  defp answer(ctx, points, retrieved \\ nil) do
    test_pid = self()
    retrieved = retrieved || points

    Bypass.expect(ctx.bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:query_body, body})
      shaped = Enum.map(points, &take_payload(&1, body["with_payload"]))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => %{"points" => shaped}}))
    end)

    Bypass.stub(ctx.bypass, "POST", "/collections/engram_notes/points", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      %{"ids" => ids, "with_payload" => keys} = body = Jason.decode!(raw)
      send(test_pid, {:retrieve_body, body})

      found =
        for id <- ids, p <- retrieved, p["id"] == id do
          p |> Map.delete("score") |> take_payload(keys)
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => found}))
    end)
  end

  defp take_payload(point, keys) when is_list(keys),
    do: Map.update(point, "payload", %{}, &Map.take(&1, keys))

  defp take_payload(point, _none), do: Map.delete(point, "payload")

  defp search(ctx), do: Search.search(ctx.user, ctx.vault, "ferritin", mode: :vector, limit: 5)

  defp with_event(event, fun) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "#{inspect(ref)}",
      event,
      fn _e, m, meta, _ -> send(test_pid, {ref, m, meta}) end,
      nil
    )

    try do
      result = fun.()
      events = collect(ref)
      {result, events}
    after
      :telemetry.detach("#{inspect(ref)}")
    end
  end

  defp collect(ref) do
    receive do
      {^ref, m, meta} -> [{m, meta} | collect(ref)]
    after
      0 -> []
    end
  end

  test "Postgres text wins over the payload text", ctx do
    id = Ecto.UUID.generate()
    insert_chunk!(ctx, id, 0, "Ferritin from postgres.")
    answer(ctx, [legacy_point(ctx, id, "Ferritin from the payload.", 0.9)])

    assert {:ok, [hit]} = search(ctx)
    assert hit.text == "Ferritin from postgres."
    assert hit.heading_path == "Iron > Labs"
    assert hit.source_path == "Health/Iron.md"
    assert hit.vault_id == to_string(ctx.vault.id)
  end

  test "a small note displays its chunk from the note content (no display_ct)", ctx do
    id = Ecto.UUID.generate()
    [chunk] = Engram.Parsers.Markdown.parse("# Iron\n\nFerritin.", "Health/Iron.md")
    insert_sum_chunk!(ctx, id, 0, chunk.text)
    answer(ctx, [v5_point(ctx, id, 0.9)])

    {result, events} = with_event([:engram, :search, :text_stale], fn -> search(ctx) end)

    assert {:ok, [hit]} = result
    assert hit.text == chunk.text
    assert hit.heading_path == chunk.heading_path
    assert events == []
  end

  test "a note edited since its index shows the current text and counts it", ctx do
    id = Ecto.UUID.generate()
    insert_sum_chunk!(ctx, id, 0, "# Iron\n\nFerritin.")

    {:ok, _} =
      Notes.upsert_note(
        ctx.user,
        ctx.vault,
        %{"path" => "Health/Iron.md", "content" => "# Iron\n\nFerritin is 90.", "mtime" => 2.0},
        actor: "api"
      )

    answer(ctx, [v5_point(ctx, id, 0.9)])

    {result, events} = with_event([:engram, :search, :text_stale], fn -> search(ctx) end)

    assert {:ok, [hit]} = result
    assert hit.text =~ "Ferritin is 90."
    assert [{%{count: 1}, _}] = events
  end

  test "small-note hits: one notes content query for every hit note", ctx do
    [chunk] = Engram.Parsers.Markdown.parse("# Iron\n\nFerritin.", "Health/Iron.md")
    ids = for _ <- 1..3, do: Ecto.UUID.generate()
    # Three points at position 0 of one note (only one row per position is
    # allowed, so the others use 1 and 2, gone from the content).
    for {id, pos} <- Enum.with_index(ids), do: insert_sum_chunk!(ctx, id, pos, chunk.text)
    answer(ctx, for({id, i} <- Enum.with_index(ids), do: v5_point(ctx, id, 1.0 - i / 10)))

    {result, events} = with_event([:engram, :repo, :query], fn -> search(ctx) end)

    assert {:ok, [_ | _]} = result
    assert Enum.count(events, fn {_m, meta} -> meta[:source] == "chunks" end) == 1
    assert Enum.count(events, fn {_m, meta} -> meta[:source] == "notes" end) <= 2
  end

  test "a row with no ciphertext falls back to the payload", ctx do
    id = Ecto.UUID.generate()
    insert_chunk!(ctx, id, 0)
    answer(ctx, [legacy_point(ctx, id, "Ferritin from the payload.", 0.9)])

    assert {:ok, [hit]} = search(ctx)
    assert hit.text == "Ferritin from the payload."
    assert hit.heading_path == "Iron > Payload"
  end

  test "a v5 point (no payload text, no vault_id) reads its text from Postgres", ctx do
    id = Ecto.UUID.generate()
    insert_chunk!(ctx, id, 0, "Ferritin v5.")
    answer(ctx, [v5_point(ctx, id, 0.9)])

    {result, events} =
      with_event([:engram, :search, :payload_shape_mismatch], fn -> search(ctx) end)

    assert {:ok, [hit]} = result
    assert hit.text == "Ferritin v5."
    assert hit.vault_id == to_string(ctx.vault.id)
    assert events == []
  end

  test "a row with no text anywhere keeps the hit with empty text and counts it", ctx do
    id = Ecto.UUID.generate()
    insert_chunk!(ctx, id, 0)
    answer(ctx, [v5_point(ctx, id, 0.9)])

    {result, events} = with_event([:engram, :search, :text_missing], fn -> search(ctx) end)

    assert {:ok, [hit]} = result
    assert hit.text == ""
    assert hit.source_path == "Health/Iron.md"
    assert [{%{count: 1}, _}] = events
  end

  test "a stale point (no chunk row) is dropped, logged and counted, not a 500", ctx do
    live = Ecto.UUID.generate()
    stale = Ecto.UUID.generate()
    insert_chunk!(ctx, live, 0, "Ferritin live.")
    answer(ctx, [v5_point(ctx, stale, 0.95), v5_point(ctx, live, 0.9)])

    # Every edit opens this window, so it is a counter and a debug line, not
    # a warning per search.
    {{result, events}, log} =
      with_log([level: :warning], fn ->
        with_event([:engram, :search, :hit_dropped], fn -> search(ctx) end)
      end)

    assert {:ok, [hit]} = result
    assert hit.text == "Ferritin live."
    assert [{%{count: 1}, %{reason: :no_chunk_row}}] = events
    refute log =~ "no chunk row"
  end

  test "only stale points: an empty page, not an error", ctx do
    answer(ctx, [v5_point(ctx, Ecto.UUID.generate(), 0.9)])

    assert {{:ok, []}, _log} = with_log(fn -> search(ctx) end)
  end

  test "a row whose text does not decrypt drops only that hit", ctx do
    good = Ecto.UUID.generate()
    bad = Ecto.UUID.generate()
    insert_chunk!(ctx, good, 0, "Ferritin good.")
    insert_chunk!(ctx, bad, 1, "Ferritin bad.")

    {:ok, _} =
      Repo.with_tenant(ctx.user.id, fn ->
        Repo.update_all(from(c in ChunkPoint, where: c.point_id == ^bad),
          set: [display_ct: <<12, :crypto.strong_rand_bytes(40)::binary>>]
        )
      end)

    answer(ctx, [v5_point(ctx, bad, 0.95), v5_point(ctx, good, 0.9)])

    {{result, events}, _log} =
      with_log(fn -> with_event([:engram, :search, :hit_dropped], fn -> search(ctx) end) end)

    assert {:ok, [%{text: "Ferritin good."}]} = result
    assert [{%{count: 1}, %{reason: :text_undecryptable}}] = events
  end

  test "a mixed page counts a payload-fallback hit that fails to decrypt", ctx do
    good = Ecto.UUID.generate()
    legacy = Ecto.UUID.generate()
    insert_chunk!(ctx, good, 0, "Ferritin good.")
    insert_chunk!(ctx, legacy, 1)

    garbled =
      update_in(legacy_point(ctx, legacy, "x", 0.95)["payload"]["text"], fn _ ->
        Base.encode64(:crypto.strong_rand_bytes(40))
      end)

    answer(ctx, [garbled, v5_point(ctx, good, 0.9)])

    {{result, events}, _log} =
      with_log(fn -> with_event([:engram, :search, :hit_dropped], fn -> search(ctx) end) end)

    assert {:ok, [%{text: "Ferritin good."}]} = result
    assert [{%{count: 1}, %{reason: :payload_undecryptable}}] = events
  end

  test "every candidate on the Postgres read path counts toward search hits", ctx do
    live = Ecto.UUID.generate()
    insert_chunk!(ctx, live, 0, "Ferritin live.")
    answer(ctx, [v5_point(ctx, Ecto.UUID.generate(), 0.95), v5_point(ctx, live, 0.9)])

    {{result, events}, _log} =
      with_log(fn -> with_event([:engram, :search, :hits], fn -> search(ctx) end) end)

    assert {:ok, [_]} = result
    assert [{%{count: 2}, _}] = events
  end

  defp corrupt_text!(ctx, point_id) do
    {:ok, _} =
      Repo.with_tenant(ctx.user.id, fn ->
        Repo.update_all(from(c in ChunkPoint, where: c.point_id == ^point_id),
          set: [display_ct: <<12, :crypto.strong_rand_bytes(40)::binary>>]
        )
      end)
  end

  test "every hit undecryptable fails the search, never an empty page", ctx do
    ids = for pos <- 0..1, do: Ecto.UUID.generate() |> tap(&insert_chunk!(ctx, &1, pos, "x"))
    Enum.each(ids, &corrupt_text!(ctx, &1))
    answer(ctx, for(id <- ids, do: v5_point(ctx, id, 0.9)))

    assert {{:error, :decrypt_failed}, _log} = with_log(fn -> search(ctx) end)
  end

  test "a DEK outage fails the search, never an empty page", ctx do
    id = Ecto.UUID.generate()
    insert_chunk!(ctx, id, 0, "Ferritin.")
    answer(ctx, [v5_point(ctx, id, 0.9)])
    keyless = %{ctx.user | encrypted_dek: nil}

    assert {{:error, :decrypt_failed}, _log} =
             with_log(fn ->
               Search.search(keyless, ctx.vault, "ferritin", mode: :vector, limit: 5)
             end)
  end

  # A second vault of the same user, with its own note.
  defp other_vault!(ctx) do
    vault = insert(:vault, user: ctx.user)

    {:ok, note} =
      Notes.upsert_note(
        ctx.user,
        vault,
        %{"path" => "Other/Zinc.md", "content" => "# Zinc\n\nZinc.", "mtime" => 1.0},
        actor: "api"
      )

    %{ctx | vault: vault, note: note}
  end

  defp cross_vault(ctx, opts \\ []),
    do:
      Search.search(
        ctx.user,
        nil,
        "ferritin",
        [mode: :vector, limit: 5, allow_cross_vault: true] ++ opts
      )

  test "cross-vault: each hit carries its own row's vault", ctx do
    other = other_vault!(ctx)
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    insert_chunk!(ctx, a, 0, "Ferritin here.")
    insert_chunk!(other, b, 0, "Zinc there.")
    answer(ctx, [v5_point(ctx, a, 0.9), v5_point(ctx, b, 0.8)])

    assert {:ok, hits} = cross_vault(ctx)

    assert Enum.sort(Enum.map(hits, &{&1.text, &1.vault_id})) ==
             Enum.sort([
               {"Ferritin here.", to_string(ctx.vault.id)},
               {"Zinc there.", to_string(other.vault.id)}
             ])
  end

  test "a soft-deleted vault's hit never shows, even with Postgres text", ctx do
    other = other_vault!(ctx)
    live = Ecto.UUID.generate()
    gone = Ecto.UUID.generate()
    insert_chunk!(ctx, live, 0, "Ferritin live.")
    insert_chunk!(other, gone, 0, "In a deleted vault.")

    {1, _} =
      Repo.update_all(
        from(v in Engram.Vaults.Vault, where: v.id == ^other.vault.id),
        [set: [deleted_at: DateTime.utc_now(:second)]],
        skip_tenant_check: true
      )

    answer(ctx, [v5_point(ctx, gone, 0.95), v5_point(ctx, live, 0.9)])

    {{result, events}, _log} =
      with_log(fn -> with_event([:engram, :search, :hit_dropped], fn -> cross_vault(ctx) end) end)

    assert {:ok, [%{text: "Ferritin live."}]} = result
    assert [{%{count: 1}, %{reason: :vault_inactive}}] = events
  end

  test "grouped: the note's best chunk shows its Postgres text", ctx do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    insert_chunk!(ctx, a, 0, "Best chunk.")
    insert_chunk!(ctx, b, 1, "Second chunk.")
    answer(ctx, [v5_point(ctx, a, 0.9), v5_point(ctx, b, 0.5)])

    assert {:ok, [note]} =
             Search.search(ctx.user, ctx.vault, "ferritin",
               mode: :vector,
               limit: 5,
               group_by_note: true
             )

    assert note.text == "Best chunk."
    assert note.source_path == "Health/Iron.md"
    assert note.match_count == 2
  end

  test "hybrid with MMR: Postgres text on every diversified hit", ctx do
    ids =
      for pos <- 0..2, do: Ecto.UUID.generate() |> tap(&insert_chunk!(ctx, &1, pos, "T#{pos}"))

    Engram.QdrantStub.stub_retrieve(ctx.bypass)

    points =
      for {id, i} <- Enum.with_index(ids) do
        ctx
        |> v5_point(id, 1.0 - i / 10)
        |> Map.put("vector", %{"dense" => [1.0 * i, 1.0, 0.5]})
      end

    Bypass.expect(ctx.bypass, "POST", "/collections/engram_notes/points/query/batch", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(Engram.QdrantStub.batch(conn, %{"result" => points}))
      )
    end)

    assert {:ok, hits} =
             Search.search(ctx.user, ctx.vault, "ferritin",
               mode: :hybrid,
               limit: 3,
               diversity: 0.5
             )

    assert Enum.sort(Enum.map(hits, & &1.text)) == ["T0", "T1", "T2"]
    # The only retrieve is hybrid's fused one, carrying the pool's vectors
    # for MMR and no payload (the text is in Postgres).
    assert %{"with_payload" => false, "with_vector" => ["dense"]} =
             Engram.QdrantStub.last_retrieve(ctx.bypass)
  end

  test "the reranker receives the Postgres text", ctx do
    prev = Application.get_env(:engram, :reranker)
    Application.put_env(:engram, :reranker, Engram.MockReranker)
    on_exit(fn -> Application.put_env(:engram, :reranker, prev || Engram.Rerankers.None) end)
    insert(:user_limit_override, user: ctx.user, key: "reranker_enabled", value: %{"v" => true})

    id = Ecto.UUID.generate()
    insert_chunk!(ctx, id, 0, "Ferritin from postgres.")
    answer(ctx, [legacy_point(ctx, id, "Ferritin from the payload.", 0.9)])
    test_pid = self()

    expect(Engram.MockReranker, :rerank, fn _query, candidates, _top_n ->
      send(test_pid, {:reranked, Enum.map(candidates, & &1.text)})
      {:ok, candidates}
    end)

    assert {:ok, [_]} = search(ctx)
    assert_received {:reranked, ["Ferritin from postgres."]}
  end

  test "one chunks query per search, whatever the hit count", ctx do
    ids = for _ <- 1..4, do: Ecto.UUID.generate()
    for {id, pos} <- Enum.with_index(ids), do: insert_chunk!(ctx, id, pos, "Ferritin #{pos}.")
    answer(ctx, for({id, i} <- Enum.with_index(ids), do: v5_point(ctx, id, 1.0 - i / 10)))

    {result, events} =
      with_event([:engram, :repo, :query], fn -> search(ctx) end)

    assert {:ok, hits} = result
    assert length(hits) == 4
    assert Enum.count(events, fn {_m, meta} -> meta[:source] == "chunks" end) == 1
  end

  test "the ranked query asks for no payload; a row with text needs no retrieve", ctx do
    id = Ecto.UUID.generate()
    insert_chunk!(ctx, id, 0, "Ferritin.")
    answer(ctx, [v5_point(ctx, id, 0.9)])

    {result, events} = with_event([:engram, :qdrant, :request, :stop], fn -> search(ctx) end)

    assert {:ok, [_]} = result
    assert_received {:query_body, %{"with_payload" => false}}
    refute_received {:retrieve_body, _}
    # Not even an empty (no-HTTP) retrieve shows on the Qdrant metrics.
    refute Enum.any?(events, fn {_m, meta} -> meta[:op] == :retrieve end)
  end

  test "a point deleted before the fallback retrieve: its hit is dropped and counted", ctx do
    live = Ecto.UUID.generate()
    gone = Ecto.UUID.generate()
    insert_chunk!(ctx, live, 0, "Ferritin live.")
    insert_chunk!(ctx, gone, 1)
    query_points = [legacy_point(ctx, gone, "Deleted.", 0.95), v5_point(ctx, live, 0.9)]
    answer(ctx, query_points, [v5_point(ctx, live, 0.9)])

    {{result, events}, _log} =
      with_log(fn -> with_event([:engram, :search, :hit_dropped], fn -> search(ctx) end) end)

    assert {:ok, [%{text: "Ferritin live."}]} = result
    assert [{%{count: 1}, %{reason: :point_gone}}] = events
  end

  test "a failed fallback retrieve fails the search, as a failed query does", ctx do
    id = Ecto.UUID.generate()
    insert_chunk!(ctx, id, 0)
    answer(ctx, [legacy_point(ctx, id, "Ferritin from the payload.", 0.9)])

    Bypass.stub(ctx.bypass, "POST", "/collections/engram_notes/points", fn conn ->
      Plug.Conn.send_resp(conn, 500, ~s({"status":{"error":"boom"}}))
    end)

    assert {{:error, _}, _log} = with_log(fn -> search(ctx) end)
  end

  test "a row without text: its point alone is retrieved, for the text keys only", ctx do
    with_text = Ecto.UUID.generate()
    without = Ecto.UUID.generate()
    insert_chunk!(ctx, with_text, 0, "Ferritin.")
    insert_chunk!(ctx, without, 1)

    answer(ctx, [
      v5_point(ctx, with_text, 0.9),
      legacy_point(ctx, without, "Ferritin from the payload.", 0.8)
    ])

    assert {:ok, [_, _]} = search(ctx)
    assert_received {:retrieve_body, %{"ids" => [^without], "with_payload" => keys}}
    assert keys == Engram.Vector.Qdrant.fallback_payload()
    refute "vault_id" in keys
    refute Engram.Vector.PayloadKeys.short(:vault_id) in keys
    assert "text_nonce" in keys
  end
end
