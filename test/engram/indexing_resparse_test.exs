defmodule Engram.IndexingResparseTest do
  # Sparse-only re-index: rebuild every point's keyword vector in place
  # (Qdrant update-vectors), with no embedder call and no point churn. This is
  # how existing vectors move to a new tokenizer without a Voyage bill.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Crypto
  alias Engram.EmbedModels
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Parsers.Markdown

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

    Engram.QdrantStub.stub_healthy(bypass)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    content = "# Plan\n\nRunning containers in production.\n\n## Notes\n\nDeploying daily."

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "plan.md", "content" => content, "mtime" => 1.0},
        actor: "api"
      )

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
      Notes.upsert_note(
        user,
        vault,
        %{
          "path" => "new.md",
          "content" => "fresh text",
          "mtime" => 1.0
        },
        actor: "api"
      )

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

  # A resparse on unchanged content and chunker finds the same unmatched
  # points every time, so leaving the note unstamped only re-selected it every
  # backoff window: in prod 671 notes looped twice an hour, each pass
  # rewriting the matched points and logging an oban-category warning. The
  # note is stamped, logged once at info, and comes back only when something
  # changes (an edit re-embeds it, a keyword bump re-selects it).
  for {label, chunker_offset} <- [{"current", 0}, {"newer", 1}] do
    test "unmatched points on a #{label}-chunker note stamp it so the sweep stops re-selecting it",
         ctx do
      %{user: user, note: note} = ctx
      orphan_one_row(note)

      Repo.update_all(
        from(n in Notes.Note, where: n.id == ^note.id),
        [
          set: [
            chunker_version: Markdown.chunker_version() + unquote(chunker_offset),
            keyword_version: nil
          ]
        ],
        skip_tenant_check: true
      )

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          assert :ok =
                   perform_job(Engram.Workers.RefreshKeywordVectors, %{
                     note_id: note.id,
                     user_id: user.id
                   })
        end)

      assert Repo.get!(Notes.Note, note.id, skip_tenant_check: true).keyword_version ==
               elem(Engram.Rebuild.target_versions(), 1)

      refute log =~ "resparse", "logged once at info, not as an oban warning"
    end
  end

  # Rows written between #1595 (context_hmac) and #1606 (pass-type prefix)
  # hold an UNPREFIXED hmac of context_text. Resparse rewrites only keyword
  # vectors, so matching them by text alone is safe.
  test "matches a point stored under the legacy unprefixed fingerprint", ctx do
    %{user: user, note: note, upserted: upserted} = ctx
    {:ok, key} = Crypto.dek_content_hash_key(user)
    [first | _] = Markdown.parse(note.content, note.path)

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

  # A DEK rotation's flip (or a payload-drift heal) clears `keyword_version`
  # while this job's resparse is in flight: those points were just encoded
  # under the retired filter key. Stamping over the NULL would keep them on
  # that key for good, so the stamp is compare-and-set, as EmbedNote's
  # (#2216 L1).
  test "a keyword_version clear that lands during the job is kept", ctx do
    %{user: user, note: note} = ctx

    Repo.update_all(from(n in Notes.Note, where: n.id == ^note.id), [set: [keyword_version: 1]],
      skip_tenant_check: true
    )

    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Engram.QdrantStub.stub_healthy(bypass)

    Bypass.stub(bypass, :any, :any, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)

      if String.ends_with?(conn.request_path, "/points/vectors") do
        Repo.update_all(
          from(n in Notes.Note, where: n.id == ^note.id),
          [set: [keyword_version: nil]],
          skip_tenant_check: true
        )
      end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
    end)

    assert :ok =
             perform_job(Engram.Workers.RefreshKeywordVectors, %{
               note_id: note.id,
               user_id: user.id
             })

    assert is_nil(Repo.get!(Notes.Note, note.id, skip_tenant_check: true).keyword_version)
  end

  # Before `INDEX_REBUILD=on` the target is the pin: stamping the build here
  # would make the v5 pass skip a note it must re-encode (pinned avgdl).
  test "before the v5 pass the job stamps the pinned keyword version", ctx do
    %{user: user, note: note} = ctx
    Engram.ServiceConfig.put_override(:rebuild_pinned_versions, Engram.Rebuild.pinned_versions())

    Repo.update_all(from(n in Notes.Note, where: n.id == ^note.id), [set: [keyword_version: nil]],
      skip_tenant_check: true
    )

    assert :ok =
             perform_job(Engram.Workers.RefreshKeywordVectors, %{
               note_id: note.id,
               user_id: user.id
             })

    assert Repo.get!(Notes.Note, note.id, skip_tenant_check: true).keyword_version ==
             elem(Engram.Rebuild.pinned_versions(), 1)
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

  # Per plan (SaaS), a Free note's points are fingerprinted with
  # voyage-4-lite while the build's model is voyage-4-large. Resparse runs
  # outside an index pass, so it must try every plan model's dense
  # fingerprint, or every Free note matches nothing, stays unstamped, and the
  # keyword sweep retries it forever (staging 2026-10-28: 1,300 notes).
  describe "per-plan models" do
    @lite "voyage-4-lite"
    @large "voyage-4-large"

    setup %{user: user, vault: vault} do
      prev = Map.new([:billing_enabled, :embed_model], &{&1, Application.get_env(:engram, &1)})

      on_exit(fn ->
        for {k, v} <- prev do
          if v == nil,
            do: Application.delete_env(:engram, k),
            else: Application.put_env(:engram, k, v)
        end
      end)

      Application.put_env(:engram, :billing_enabled, true)
      Application.put_env(:engram, :embed_model, @large)

      # A nameable model calls the embedder with it (`embed_texts/2`).
      stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      content = "# Essay\n\nPlain prose about gardens.\n\n## More\n\nTomatoes like sun."

      {:ok, prose} =
        Notes.upsert_note(
          user,
          vault,
          %{"path" => "essay.md", "content" => content, "mtime" => 1.0},
          actor: "api"
        )

      {:ok, prose} = Crypto.maybe_decrypt_note_fields(prose, user)
      %{prose: prose}
    end

    defp index_with(note, vault, user, model) do
      {:ok, _, _, true} = Indexing.index_note_with_usage(note, vault, user, doc_model: model)
      points = upserted_points()
      assert points != []
      points
    end

    test "a Free note embedded with lite matches every point", ctx do
      %{user: user, vault: vault, prose: prose} = ctx
      assert EmbedModels.doc_model(user) == @lite
      points = index_with(prose, vault, user, @lite)

      assert {:ok, count, 0} = Indexing.resparse_note(prose, user)
      assert count == length(points)
    end

    test "a large-model note still matches every point", ctx do
      %{user: user, vault: vault, prose: prose} = ctx
      points = index_with(prose, vault, user, @large)

      assert {:ok, count, 0} = Indexing.resparse_note(prose, user)
      assert count == length(points)
    end

    # A downgraded note keeps its large vectors and embeds only new chunks
    # with lite, so one note holds points under both models' fingerprints.
    test "a note mixing large and lite points matches each exactly once", ctx do
      %{user: user, vault: vault} = ctx

      section = fn h, word ->
        "## #{h}\n\n" <> String.duplicate("#{word} grows in the bed. ", 60)
      end

      base =
        "# Garden\n\n" <>
          Enum.map_join([{"A", "Basil"}, {"B", "Thyme"}], "\n\n", fn {h, w} -> section.(h, w) end)

      upsert = fn content, mtime ->
        {:ok, n} =
          Notes.upsert_note(
            user,
            vault,
            %{"path" => "garden.md", "content" => content, "mtime" => mtime},
            actor: "api"
          )

        {:ok, n} = Crypto.maybe_decrypt_note_fields(n, user)
        n
      end

      index_with(upsert.(base, 1.0), vault, user, @large)
      edited = upsert.(base <> "\n\n" <> section.("C", "Pepper"), 2.0)
      test_pid = self()

      stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts ->
        send(test_pid, {:embedded, length(texts)})
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      {:ok, _, _, true} = Indexing.index_note_with_usage(edited, vault, user, doc_model: @lite)
      _ = upserted_points()

      rows =
        Repo.all(
          from(c in Engram.Notes.Chunk,
            where: c.note_id == ^edited.id and not is_nil(c.qdrant_point_id)
          ),
          skip_tenant_check: true
        )

      # Mixed for real: lite embedded only the new chunk, the rest kept large.
      assert_received {:embedded, sent}
      assert sent > 0 and sent < length(rows)

      assert {:ok, count, 0} = Indexing.resparse_note(edited, user)
      assert count == length(rows)
    end

    test "the job stamps a current-chunker lite note with the target keyword version", ctx do
      %{user: user, vault: vault, prose: prose} = ctx
      index_with(prose, vault, user, @lite)

      Repo.update_all(
        from(n in Notes.Note, where: n.id == ^prose.id),
        [set: [chunker_version: Markdown.chunker_version(), keyword_version: nil]],
        skip_tenant_check: true
      )

      assert :ok =
               perform_job(Engram.Workers.RefreshKeywordVectors, %{
                 note_id: prose.id,
                 user_id: user.id
               })

      assert Repo.get!(Notes.Note, prose.id, skip_tenant_check: true).keyword_version ==
               elem(Engram.Rebuild.target_versions(), 1)
    end
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
