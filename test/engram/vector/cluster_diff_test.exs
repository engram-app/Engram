defmodule Engram.Vector.ClusterDiffTest do
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.ServiceConfig
  alias Engram.Vector.ClusterDiff

  # A Qdrant cluster: an Agent of id => point behind a Bypass, answering the
  # id-only scroll, the has_id scroll (with payload and vectors when asked)
  # and the upsert.
  defp start_cluster(points) do
    bypass = Bypass.open()
    {:ok, store} = Agent.start_link(fn -> Map.new(points, &{&1["id"], &1}) end)

    Bypass.stub(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      all = Agent.get(store, & &1)

      found =
        case body["filter"] do
          %{"must" => [%{"has_id" => ids}]} -> for id <- ids, Map.has_key?(all, id), do: all[id]
          _ -> Map.values(all)
        end

      found =
        Enum.map(found, fn p ->
          p
          |> then(&if body["with_payload"] == true, do: &1, else: Map.delete(&1, "payload"))
          |> then(&if body["with_vector"] == true, do: &1, else: Map.delete(&1, "vector"))
        end)

      json(conn, %{"result" => %{"points" => found, "next_page_offset" => nil}})
    end)

    Bypass.stub(bypass, "PUT", "/collections/test_col/points", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      for p <- Jason.decode!(raw)["points"],
          do: Agent.update(store, &Map.put(&1, p["id"], p))

      json(conn, %{"result" => %{"status" => "completed"}})
    end)

    {bypass, store}
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp point(id),
    do: %{"id" => id, "vector" => %{"dense" => [0.1, 0.2]}, "payload" => %{"u" => "x"}}

  defp insert_chunk!(note, point_id, position) do
    Repo.insert!(
      %Chunk{
        note_id: note.id,
        user_id: note.user_id,
        vault_id: note.vault_id,
        position: position,
        char_start: 0,
        char_end: 10,
        qdrant_point_id: point_id
      },
      skip_tenant_check: true
    )
  end

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)

    note =
      insert(:note, user: user, vault: vault, embed_hash: "h", content_hash: "h")

    [a, b, c] = for _ <- 1..3, do: Ecto.UUID.generate()
    stray = Ecto.UUID.generate()
    for {id, i} <- Enum.with_index([a, b, c]), do: insert_chunk!(note, id, i)

    # old holds a and b; v2 holds a and a point no chunk row names. So on v2
    # b is missing (copyable from old) and c is missing (on neither).
    {old, _} = start_cluster([point(a), point(b)])
    {v2, v2_store} = start_cluster([point(a), point(stray)])

    ServiceConfig.put_override(:qdrant_collection, "test_col")
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{old.port}")
    ServiceConfig.put_override(:qdrant_url_v2, "http://localhost:#{v2.port}")

    %{user: user, note: note, ids: %{a: a, b: b, c: c, stray: stray}, v2_store: v2_store}
  end

  test "reports ids missing on the target and extra ids, read-only by default", ctx do
    assert {:ok, report} = ClusterDiff.run("old", "v2", pause_ms: 0)

    assert report.checked == 3
    assert report.missing == 2
    assert Enum.sort(report.missing_sample) == Enum.sort([ctx.ids.b, ctx.ids.c])
    assert report.missing_by_user == %{ctx.user.id => 2}
    assert report.extra == 1
    assert report.extra_sample == [ctx.ids.stray]
    assert report.copied == 0

    # Nothing was written to the target.
    refute Map.has_key?(Agent.get(ctx.v2_store, & &1), ctx.ids.b)
  end

  test "repair copies what the source holds, vectors and payload, and nothing else", ctx do
    assert {:ok, report} = ClusterDiff.run("old", "v2", repair: true, pause_ms: 0)

    assert report.copied == 1
    assert report.unrecoverable == 1
    assert report.flagged_notes == 0
    assert Agent.get(ctx.v2_store, & &1[ctx.ids.b]) == point(ctx.ids.b)
    # Not re-indexed without `reindex: true`: that spends Voyage.
    assert Repo.get!(Note, ctx.note.id, skip_tenant_check: true).embed_hash == "h"

    assert {:ok, again} = ClusterDiff.run("old", "v2", pause_ms: 0)
    assert again.missing == 1
  end

  test "reindex flags notes whose points neither cluster holds, only on the active target",
       ctx do
    assert {:error, :target_not_active} =
             ClusterDiff.run("old", "v2", repair: true, reindex: true, pause_ms: 0)

    ServiceConfig.put_override(:qdrant_active_cluster, "v2")

    assert {:ok, report} =
             ClusterDiff.run("old", "v2", repair: true, reindex: true, pause_ms: 0)

    assert report.flagged_notes == 1
    assert is_nil(Repo.get!(Note, ctx.note.id, skip_tenant_check: true).embed_hash)
    assert_enqueued(worker: Engram.Workers.ReconcileEmbeddings)
  end

  test "user_ids limits the walk and skips the whole-collection extra scan", ctx do
    assert {:ok, report} = ClusterDiff.run("old", "v2", user_ids: [ctx.user.id], pause_ms: 0)
    assert report.missing == 2
    assert report.extra == nil

    assert {:ok, other} =
             ClusterDiff.run("old", "v2", user_ids: [Ecto.UUID.generate()], pause_ms: 0)

    assert other.checked == 0
  end

  # A node on a stale cache (lost eviction, no mesh, an in-flight request
  # with retries) writes the OLD cluster after the flip. New point ids show up
  # as missing and are copied; a payload or sparse rewrite of an EXISTING id
  # leaves v2 holding the pre-flip version under the same id, which no id
  # diff can see. `since:` hands every note changed since then to the $0
  # heals (ReconcileNotePayloads, keyword refresh) on the active cluster.
  test "since requeues the payload and keyword heals for notes changed since", ctx do
    since = DateTime.add(DateTime.utc_now(), -3600)

    assert {:error, :target_not_active} =
             ClusterDiff.run("old", "v2", since: since, pause_ms: 0)

    ServiceConfig.put_override(:qdrant_active_cluster, "v2")

    before =
      insert(:note,
        user: ctx.user,
        vault: ctx.note.vault,
        updated_at: DateTime.add(since, -60) |> DateTime.truncate(:second)
      )

    for n <- [ctx.note, before] do
      Repo.update_all(
        from(x in Note, where: x.id == ^n.id),
        [set: [payload_hash: <<1>>, keyword_version: 1]],
        skip_tenant_check: true
      )
    end

    assert {:ok, report} = ClusterDiff.run("old", "v2", since: since, pause_ms: 0)
    assert report.requeued_notes == 1

    healed = Repo.get!(Note, ctx.note.id, skip_tenant_check: true)
    assert is_nil(healed.payload_hash) and is_nil(healed.keyword_version)
    untouched = Repo.get!(Note, before.id, skip_tenant_check: true)
    assert untouched.payload_hash == <<1>> and untouched.keyword_version == 1

    assert_enqueued(
      worker: Engram.Workers.ReconcileNotePayloads,
      args: %{"user_id" => ctx.user.id}
    )
  end

  test "since is validated before the walk and requeued in paced id batches", ctx do
    ServiceConfig.put_override(:qdrant_active_cluster, "v2")

    assert {:error, {:invalid_since, "2026-10-21"}} =
             ClusterDiff.run("old", "v2", since: "2026-10-21", pause_ms: 0)

    _second = insert(:note, user: ctx.user, vault: ctx.note.vault)
    since = DateTime.add(DateTime.utc_now(), -3600)

    assert {:ok, report} =
             ClusterDiff.run("old", "v2", since: since, requeue_batch: 1, pause_ms: 0)

    assert report.requeued_notes == 2
    # Two notes at one per batch, plus the empty page that ends the walk is
    # not a batch.
    assert report.requeue_batches == 2
  end

  test "a walk resumes after the last chunk id a report names" do
    assert {:ok, first} = ClusterDiff.run("old", "v2", batch: 2, pause_ms: 0)
    assert first.checked == 3

    [first_id | _] =
      Repo.all(from(c in Chunk, order_by: c.id, select: c.id), skip_tenant_check: true)

    assert {:ok, resumed} = ClusterDiff.run("old", "v2", after: first_id, pause_ms: 0)
    assert resumed.checked == 2
    assert resumed.last_chunk_id == first.last_chunk_id
  end

  test "refuses to diff a cluster with itself" do
    assert {:error, :same_cluster} = ClusterDiff.run("v2", "v2")
  end
end
