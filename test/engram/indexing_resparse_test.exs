defmodule Engram.IndexingResparseTest do
  # Sparse-only re-index: rebuild every point's keyword vector in place
  # (Qdrant update-vectors), with no embedder call and no point churn. This is
  # how existing vectors move to a new tokenizer without a Voyage bill.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Notes

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    test_pid = self()

    Bypass.stub(bypass, :any, :any, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      send(test_pid, {:qdrant, conn.method, conn.request_path, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    content = "# Plan\n\nRunning containers in production.\n\n## Notes\n\nDeploying daily."

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "plan.md", "content" => content, "mtime" => 1.0})

    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, _} = Indexing.index_note(note, vault, user)
    upserted = upserted_points()
    assert upserted != []

    %{user: user, vault: vault, note: note, upserted: upserted}
  end

  defp upserted_points do
    receive do
      {:qdrant, "PUT", "/collections/" <> rest, body} ->
        if String.ends_with?(rest, "/points"),
          do: Jason.decode!(body)["points"] ++ upserted_points(),
          else: upserted_points()

      {:qdrant, _, _, _} ->
        upserted_points()
    after
      0 -> []
    end
  end

  test "rewrites each point's keyword vector in place, embedding nothing", ctx do
    %{user: user, note: note, upserted: upserted} = ctx
    expect(Engram.MockEmbedder, :embed_texts, 0, fn _ -> flunk("embedded") end)

    assert {:ok, count, 0} = Indexing.resparse_note(note, user)
    assert count == length(upserted)

    assert_receive {:qdrant, "PUT", path, body}
    assert String.ends_with?(path, "/points/vectors")
    %{"points" => updates} = Jason.decode!(body)

    # Same point ids, ONLY the keyword vector, and it is what the encoder
    # produces for that point's chunk today.
    assert Enum.map(updates, & &1["id"]) |> Enum.sort() ==
             Enum.map(upserted, & &1["id"]) |> Enum.sort()

    by_id = Map.new(upserted, &{&1["id"], &1["vector"]["keyword"]})

    for %{"id" => id, "vector" => vector} <- updates do
      assert Map.keys(vector) == ["keyword"]
      assert vector["keyword"] == by_id[id]
    end

    refute_received {:qdrant, "PUT", "/collections/" <> _, _}
  end

  test "a note with no chunk rows updates nothing", %{user: user, vault: vault} do
    {:ok, fresh} =
      Notes.upsert_note(user, vault, %{
        "path" => "new.md",
        "content" => "fresh text",
        "mtime" => 1.0
      })

    {:ok, fresh} = Crypto.maybe_decrypt_note_fields(fresh, user)

    assert {:ok, 0, 0} = Indexing.resparse_note(fresh, user)
    refute_received {:qdrant, "PUT", _, _}
  end

  # A row with no fingerprint (written before context_hmac existed, or
  # cleared by a DEK rotation) still names the chunk it holds by position and
  # offsets. Resparse rewrites only the keyword vector, from the current text,
  # so that is enough: these heal with no re-embed.
  test "matches a row with no fingerprint by its position and offsets", ctx do
    %{user: user, note: note, upserted: upserted} = ctx
    clear_one_fingerprint(note)

    assert {:ok, count, 0} = Indexing.resparse_note(note, user)
    assert count == length(upserted)
  end

  # A row matching nothing (a boundary the current chunker no longer
  # produces) keeps its old keyword vector, so it must be reported.
  test "counts stored points it cannot match", ctx do
    %{user: user, note: note, upserted: upserted} = ctx
    orphan_one_row(note)

    assert {:ok, count, 1} = Indexing.resparse_note(note, user)
    assert count == length(upserted) - 1
  end

  # Every note with an unmatchable point also carries a stale chunker_version
  # (legacy rows predate the fingerprint, or v1 chunks hold base64 blobs v2
  # strips), so the chunker rebuild owns it. A resparse that re-embedded here
  # turned an automatic keyword sweep into a corpus-wide Voyage bill, and over
  # a spent Free budget it dropped the note's dense vectors.
  test "unmatched points never trigger a re-embed; the note is still stamped", ctx do
    %{user: user, note: note} = ctx
    orphan_one_row(note)
    before = Repo.get!(Notes.Note, note.id, skip_tenant_check: true)

    embeds = fn ->
      length(all_enqueued(worker: Engram.Workers.EmbedNote, args: %{"note_id" => note.id}))
    end

    queued = embeds.()

    assert :ok =
             perform_job(Engram.Workers.RefreshKeywordVectors, %{
               note_id: note.id,
               user_id: user.id
             })

    # No rebuild enqueued (the fixture's own upsert already queued one), and
    # the index markers a rebuild would clear are untouched.
    assert embeds.() == queued
    reloaded = Repo.get!(Notes.Note, note.id, skip_tenant_check: true)

    assert {reloaded.embed_hash, reloaded.dense_indexed_hash} ==
             {before.embed_hash, before.dense_indexed_hash}

    assert reloaded.keyword_version == Engram.KeywordIndex.version()
  end

  # On a CURRENT chunker no rebuild is coming for a point that matches
  # nothing, so stamping would hide it for good; staying unstamped keeps it in
  # the sweep and logged.
  test "unmatched points on a current-chunker note leave it unstamped", ctx do
    %{user: user, note: note} = ctx
    orphan_one_row(note)

    Repo.update_all(
      from(n in Notes.Note, where: n.id == ^note.id),
      [set: [chunker_version: Engram.Parsers.Markdown.chunker_version(), keyword_version: nil]],
      skip_tenant_check: true
    )

    assert :ok =
             perform_job(Engram.Workers.RefreshKeywordVectors, %{
               note_id: note.id,
               user_id: user.id
             })

    assert is_nil(Repo.get!(Notes.Note, note.id, skip_tenant_check: true).keyword_version)
  end

  # Rows written between #1595 (context_hmac) and #1606 (pass-type prefix)
  # hold an UNPREFIXED hmac of context_text. Resparse rewrites only keyword
  # vectors, so matching them by text alone is safe.
  test "matches a point stored under the legacy unprefixed fingerprint", ctx do
    %{user: user, note: note, upserted: upserted} = ctx
    {:ok, key} = Crypto.dek_content_hash_key(user)
    [first | _] = Engram.Parsers.Markdown.parse(note.content, note.path)

    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.update_all(
          from(c in Engram.Notes.Chunk, where: c.note_id == ^note.id and c.position == 0),
          set: [context_hmac: Crypto.hmac_content_hash(key, first.context_text)]
        )
      end)

    assert {:ok, count, 0} = Indexing.resparse_note(note, user)
    assert count == length(upserted)
  end

  test "the job stamps the current keyword version on success", ctx do
    %{user: user, note: note} = ctx

    Repo.update_all(from(n in Notes.Note, where: n.id == ^note.id), [set: [keyword_version: nil]],
      skip_tenant_check: true
    )

    assert :ok =
             perform_job(Engram.Workers.RefreshKeywordVectors, %{
               note_id: note.id,
               user_id: user.id
             })

    assert Repo.get!(Notes.Note, note.id, skip_tenant_check: true).keyword_version ==
             Engram.KeywordIndex.version()
  end

  # No fingerprint AND offsets no current chunk has: unmatchable.
  defp orphan_one_row(note) do
    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        [id | _] =
          Repo.all(from(c in Engram.Notes.Chunk, where: c.note_id == ^note.id, select: c.id))

        Repo.update_all(from(c in Engram.Notes.Chunk, where: c.id == ^id),
          set: [context_hmac: nil, char_start: 999_000, char_end: 999_999]
        )
      end)
  end

  defp clear_one_fingerprint(note) do
    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        [id | _] =
          Repo.all(from(c in Engram.Notes.Chunk, where: c.note_id == ^note.id, select: c.id))

        Repo.update_all(from(c in Engram.Notes.Chunk, where: c.id == ^id),
          set: [context_hmac: nil]
        )
      end)
  end

  test "the RefreshKeywordVectors job runs the re-index for its note", ctx do
    %{user: user, note: note} = ctx

    assert :ok =
             perform_job(Engram.Workers.RefreshKeywordVectors, %{
               note_id: note.id,
               user_id: user.id
             })

    assert_receive {:qdrant, "PUT", path, _body}
    assert String.ends_with?(path, "/points/vectors")
  end

  # A chunk whose text changed since the last index has no point that is
  # "its" vector to fix; the next normal embed replaces it. Only chunks that
  # still match a stored point are rewritten.
  test "an edited note only rewrites the points that still match", ctx do
    %{user: user, note: note, upserted: upserted} = ctx

    edited = %{
      note
      | content: String.replace(note.content, "Deploying daily.", "Shipping weekly.")
    }

    assert {:ok, count, unmatched} = Indexing.resparse_note(edited, user)
    assert count > 0 and count + unmatched == length(upserted)
  end
end
