defmodule Engram.IndexingV5RebuildTest do
  @moduledoc """
  Chunker v5 Task 16.3: the v5 rebuild of one note. Every point is written
  fresh (UUIDv5 id, text-free payload), its dense vector copied from the old
  point, mean-pooled from a capped group's members' old points, or embedded
  as a last resort; new points are written before the old ones go.

  Qdrant is an in-memory store behind Bypass, so "the old points are still
  searchable" is a read of what Qdrant would hold.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.IndexBudgetHelpers
  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Indexing.PointId
  alias Engram.Notes.{Chunk, ChunkPoint, Note, NoteAttr}
  alias Engram.ServiceConfig
  alias Engram.UsageMeters
  alias Engram.Workers.EmbedNote
  alias Engram.Workers.EmbedNote.CrashGuard
  alias Engram.Workers.RebuildStaleNote

  setup :verify_on_exit!

  @pad String.duplicate("lorem ipsum dolor ", 30)

  defp sections(n) do
    "---\nauthor: Ann\nmood: calm\n---\n# Big\n\n" <>
      Enum.map_join(1..n, "\n\n", fn i -> "## S#{i}\n\nsection#{i} body text here. #{@pad}" end)
  end

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    {:ok, store} = Agent.start_link(fn -> %{points: %{}, refuse: false, log: []} end)

    Bypass.stub(bypass, :any, :any, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 100_000_000)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)
      {status, resp} = handle(store, conn.method, conn.request_path, body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(resp))
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user, is_default: true)
    stub_embedder()
    %{user: user, vault: vault, store: store}
  end

  defp handle(store, method, path, body) do
    Agent.get_and_update(store, fn s ->
      s = %{s | log: [{method, path} | s.log]}

      cond do
        method == "PUT" and String.ends_with?(path, "/points") and s.refuse ->
          {{507, %{"status" => %{"error" => "Disk usage is at 99% of total"}}}, s}

        method == "PUT" and String.ends_with?(path, "/points") ->
          points =
            Enum.into(body["points"], s.points, fn p ->
              {p["id"], %{dense: p["vector"]["dense"], payload: p["payload"]}}
            end)

          {{200, %{"result" => %{"status" => "completed"}}}, %{s | points: points}}

        method == "POST" and String.ends_with?(path, "/points/delete") ->
          points =
            case body do
              %{"points" => ids} ->
                Map.drop(s.points, ids)

              %{"filter" => filter} ->
                keep = for %{"has_id" => ids} <- filter["must_not"] || [], id <- ids, do: id
                Map.take(s.points, keep)
            end

          {{200, %{"result" => %{"status" => "completed"}}}, %{s | points: points}}

        method == "POST" and String.ends_with?(path, "/points") ->
          result =
            for id <- body["ids"],
                %{dense: d} when d != nil <- [s.points[id]],
                do: %{"id" => id, "vector" => %{"dense" => d}}

          {{200, %{"result" => result}}, s}

        true ->
          {{200, %{"result" => true}}, s}
      end
    end)
  end

  defp points(store), do: Agent.get(store, & &1.points)
  defp refuse(store, on?), do: Agent.update(store, &%{&1 | refuse: on?})
  defp clear_log(store), do: Agent.update(store, &%{&1 | log: []})
  defp deletes(store), do: for({"POST", p} <- Agent.get(store, & &1.log), p =~ "/delete", do: p)

  defp drop_dense(store),
    do:
      Agent.update(store, fn s ->
        %{s | points: Map.new(s.points, fn {id, p} -> {id, %{p | dense: nil}} end)}
      end)

  # A distinct vector per text, so a copied vector is told from a fresh one.
  defp stub_embedder do
    parent = self()

    embed = fn texts ->
      send(parent, {:embedded, texts})
      {:ok, Enum.map(texts, &vector/1)}
    end

    stub(Engram.MockEmbedder, :embed_texts, embed)
    stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts -> embed.(texts) end)
  end

  defp vector(text) do
    h = :erlang.phash2(text, 1000) + 1
    [h / 1000, 0.5, 1 - h / 1000]
  end

  defp embedded(acc \\ []) do
    receive do
      {:embedded, texts} -> embedded(acc ++ texts)
    after
      0 -> acc
    end
  end

  defp insert_note(user, vault, content) do
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "Big.md", content: content})
    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)
    note
  end

  defp tenant(user, fun) do
    {:ok, result} = Repo.with_tenant(user.id, fun)
    result
  end

  defp rows(note),
    do:
      tenant(%{id: note.user_id}, fn ->
        Repo.all(from(c in Chunk, where: c.note_id == ^note.id, order_by: c.position))
      end)

  defp reload(note),
    do: tenant(%{id: note.user_id}, fn -> Repo.get!(Note, note.id) end)

  defp dense_by_position(note, store) do
    pts = points(store)
    Map.new(rows(note), &{&1.position, pts[&1.qdrant_point_id].dense})
  end

  defp rebuild(note, vault, user),
    do: Indexing.index_note_with_usage(note, vault, user, rebuild: true)

  # A first index the pre-v5 way: random ids, one point a chunk.
  defp indexed(ctx, n \\ 3) do
    note = insert_note(ctx.user, ctx.vault, sections(n))
    assert {:ok, _, _, true} = Indexing.index_note_with_usage(note, ctx.vault, ctx.user)
    _ = embedded()
    clear_log(ctx.store)
    note
  end

  test "an unchanged note copies every vector: 0 tokens, fresh v5 points, old ids gone", ctx do
    note = indexed(ctx)
    old_rows = rows(note)
    old_dense = dense_by_position(note, ctx.store)

    assert {:ok, count, 0, true} = rebuild(note, ctx.vault, ctx.user)
    assert embedded() == []

    new_rows = rows(note)
    assert length(new_rows) == count

    fps = Enum.map(new_rows, & &1.context_hmac)

    assert Enum.map(new_rows, & &1.qdrant_point_id) ==
             Enum.zip_with(fps, PointId.ordinals(fps), &PointId.v5(note.id, &1, &2))

    # f16 storage keeps a copied f32 within 1e-3.
    for {pos, dense} <- dense_by_position(note, ctx.store),
        dense != nil,
        {a, b} <- Enum.zip(dense, old_dense[pos]),
        do: assert(abs(a - b) < 1.0e-3)

    # Only the new points remain, and the rows name exactly them.
    assert MapSet.new(Map.keys(points(ctx.store))) ==
             MapSet.new(new_rows, & &1.qdrant_point_id)

    refute Enum.any?(old_rows, &Map.has_key?(points(ctx.store), &1.qdrant_point_id))
    refute Enum.any?(Map.values(points(ctx.store)), &Map.has_key?(&1.payload, "text"))

    point_rows =
      tenant(ctx.user, fn -> Repo.all(from(p in ChunkPoint, where: p.note_id == ^note.id)) end)

    assert length(point_rows) == count
  end

  # The dry run's estimate (`rebuild_estimate/2`) and the pass plan from the
  # same parse, rows and fingerprints, so the estimate is exactly what the
  # pass sends Voyage. A note with partial reuse and a block repeated more
  # times than the stored rows hold (staging rehearsal 2026-10-22: the pass
  # spent 0.144x of the manifest).
  test "the dry-run estimate is exactly what the rebuild sends Voyage", ctx do
    repeated = "## Repeated\n\nthe same block of words. #{@pad}"
    first = sections(4) <> "\n\n" <> repeated <> "\n\n" <> repeated
    note = insert_note(ctx.user, ctx.vault, first)
    assert {:ok, _, _, true} = Indexing.index_note_with_usage(note, ctx.vault, ctx.user)
    _ = embedded()

    # Two sections reworded, one added, the repeated block now three times.
    content =
      first
      |> String.replace("section2 body", "section2 reworded body")
      |> String.replace("section3 body", "section3 reworded body")
      |> Kernel.<>("\n\n## S9\n\nnew section. #{@pad}\n\n" <> repeated)

    changed = %{note | content: content}
    {:ok, est} = tenant(ctx.user, fn -> Indexing.rebuild_estimate(changed, ctx.user) end)
    assert est.new_points >= 4 and est.reused_points >= 4

    assert {:ok, _, _, true} = rebuild(changed, ctx.vault, ctx.user)
    sent = embedded()

    assert sent != []
    assert est.est_tokens == sent |> Enum.map(&UsageMeters.estimate_tokens/1) |> Enum.sum()
  end

  # What the staging rehearsal (2026-10-22) actually saw: the pass runs with
  # the vector cache on (`index_rebuild=on` requires it), and the cache is
  # per USER, so a text two notes share is paid once. The estimate is per
  # note and counts it in both: per note it is exact, summed over a user's
  # notes it is an upper bound. Staging's one paid user: 13,189 new points,
  # 1,381 texts cached (sent), spend 0.144x the manifest.
  test "with the vector cache on, a text two notes share is sent once", ctx do
    Application.put_env(:engram, :vector_cache_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :vector_cache_enabled) end)

    shared = sections(3) <> "\n\n## New\n\nshared new text. #{@pad}"
    a = indexed(ctx)
    b = Engram.Fixtures.insert_note!(ctx.user, ctx.vault, %{path: "B.md", content: shared})
    {:ok, b} = Crypto.maybe_decrypt_note_fields(b, ctx.user)
    _ = embedded()

    [{est_a, sent_a}, {est_b, sent_b}] =
      for note <- [%{a | content: shared}, b] do
        {:ok, est} = tenant(ctx.user, fn -> Indexing.rebuild_estimate(note, ctx.user) end)
        assert {:ok, _, _, true} = rebuild(note, ctx.vault, ctx.user)
        {est.est_tokens, embedded() |> Enum.map(&UsageMeters.estimate_tokens/1) |> Enum.sum()}
      end

    # `a` reuses its 3 sections and sends `New`, exactly its estimate. `b`
    # (never indexed) is estimated at all 4 texts, and every one is a cache
    # hit from `a`'s index and rebuild: the user pays 144 of an estimated 726.
    assert sent_a == est_a and est_a > 0
    assert est_b > est_a and sent_b == 0
  end

  test "a capped group of all-dense members gets a unit-norm mean and 0 tokens", ctx do
    note = indexed(ctx, 200)
    enable_index_budget()

    assert {:ok, count, 0, true} = rebuild(note, ctx.vault, ctx.user)
    assert count <= 128
    assert embedded() == []

    merged = Enum.filter(rows(note), &(&1.member_hmacs != nil))
    assert merged != []

    for row <- merged do
      dense = points(ctx.store)[row.qdrant_point_id].dense
      norm = :math.sqrt(Enum.reduce(dense, 0.0, &(&1 * &1 + &2)))
      assert abs(norm - 1.0) < 1.0e-3
    end
  end

  test "H8: a refused upsert (507) keeps the old points searchable and the note retried", ctx do
    note = indexed(ctx)
    before = points(ctx.store)
    old_rows = rows(note)
    refuse(ctx.store, true)

    assert {:error, :qdrant_backpressure} = rebuild(note, ctx.vault, ctx.user)
    assert points(ctx.store) == before
    assert deletes(ctx.store) == []
    assert Enum.map(rows(note), & &1.qdrant_point_id) == Enum.map(old_rows, & &1.qdrant_point_id)

    refuse(ctx.store, false)
    assert {:ok, _, 0, true} = rebuild(note, ctx.vault, ctx.user)
    refute Enum.any?(old_rows, &Map.has_key?(points(ctx.store), &1.qdrant_point_id))
  end

  test "H4: an edit committed mid-rebuild discards the stale plan without deleting", ctx do
    note = indexed(ctx)
    old_ids = Enum.map(rows(note), & &1.qdrant_point_id)

    tenant(ctx.user, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^note.id), set: [content_hash: "newer"])
    end)

    assert {:error, :superseded} = rebuild(note, ctx.vault, ctx.user)
    assert Enum.map(rows(note), & &1.qdrant_point_id) == old_ids
    assert Enum.all?(old_ids, &Map.has_key?(points(ctx.store), &1))
    assert deletes(ctx.store) == []
  end

  test "flat fields and note_attrs are re-extracted from the current frontmatter", ctx do
    ServiceConfig.put_override(:v5_payload_format, true)
    note = indexed(ctx)

    attrs = fn ->
      tenant(ctx.user, fn ->
        Repo.all(from(a in NoteAttr, where: a.note_id == ^note.id, order_by: [a.key_id, a.ord]))
      end)
    end

    fresh = attrs.()
    assert fresh != []

    # Stale: as if extracted before the mapping existed.
    tenant(ctx.user, fn -> Repo.delete_all(from(a in NoteAttr, where: a.note_id == ^note.id)) end)
    ServiceConfig.put_override(:v5_payload_format, false)

    assert {:ok, _, 0, true} = rebuild(note, ctx.vault, ctx.user)
    assert attrs.() == fresh
  end

  # A note written with a localized key before the alias table existed was
  # indexed with it as a user key; the rebuild's re-extraction maps it.
  test "the rebuild re-extraction maps a localized key to its named field", ctx do
    note = insert_note(ctx.user, ctx.vault, "---\n状態: draft\n---\n# Big\n\nbody. #{@pad}")
    assert {:ok, _, _, true} = Indexing.index_note_with_usage(note, ctx.vault, ctx.user)
    tenant(ctx.user, fn -> Repo.delete_all(from(a in NoteAttr, where: a.note_id == ^note.id)) end)

    assert {:ok, _, _, true} = rebuild(note, ctx.vault, ctx.user)
    {:ok, fk} = Crypto.dek_filter_key(ctx.user)
    status = Engram.Notes.FrontmatterKeys.named_id(:status)

    assert [%{key_id: ^status, h: h}] =
             tenant(ctx.user, fn ->
               Repo.all(from(a in NoteAttr, where: a.note_id == ^note.id))
             end)

    assert h == Engram.Vector.FilterId.value_hmac(fk, "draft")
  end

  test "the Voyage-paid stamp: set when Voyage returns, cleared by the commit", ctx do
    note = indexed(ctx)
    drop_dense(ctx.store)
    refuse(ctx.store, true)

    assert {:error, :qdrant_backpressure} = rebuild(note, ctx.vault, ctx.user)
    assert embedded() != []
    assert reload(note).rebuild_paid_at != nil

    # The retry reuses the retained vectors: no second payment, and it commits.
    refuse(ctx.store, false)
    assert {:ok, _, _, true} = rebuild(reload_decrypted(note, ctx.user), ctx.vault, ctx.user)
    assert embedded() == []
    assert reload(note).rebuild_paid_at == nil
  end

  # A rebuild paid, failed its write, and an edit's pass committed from a row
  # it loaded BEFORE that stamp. The commit must still clear it: left set,
  # the next rebuild of this note parks as a double pay.
  test "any committing pass clears the stamp, even from a row loaded before it", ctx do
    note = indexed(ctx)
    assert note.rebuild_paid_at == nil

    tenant(ctx.user, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^note.id),
        set: [rebuild_paid_at: DateTime.utc_now()]
      )
    end)

    assert {:ok, _, _, _} = Indexing.index_note_with_usage(note, ctx.vault, ctx.user)
    assert reload(note).rebuild_paid_at == nil
  end

  test "a second Voyage call for an already-paid note parks it rebuild_double_pay", ctx do
    note = indexed(ctx)
    drop_dense(ctx.store)

    tenant(ctx.user, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^note.id),
        set: [rebuild_paid_at: DateTime.utc_now()]
      )
    end)

    assert {:error, :rebuild_double_pay} =
             rebuild(reload_decrypted(note, ctx.user), ctx.vault, ctx.user)

    assert embedded() == []
    assert reload(note).embed_retry_after == EmbedNote.parked_until_edited()
  end

  test "a rebuild job that killed its node reruns isolated as a rebuild", ctx do
    note = indexed(ctx)

    tenant(ctx.user, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^note.id),
        set: [
          embed_started_at: DateTime.utc_now(),
          embed_started_by: "engram@10.0.0.9/deadbeef",
          embed_started_hash: note.content_hash
        ]
      )
    end)

    args = %{"note_id" => note.id, "user_id" => note.user_id}
    job = %Oban.Job{worker: "Engram.Workers.RebuildStaleNote", queue: "rebuild", args: args}

    assert {:cancel, :isolated_after_node_death} = CrashGuard.check(reload(note), job)
    assert_enqueued(worker: RebuildStaleNote, queue: :embed_isolated, args: args)
    refute_enqueued(worker: EmbedNote, queue: :embed_isolated)
  end

  defp reload_decrypted(note, user) do
    {:ok, note} = Crypto.maybe_decrypt_note_fields(reload(note), user)
    note
  end
end
