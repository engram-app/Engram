defmodule Engram.Crypto.UserDekRotationIndexKeysTest do
  @moduledoc """
  Every key the index matches on derives from the DEK: the Qdrant filter
  HMACs (`Crypto.dek_filter_key/1`) and the chunk-reuse fingerprints
  (`Crypto.dek_content_hash_key/1`). A rotation that rewraps only the point
  text leaves type/tag/folder/path filters matching nothing, and makes the
  next index of every note re-embed every chunk. The keyword (sparse)
  vectors are keyed on the filter key too.

  Nothing touches Qdrant between the note rewrap and the flip: a failure
  there strands the notes under a DEK that was never saved. Points are
  healed after the flip (`ReconcileNotePayloads`, `RefreshKeywordVectors`).

  Qdrant is a small in-memory fake behind Bypass: it keeps each point's
  payload and applies `set_payload`, so a search's filter can be evaluated
  against what a point actually holds.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Engram.Crypto
  alias Engram.Crypto.UserDekRotation
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.Chunk
  alias Engram.Search
  alias Engram.Workers.{ReconcileNotePayloads, RefreshKeywordVectors}

  setup :verify_on_exit!

  @content """
  ---
  type: Playbook
  tags: [ops, oncall]
  ---
  # Pager Runbook

  Intro paragraph about the pager.

  ## Escalation

  Page the secondary after fifteen minutes.

  ## Handoff

  Write the handoff note before signing off.
  """

  setup do
    {:ok, store} =
      Agent.start_link(fn ->
        %{points: %{}, vectors: %{}, queries: [], upserts: 0, fail: false}
      end)

    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Bypass.stub(bypass, :any, :any, &fake_qdrant(&1, store))

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
    vault = Engram.Fixtures.insert_vault!(user, "KeysVault")

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Ops/Pager.md", "content" => @content},
        actor: "api"
      )

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      send(self(), {:embedded, texts})
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    assert {:ok, chunks} = Indexing.index_note(fresh(note, user), vault)
    assert chunks > 2, "the fixture must produce several chunks"
    assert drain_embedded() != [], "the first index embeds"

    # What EmbedNote stamps once the note is indexed.
    {1, _} =
      Repo.update_all(
        from(n in Notes.Note,
          where: n.id == ^note.id,
          update: [
            set: [
              embed_hash: n.content_hash,
              dense_indexed_hash: n.content_hash,
              chunker_version: ^Engram.Parsers.Markdown.chunker_version(),
              keyword_version: ^Engram.KeywordIndex.version()
            ]
          ]
        ),
        [],
        skip_tenant_check: true
      )

    %{user: user, vault: vault, note: note, store: store}
  end

  test "a type/tag/folder search finds the note once the post-flip heal ran", ctx do
    assert :ok = UserDekRotation.rotate_user(ctx.user.id)
    user = reload_user(ctx.user)

    assert_enqueued(worker: ReconcileNotePayloads, args: %{"user_id" => ctx.user.id})
    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

    for {opts, key} <- [
          {[type: "Playbook"], "type_hmac"},
          {[tags: ["ops"]], "tags_hmac"},
          {[folder: "Ops"], "folder_hmac"}
        ] do
      assert {:ok, _} = Search.search(user, ctx.vault, "pager", [mode: :vector] ++ opts)
      filter = last_query(ctx.store)["filter"]["must"]
      assert Enum.any?(filter, &(&1["key"] == key)), "the search must filter on #{key}"

      ids = point_ids(ctx.note)
      matched = for id <- ids, matches?(point(ctx.store, id), filter), do: id

      assert Enum.sort(matched) == Enum.sort(ids),
             "#{key}: a #{inspect(opts)} search must still find every chunk of the note"
    end
  end

  # The outage outlasts the post-flip retries, so the point text stays under
  # the DEK the flip retired. The notes are queued for a rebuild as OUR
  # maintenance (version-stale, fingerprints cleared): a Free user at the
  # cap still gets dense vectors back, and their meter does not move.
  test "a Qdrant outage during the rotation neither fails it nor strands the notes", ctx do
    prev = Application.get_env(:engram, :limits_enforced)
    Application.put_env(:engram, :limits_enforced, true)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :limits_enforced),
        else: Application.put_env(:engram, :limits_enforced, prev)
    end)

    Engram.UsageMeters.add_embed_tokens(ctx.user.id, 20_000_000)
    used = Engram.UsageMeters.lifetime_embed_tokens(ctx.user.id)
    Agent.update(ctx.store, &%{&1 | fail: true})

    assert :ok = UserDekRotation.rotate_user(ctx.user.id)

    user = reload_user(ctx.user)
    assert user.dek_rotation_locked_at == nil
    assert fresh(ctx.note, user).content =~ "Page the secondary"
    assert_enqueued(worker: ReconcileNotePayloads, args: %{"user_id" => ctx.user.id})

    raw = Repo.one!(from(n in Notes.Note, where: n.id == ^ctx.note.id), skip_tenant_check: true)
    assert raw.chunker_version == nil, "version-stale, so EmbedNote rebuilds it as maintenance"
    assert raw.embed_hash == raw.content_hash, "never the metered content path"

    assert Repo.all(from(c in Chunk, where: c.note_id == ^ctx.note.id, select: c.context_hmac),
             skip_tenant_check: true
           )
           |> Enum.all?(&is_nil/1),
           "no chunk may reuse a point whose text is under the retired DEK"

    # Enqueued now, not left for the 04:00 reconcile hour.
    assert_enqueued(worker: Engram.Workers.EmbedNote, args: %{note_id: ctx.note.id})

    Agent.update(ctx.store, &%{&1 | fail: false})

    assert :ok =
             perform_job(Engram.Workers.EmbedNote, %{
               "note_id" => ctx.note.id,
               "user_id" => ctx.user.id
             })

    assert drain_embedded() != [], "the dense vectors are rebuilt, cap or not"
    assert Engram.UsageMeters.lifetime_embed_tokens(ctx.user.id) == used

    {:ok, dek} = Crypto.get_dek(user)

    for id <- point_ids(ctx.note) do
      p = point(ctx.store, id)
      aad = Crypto.aad_for_qdrant(Engram.Vector.Qdrant.collection_name(), id, :text)

      assert {:ok, _} =
               Engram.Crypto.Envelope.decrypt(
                 Base.decode64!(p["text"]),
                 Base.decode64!(p["text_nonce"]),
                 dek,
                 aad
               ),
             "every point of the rebuilt note must decrypt under the new DEK"
    end
  end

  test "keyword search hits the note again once its sparse vectors are refreshed", ctx do
    assert :ok = UserDekRotation.rotate_user(ctx.user.id)
    user = reload_user(ctx.user)

    raw = Repo.one!(from(n in Notes.Note, where: n.id == ^ctx.note.id), skip_tenant_check: true)
    assert raw.keyword_version == nil, "the keyword sweep must pick the note up"

    # Control: until the refresh, the points still answer only the old key.
    refute keyword_hit?(ctx, user), "the fixture must start from old-key sparse vectors"

    assert :ok =
             perform_job(RefreshKeywordVectors, %{
               "note_id" => ctx.note.id,
               "user_id" => ctx.user.id
             })

    assert drain_embedded() == [], "a resparse never calls the embedder"

    assert keyword_hit?(ctx, user),
           "a keyword query under the new key must share a dimension with the note's points"
  end

  defp keyword_hit?(ctx, user) do
    assert {:ok, _} = Search.search(user, ctx.vault, "escalation secondary", mode: :keyword)
    query = last_query(ctx.store)["query"]["indices"]

    Enum.any?(point_ids(ctx.note), fn id ->
      indices = get_in(Agent.get(ctx.store, & &1.vectors), [id, "keyword", "indices"]) || []
      Enum.any?(query, &(&1 in indices))
    end)
  end

  test "re-indexing the unchanged note after the rotation embeds nothing", ctx do
    assert :ok = UserDekRotation.rotate_user(ctx.user.id)
    user = reload_user(ctx.user)
    before = point_ids(ctx.note)

    assert {:ok, _} = Indexing.index_note(fresh(ctx.note, user), ctx.vault)

    assert drain_embedded() == [], "a rotation must cost nothing in Voyage"
    assert Enum.sort(point_ids(ctx.note)) == Enum.sort(before), "every point is reused"
  end

  # The plugin sends the server's content_hash back as base_hash: moving it
  # under every synced client would turn their next push into a 409.
  test "the rotation leaves content_hash and embed_hash alone", ctx do
    before =
      Repo.one!(from(n in Notes.Note, where: n.id == ^ctx.note.id), skip_tenant_check: true)

    assert :ok = UserDekRotation.rotate_user(ctx.user.id)

    raw = Repo.one!(from(n in Notes.Note, where: n.id == ^ctx.note.id), skip_tenant_check: true)
    assert raw.content_hash == before.content_hash
    assert raw.embed_hash == before.embed_hash
  end

  # ---------------------------------------------------------------------------

  defp reload_user(user), do: Repo.reload!(user, skip_tenant_check: true)

  defp fresh(note, user) do
    {:ok, note} =
      note
      |> Repo.reload!(skip_tenant_check: true)
      |> Crypto.maybe_decrypt_note_fields(reload_user(user))

    note
  end

  defp drain_embedded do
    receive do
      {:embedded, texts} -> texts ++ drain_embedded()
    after
      0 -> []
    end
  end

  defp point_ids(note) do
    Repo.all(from(c in Chunk, where: c.note_id == ^note.id, select: c.qdrant_point_id),
      skip_tenant_check: true
    )
  end

  defp point(store, id), do: Agent.get(store, &Map.fetch!(&1.points, id))

  defp last_query(store) do
    [body | _] = Agent.get(store, & &1.queries)
    body
  end

  # Only the key/match conditions: the ones a filter HMAC answers.
  defp matches?(payload, conditions) do
    Enum.all?(conditions, fn
      %{"key" => key, "match" => %{"value" => v}} ->
        v in List.wrap(payload[key])

      %{"key" => key, "match" => %{"any" => vs}} ->
        Enum.any?(vs, &(&1 in List.wrap(payload[key])))

      _other ->
        true
    end)
  end

  defp fake_qdrant(conn, store) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
    body = if body == "", do: %{}, else: Jason.decode!(body)

    if Agent.get(store, & &1.fail) and String.contains?(conn.request_path, "/points"),
      do: Plug.Conn.send_resp(conn, 500, ~s({"status": {"error": "down"}})),
      else: fake_reply(conn, store, body)
  end

  defp fake_reply(conn, store, body) do
    result =
      case {conn.method, conn.request_path} do
        {"PUT", "/collections/engram_notes/points"} ->
          Agent.update(store, fn s ->
            points = Map.new(body["points"], &{&1["id"], &1["payload"]})
            vectors = Map.new(body["points"], &{&1["id"], &1["vector"]})

            %{
              s
              | points: Map.merge(s.points, points),
                vectors: Map.merge(s.vectors, vectors),
                upserts: s.upserts + 1
            }
          end)

          %{"status" => "completed"}

        {"PUT", "/collections/engram_notes/points/vectors"} ->
          Agent.update(store, fn s ->
            vectors =
              Enum.reduce(body["points"], s.vectors, fn p, acc ->
                Map.update(acc, p["id"], p["vector"], &Map.merge(&1, p["vector"]))
              end)

            %{s | vectors: vectors}
          end)

          %{"status" => "completed"}

        {"POST", "/collections/engram_notes/points/payload"} ->
          ids = for %{"has_id" => ids} <- body["filter"]["should"], id <- ids, do: id

          Agent.update(store, fn s ->
            points =
              Enum.reduce(ids, s.points, fn id, acc ->
                Map.update(acc, id, body["payload"], &Map.merge(&1, body["payload"]))
              end)

            %{s | points: points}
          end)

          %{"status" => "completed"}

        # The rotation's own text sweep scrolls by user_id and gets nothing
        # (no text to rewrap here); the heal scrolls by id.
        {"POST", "/collections/engram_notes/points/scroll"} ->
          ids =
            for %{"has_id" => ids} <- get_in(body, ["filter", "must"]) || [], id <- ids, do: id

          points = Agent.get(store, & &1.points)

          %{
            "points" =>
              for(
                id <- ids,
                Map.has_key?(points, id),
                do: %{
                  "id" => id,
                  "payload" => Map.take(points[id], List.wrap(body["with_payload"]))
                }
              ),
            "next_page_offset" => nil
          }

        {"POST", "/collections/engram_notes/points/query"} ->
          Agent.update(store, &%{&1 | queries: [body | &1.queries]})
          %{"points" => []}

        _other ->
          true
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => result, "status" => "ok"}))
  end
end
