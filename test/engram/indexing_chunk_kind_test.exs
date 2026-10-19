defmodule Engram.IndexingChunkKindTest do
  @moduledoc """
  Embed less: only `kind == "prose"` chunks get a dense vector. A frontmatter
  chunk is sparse-only even on a dense pass, so it costs no Voyage tokens and
  no dense storage, and keyword search still finds its keys and values.
  """
  use Engram.DataCase, async: true

  import Ecto.Query
  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.KeywordIndex.QdrantSparse
  alias Engram.Notes
  alias Engram.Notes.Chunk
  alias Engram.Parsers.Markdown
  alias Engram.ServiceConfig
  alias Engram.UsageMeters

  setup :verify_on_exit!

  @content """
  ---
  project: zanzibar
  ---
  # Plan

  The first section talks about the launch.

  ## Risks

  The second section lists what could go wrong.
  """

  @frontmatter_only """
  ---
  project: zanzibar
  ---
  """

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    test_pid = self()

    Bypass.stub(bypass, :any, :any, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

      if conn.method == "PUT" and String.ends_with?(conn.request_path, "/points") do
        send(test_pid, {:upserted, Jason.decode!(body)["points"]})
      end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      send(test_pid, {:embedded, texts})
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    %{user: user, vault: vault}
  end

  defp put_note(ctx, content) do
    {:ok, note} =
      Notes.upsert_note(
        ctx.user,
        ctx.vault,
        %{"path" => "Plan.md", "content" => content, "mtime" => 1_000.0},
        actor: "api"
      )

    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, ctx.user)
    note
  end

  defp drain(tag) do
    receive do
      {^tag, items} -> items ++ drain(tag)
    after
      0 -> []
    end
  end

  defp chunk_rows(note) do
    Repo.all(from(c in Chunk, where: c.note_id == ^note.id, order_by: c.position),
      skip_tenant_check: true
    )
  end

  defp has_dim?(point, user, token) do
    {:ok, key} = Crypto.dek_filter_key(user)
    %{indices: indices} = QdrantSparse.unpack(point.vector["keyword"])
    QdrantSparse.dim(key, token) in indices
  end

  test "parse tags the frontmatter chunk and leaves the rest prose" do
    kinds = @content |> Markdown.parse("Plan.md") |> Enum.map(&{&1.heading_path, &1.kind})
    assert kinds == [{"Plan", "prose"}, {"Plan > Risks", "prose"}, {"frontmatter", "frontmatter"}]
  end

  test "a dense pass embeds only the prose chunks; frontmatter is sparse-only", ctx do
    note = put_note(ctx, @content)

    assert {:ok, prepared} = Indexing.prepare_index(note, ctx.vault, ctx.user)

    sent = drain(:embedded)
    assert length(sent) == 2
    refute Enum.any?(sent, &(&1 =~ "zanzibar"))

    assert [p1, p2, fm] = prepared.qdrant_points
    assert Map.has_key?(p1.vector, "dense")
    assert Map.has_key?(p2.vector, "dense")
    refute Map.has_key?(fm.vector, "dense")
    assert has_dim?(fm, ctx.user, "zanzibar"), "keyword search must find a frontmatter value"
    assert prepared.dense?
  end

  test "a frontmatter-only note writes one sparse-only point, found by keyword", ctx do
    note = put_note(ctx, @frontmatter_only)

    assert {:ok, prepared} = Indexing.prepare_index(note, ctx.vault, ctx.user)

    assert drain(:embedded) == []
    assert [point] = prepared.qdrant_points
    refute Map.has_key?(point.vector, "dense")
    assert has_dim?(point, ctx.user, "zanzibar")
    assert prepared.embedded_bytes == 0
  end

  test "metered tokens are the prose chunks' tokens only", ctx do
    note = put_note(ctx, @content)
    test_pid = self()

    reserve = fn tokens ->
      send(test_pid, {:reserved, [tokens]})
      true
    end

    assert {:ok, 3, embedded_bytes, true} =
             Indexing.index_note_with_usage(note, ctx.vault, ctx.user, reserve_tokens: reserve)

    prose_bytes =
      @content
      |> Markdown.parse("Plan.md")
      |> Enum.filter(&(&1.kind == "prose"))
      |> Enum.map(&byte_size(&1.embed_text))
      |> Enum.sum()

    assert embedded_bytes == prose_bytes
    assert drain(:reserved) == [UsageMeters.estimate_tokens(prose_bytes)]
  end

  test "re-indexing unchanged content reuses every point", ctx do
    note = put_note(ctx, @content)
    assert {:ok, 3} = Indexing.index_note(note, ctx.vault, ctx.user)
    first = note |> chunk_rows() |> Enum.map(& &1.qdrant_point_id)
    _ = drain(:embedded)
    _ = drain(:upserted)

    assert {:ok, 3} = Indexing.index_note(note, ctx.vault, ctx.user)

    assert drain(:embedded) == []
    assert drain(:upserted) == []
    assert note |> chunk_rows() |> Enum.map(& &1.qdrant_point_id) == first
  end

  # A chunker v3 index stored the frontmatter chunk as a DENSE point. Under v4
  # its fingerprint is sparse, so that point must not be reused (it holds a
  # vector we no longer want to pay to store) while the prose points are.
  test "a v3 dense frontmatter point is replaced sparse-only, prose reused", ctx do
    note = put_note(ctx, @content)
    assert {:ok, 3} = Indexing.index_note(note, ctx.vault, ctx.user)
    [r1, r2, fm_row] = chunk_rows(note)

    {:ok, content_key} = Crypto.dek_content_hash_key(ctx.user)
    fm = @content |> Markdown.parse("Plan.md") |> List.last()

    [dense_hmac] =
      Engram.Native.hmac_hex_many(
        content_key,
        "dense:#{Indexing.embed_model()}/embed_text\n",
        ["#{byte_size(fm.context_text)}:" <> fm.context_text <> fm.embed_text]
      )

    Repo.update_all(
      from(c in Chunk, where: c.id == ^fm_row.id),
      [set: [context_hmac: dense_hmac]],
      skip_tenant_check: true
    )

    _ = drain(:embedded)
    _ = drain(:upserted)

    assert {:ok, 3} = Indexing.index_note(note, ctx.vault, ctx.user)

    assert drain(:embedded) == []
    assert [point] = drain(:upserted)
    refute Map.has_key?(point["vector"], "dense")

    assert [n1, n2, n3] = chunk_rows(note)
    assert {n1.qdrant_point_id, n2.qdrant_point_id} == {r1.qdrant_point_id, r2.qdrant_point_id}
    assert n3.qdrant_point_id != fm_row.qdrant_point_id
  end

  @log_lines Enum.map_join(0..29, "\n", fn i ->
               "2026-10-19T05:14:#{String.pad_leading("#{i}", 2, "0")}.0863647Z id=zq98#{i} status=200"
             end)

  @with_data "# Plan\n\nThe first section talks about the launch.\n\n## Logs\n\n" <> @log_lines

  test "a log dump is a data chunk: sparse-only, its exact tokens still found", ctx do
    assert [{"Plan", "prose"}, {"Plan > Logs", "data"}] =
             @with_data |> Markdown.parse("Plan.md") |> Enum.map(&{&1.heading_path, &1.kind})

    note = put_note(ctx, @with_data)
    assert {:ok, prepared} = Indexing.prepare_index(note, ctx.vault, ctx.user)

    assert [sent] = drain(:embedded)
    assert sent =~ "launch"
    assert [prose, data] = prepared.qdrant_points
    assert Map.has_key?(prose.vector, "dense")
    refute Map.has_key?(data.vector, "dense")
    assert has_dim?(data, ctx.user, "zq987"), "keyword search must find an id inside data"
  end
end
