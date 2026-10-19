defmodule Engram.IndexingFloorTest do
  # async: false: the reconcile and EmbedNote paths assert on the global
  # Oban job table.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.KeywordIndex.QdrantSparse
  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.UsageMeters
  alias Engram.Workers.{EmbedNote, RebuildStaleNote, ReconcileEmbeddings}

  setup :verify_on_exit!

  # Three sections; "zymurgy" appears only in the last one.
  @content """
  # Brewing

  ## Grain

  Malted barley and wheat, milled coarse.

  ## Water

  Soft water, low in carbonate.

  ## Yeast

  Zymurgy is the study of fermentation.
  """

  defp floor_note(user, vault, path \\ "Brew/Notes.md", content \\ @content) do
    note = Engram.Fixtures.insert_note!(user, vault, %{path: path, content: content})
    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)
    note
  end

  defp chunk_rows(note) do
    {:ok, rows} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.all(from(c in Chunk, where: c.note_id == ^note.id, order_by: c.position))
      end)

    rows
  end

  defp avg_token_count(user, vault) do
    {:ok, avg} =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from(c in Chunk,
            where: c.vault_id == ^vault.id and not is_nil(c.token_count),
            select: avg(c.token_count)
          )
        )
      end)

    avg
  end

  defp reload(note) do
    {:ok, row} = Repo.with_tenant(note.user_id, fn -> Repo.get!(Note, note.id) end)
    row
  end

  describe "floor index (Bypass Qdrant)" do
    setup do
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

      Bypass.stub(bypass, :any, :any, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      {:ok, user} = Crypto.ensure_user_dek(insert(:user))
      vault = insert(:vault, user: user)
      %{user: user, vault: vault}
    end

    # No Mox expectation on the embedder: any call raises, which is the
    # "zero embedder calls" assertion.
    test "a 3-section note writes 1 row and 1 sparse-only point, unmetered", %{
      user: user,
      vault: vault
    } do
      note = floor_note(user, vault)
      assert length(Engram.Parsers.Markdown.parse(note.content, note.path)) >= 3
      before = UsageMeters.lifetime_embed_tokens(user.id)

      {:ok, prepared} = Indexing.prepare_index(note, vault, user, index_tier: "floor")

      assert [point] = prepared.qdrant_points
      assert Map.keys(point.vector) == ["keyword"]
      assert prepared.dense? == false
      assert prepared.embedded_bytes == 0

      assert {:ok, 1, 0, false} =
               Indexing.index_note_with_usage(note, vault, user, index_tier: "floor")

      assert [row] = chunk_rows(note)
      assert row.position == 0
      assert row.token_count == nil
      assert reload(note).index_tier == "floor"
      assert UsageMeters.lifetime_embed_tokens(user.id) == before
    end

    test "the floor vector carries every section's terms", %{user: user, vault: vault} do
      note = floor_note(user, vault)
      {:ok, prepared} = Indexing.prepare_index(note, vault, user, index_tier: "floor")
      [point] = prepared.qdrant_points
      %{indices: indices} = QdrantSparse.unpack(point.vector["keyword"])
      {:ok, key} = Crypto.dek_filter_key(user)

      for term <- ["barley", "carbonate", "zymurgy", "brewing"] do
        assert QdrantSparse.dim(key, term) in indices, "missing #{term}"
      end
    end

    test "the note's own index_tier selects the floor path; a full pass clears it", %{
      user: user,
      vault: vault
    } do
      note = floor_note(user, vault)
      note = %{note | index_tier: "floor_paid"}

      assert {:ok, 1, 0, false} = Indexing.index_note_with_usage(note, vault, user)
      assert reload(note).index_tier == "floor_paid"

      # `index_tier: nil` forces a full pass, which clears the tier.
      Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      assert {:ok, count, _bytes, true} =
               Indexing.index_note_with_usage(note, vault, user, index_tier: nil)

      assert count >= 3
      assert reload(note).index_tier == nil
      assert Enum.all?(chunk_rows(note), &is_integer(&1.token_count))
    end

    test "the floor row's token_count is NULL and the vault avgdl is unchanged", %{
      user: user,
      vault: vault
    } do
      Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      full = floor_note(user, vault, "Other.md", "# Other\n\nSome unrelated words here.")
      {:ok, _} = Indexing.index_note(full, vault, user)
      avg_before = avg_token_count(user, vault)
      assert avg_before

      note = floor_note(user, vault)
      {:ok, 1, 0, false} = Indexing.index_note_with_usage(note, vault, user, index_tier: "floor")

      assert [%{token_count: nil}] = chunk_rows(note)
      assert avg_token_count(user, vault) == avg_before
    end

    test "the floor payload decrypts through decrypt_qdrant_candidates with empty text", %{
      user: user,
      vault: vault
    } do
      note = floor_note(user, vault)
      {:ok, prepared} = Indexing.prepare_index(note, vault, user, index_tier: "floor")
      [point] = prepared.qdrant_points
      p = point.payload

      candidate = %{
        score: 1.0,
        qdrant_id: point.id,
        vault_id: to_string(vault.id),
        text: p.text,
        text_nonce: p.text_nonce,
        title: p.title,
        title_nonce: p.title_nonce,
        heading_path: p.heading_path,
        heading_path_nonce: p.heading_path_nonce,
        aad_version: p.aad_version
      }

      collection = Application.get_env(:engram, :qdrant_collection, "obsidian_notes")

      assert {:ok, [out]} =
               Crypto.decrypt_qdrant_candidates(
                 [candidate],
                 user,
                 %{to_string(vault.id) => vault},
                 collection
               )

      assert out.text == ""
    end

    for tier <- [:free, :starter] do
      test "two reconcile ticks after flooring enqueue nothing (#{tier})", %{
        user: user,
        vault: vault
      } do
        if unquote(tier) == :starter,
          do: insert(:subscription, user: user, tier: "starter", status: "active")

        note = floor_note(user, vault)

        {:ok, _} =
          Repo.with_tenant(user.id, fn ->
            Repo.update_all(from(n in Note, where: n.id == ^note.id), set: [index_tier: "floor"])
          end)

        # The real embed job floors it (index_tier is on the row) and stamps.
        assert :ok =
                 perform_job(EmbedNote, %{"note_id" => note.id, "user_id" => user.id})

        floored = reload(note)
        assert floored.embed_hash == floored.content_hash
        assert [%{token_count: nil}] = chunk_rows(note)

        for _tick <- 1..2 do
          assert :ok = perform_job(ReconcileEmbeddings, %{})
          refute_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
          refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})

          # Any cooldown either path stamped lapses before the next tick.
          {:ok, _} =
            Repo.with_tenant(user.id, fn ->
              Repo.update_all(from(n in Note, where: n.id == ^note.id),
                set: [embed_retry_after: DateTime.add(DateTime.utc_now(), -1, :second)]
              )
            end)
        end
      end
    end

    test "a re-delivered embed job for a floored note at current content is a no-op", %{
      user: user,
      vault: vault
    } do
      note = floor_note(user, vault)

      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(n in Note, where: n.id == ^note.id), set: [index_tier: "floor"])
        end)

      assert :ok = perform_job(EmbedNote, %{"note_id" => note.id, "user_id" => user.id})
      [%{qdrant_point_id: point_id}] = chunk_rows(note)

      assert :ok = perform_job(EmbedNote, %{"note_id" => note.id, "user_id" => user.id})
      assert [%{qdrant_point_id: ^point_id}] = chunk_rows(note)
      assert reload(note).embed_budget_parked == nil
    end

    test "a keyword refresh re-floors a floor note instead of resparsing chunks", %{
      user: user,
      vault: vault
    } do
      note = floor_note(user, vault, "One.md", "# One\n\nA single section.")
      note = %{note | index_tier: "floor"}
      {:ok, 1, 0, false} = Indexing.index_note_with_usage(note, vault, user)

      assert {:ok, 1, 0} = Indexing.resparse_note(note, user)
      assert [%{token_count: nil}] = chunk_rows(note)
    end
  end

  describe "BM25 length cap" do
    test "cap_doc_len scores a long document as if it were avgdl long" do
      key = :crypto.strong_rand_bytes(32)
      long = Enum.map_join(1..400, " ", &"word#{&1}")

      [{capped, _}] = QdrantSparse.encode_documents([long], key, 100.0, nil, cap_doc_len: true)
      [{plain, n}] = QdrantSparse.encode_documents([long], key, 100.0, nil)
      assert n > 100

      [w | _] = QdrantSparse.unpack(capped).values
      [p | _] = QdrantSparse.unpack(plain).values

      # tf = 1 at norm = 1: (k1 + 1) / (1 + k1) = 1.0 exactly.
      assert_in_delta w, 1.0, 1.0e-9
      assert p < w
    end

    test "cap_doc_len leaves a document shorter than avgdl unchanged" do
      key = :crypto.strong_rand_bytes(32)

      assert QdrantSparse.encode_documents(["short text"], key, 100.0, nil, cap_doc_len: true) ==
               QdrantSparse.encode_documents(["short text"], key, 100.0, nil)
    end
  end

  describe "floor search (real Qdrant)" do
    @describetag :qdrant_integration

    setup do
      url = System.get_env("QDRANT_URL") || Application.get_env(:engram, :qdrant_url)
      ServiceConfig.put_override(:qdrant_url, url)

      col =
        "engram_test_#{System.get_env("MIX_TEST_PARTITION")}_#{System.unique_integer([:positive])}"

      old_col = Application.get_env(:engram, :qdrant_collection)
      Application.put_env(:engram, :qdrant_collection, col)

      on_exit(fn ->
        Engram.Vector.Qdrant.delete_collection(col)
        Application.put_env(:engram, :qdrant_collection, old_col)
      end)

      dims = Application.get_env(:engram, :embed_dims, 1024)

      Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, dims) end)}
      end)

      {:ok, user} = Crypto.ensure_user_dek(insert(:user))
      vault = insert(:vault, user: user)
      %{user: user, vault: vault, collection: col}
    end

    defp search(col, user, vault, query) do
      {:ok, key} = Crypto.dek_filter_key(user)
      sparse = QdrantSparse.encode_query(query, key)

      {:ok, hits} =
        Engram.Vector.Qdrant.sparse_search(col, sparse,
          user_id: to_string(user.id),
          vault_id: to_string(vault.id),
          limit: 10
        )

      hits
    end

    defp await_hits(col, user, vault, query, want, tries \\ 50) do
      hits = search(col, user, vault, query)

      if length(hits) >= want or tries == 0 do
        hits
      else
        Process.sleep(100)
        await_hits(col, user, vault, query, want, tries - 1)
      end
    end

    defp point_id(note), do: hd(chunk_rows(note)).qdrant_point_id

    test "a term only in section 3 finds the floor note; it decrypts to empty text", %{
      user: user,
      vault: vault,
      collection: col
    } do
      note = floor_note(user, vault)
      {:ok, 1, 0, false} = Indexing.index_note_with_usage(note, vault, user, index_tier: "floor")

      assert [hit] = await_hits(col, user, vault, "zymurgy", 1)
      assert hit.qdrant_id == point_id(note)

      assert {:ok, [out]} =
               Crypto.decrypt_qdrant_candidates([hit], user, %{to_string(vault.id) => vault}, col)

      assert out.text == ""
    end

    test "the floor note outranks an unrelated full chunk", %{
      user: user,
      vault: vault,
      collection: col
    } do
      other = floor_note(user, vault, "Other.md", "# Other\n\nFermentation of cabbage.")
      {:ok, _} = Indexing.index_note(other, vault, user)

      note = floor_note(user, vault)
      {:ok, 1, 0, false} = Indexing.index_note_with_usage(note, vault, user, index_tier: "floor")

      assert [first, second | _] = await_hits(col, user, vault, "zymurgy fermentation", 2)
      assert first.qdrant_id == point_id(note)
      assert second.score < first.score
    end
  end
end
