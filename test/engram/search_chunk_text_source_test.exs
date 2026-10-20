defmodule Engram.SearchChunkTextSourceTest do
  @moduledoc """
  Task 11.3 + 15.7 step 2: with `:chunk_text_read` on, search reads each
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
  alias Engram.Notes.Chunk

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:chunk_text_read, true)

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
        |> Ecto.Changeset.change(enc)
        |> Repo.insert!()
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

  defp answer(ctx, points) do
    test_pid = self()

    Bypass.expect(ctx.bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:query_body, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => %{"points" => points}}))
    end)
  end

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

    {{result, events}, log} =
      with_log(fn ->
        with_event([:engram, :search, :hit_dropped], fn -> search(ctx) end)
      end)

    assert {:ok, [hit]} = result
    assert hit.text == "Ferritin live."
    assert [{%{count: 1}, %{reason: :no_chunk_row}}] = events
    assert log =~ "no chunk row"
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
        Repo.update_all(from(c in Chunk, where: c.qdrant_point_id == ^bad),
          set: [text_ciphertext: :crypto.strong_rand_bytes(40)]
        )
      end)

    answer(ctx, [v5_point(ctx, bad, 0.95), v5_point(ctx, good, 0.9)])

    {{result, events}, _log} =
      with_log(fn -> with_event([:engram, :search, :hit_dropped], fn -> search(ctx) end) end)

    assert {:ok, [%{text: "Ferritin good."}]} = result
    assert [{%{count: 1}, %{reason: :text_decrypt_failed}}] = events
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

  test "Qdrant is asked for named payload keys, without vault_id", ctx do
    id = Ecto.UUID.generate()
    insert_chunk!(ctx, id, 0, "Ferritin.")
    answer(ctx, [v5_point(ctx, id, 0.9)])

    assert {:ok, [_]} = search(ctx)
    assert_received {:query_body, %{"with_payload" => keys}}
    assert is_list(keys)
    refute "vault_id" in keys
    refute Engram.Vector.PayloadKeys.short(:vault_id) in keys
    assert "text_nonce" in keys
  end

  test "flag off: vault_id is still read from the payload", ctx do
    ServiceConfig.put_override(:chunk_text_read, false)
    id = Ecto.UUID.generate()
    insert_chunk!(ctx, id, 0, "Ferritin from postgres.")
    answer(ctx, [legacy_point(ctx, id, "Ferritin from the payload.", 0.9)])

    assert {:ok, [hit]} = search(ctx)
    assert hit.text == "Ferritin from the payload."
    assert_received {:query_body, %{"with_payload" => keys}}
    assert "vault_id" in keys
  end
end
