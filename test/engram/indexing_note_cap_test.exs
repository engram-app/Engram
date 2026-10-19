defmodule Engram.IndexingNoteCapTest do
  # async: false: the limits_enforced toggle is global app env, and the
  # reconcile tests assert on the global Oban job table.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.KeywordIndex.QdrantSparse
  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.UsageMeters
  alias Engram.Workers.{EmbedNote, RebuildStaleNote, ReconcileEmbeddings}

  setup :verify_on_exit!

  # `n` one-line sections, one chunk each; `last` goes in the final section.
  defp sections(n, last \\ "") do
    "# Big\n\n" <>
      Enum.map_join(1..n, "\n\n", fn i -> "## S#{i}\n\nsection#{i} body text here." end) <>
      last
  end

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user, is_default: true)
    %{user: user, vault: vault}
  end

  defp insert_note(user, vault, content, path \\ "Big.md") do
    note = Engram.Fixtures.insert_note!(user, vault, %{path: path, content: content})
    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)
    note
  end

  defp rows_for(note) do
    {:ok, rows} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.all(from(c in Chunk, where: c.note_id == ^note.id, order_by: c.position))
      end)

    rows
  end

  defp reload(note) do
    {:ok, row} = Repo.with_tenant(note.user_id, fn -> Repo.get!(Note, note.id) end)
    row
  end

  # Each embed call reports its texts to the test process.
  defp stub_embedder do
    parent = self()

    Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      send(parent, {:embedded, texts})
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)
  end

  defp embedded_texts(acc \\ []) do
    receive do
      {:embedded, texts} -> embedded_texts(acc ++ texts)
    after
      0 -> acc
    end
  end

  defp embed(note), do: perform_job(EmbedNote, %{"note_id" => note.id, "user_id" => note.user_id})

  defp with_limits_enforced(value) do
    prev = Application.get_env(:engram, :limits_enforced)
    Application.put_env(:engram, :limits_enforced, value)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :limits_enforced),
        else: Application.put_env(:engram, :limits_enforced, prev)
    end)
  end

  defp lapse_cooldown(note) do
    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id),
          set: [embed_retry_after: DateTime.add(DateTime.utc_now(), -1, :second)]
        )
      end)
  end

  describe "cap_chunks/2" do
    setup do
      chunks = Markdown.parse(sections(500), "Big.md")
      assert length(chunks) == 500
      %{chunks: chunks}
    end

    test "500 chunks to 128 contiguous groups, nothing dropped", %{chunks: chunks} do
      capped = Indexing.cap_chunks(chunks, 128)

      assert length(capped) == 128
      assert Enum.map(capped, & &1.position) == Enum.to_list(0..127)
      assert hd(capped).char_start == hd(chunks).char_start
      assert List.last(capped).char_end == List.last(chunks).char_end

      # Groups are joined with the same separator as members within a group,
      # so the whole note reads back identically, in order.
      assert Enum.map_join(capped, "\n\n", & &1.text) == Enum.map_join(chunks, "\n\n", & &1.text)

      assert Enum.sum(Enum.map(capped, & &1.token_count)) ==
               Enum.sum(Enum.map(chunks, &UsageMeters.estimate_tokens(&1.text)))

      # Contiguous and ordered: each group starts after the previous one.
      assert capped
             |> Enum.map(& &1.char_start)
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> a < b end)

      # Balanced: no group is far over the mean.
      mean = Enum.sum(Enum.map(capped, & &1.token_count)) / 128
      assert Enum.max(Enum.map(capped, & &1.token_count)) <= 2 * mean
    end

    test "a merged chunk's inputs are what a single chunk with its text gets", %{chunks: chunks} do
      [first_group | _] = Indexing.cap_chunks(chunks, 128)
      first = hd(chunks)
      prefix = fn full, text -> binary_part(full, 0, byte_size(full) - byte_size(text)) end

      assert first_group.heading_path == first.heading_path

      assert first_group.context_text ==
               prefix.(first.context_text, first.text) <> first_group.text

      assert first_group.embed_text == prefix.(first.embed_text, first.text) <> first_group.text
    end

    test "under the cap the list is returned unchanged" do
      chunks = Markdown.parse(sections(100), "Big.md")
      assert length(chunks) == 100
      assert Indexing.cap_chunks(chunks, 128) === chunks
      assert Indexing.cap_chunks(chunks, nil) === chunks
    end
  end

  describe "indexing a 500-chunk note" do
    test "Free indexes 128 points, metered on its first embed", %{user: user, vault: vault} do
      note = insert_note(user, vault, sections(500))
      stub_embedder()
      before = UsageMeters.lifetime_embed_tokens(user.id)

      assert :ok = embed(note)
      assert length(rows_for(note)) == 128
      texts = embedded_texts()
      assert length(texts) == 128

      assert UsageMeters.lifetime_embed_tokens(user.id) - before ==
               texts |> Enum.map(&byte_size/1) |> Enum.sum() |> UsageMeters.estimate_tokens()

      indexed = reload(note)
      assert indexed.dense_indexed_hash == indexed.content_hash
      assert indexed.index_tier == nil
    end

    test "Starter indexes all 500 (under 1,024)", %{user: user, vault: vault} do
      insert(:subscription, user: user, tier: "starter", status: "active")
      note = insert_note(user, vault, sections(500))
      stub_embedder()

      assert :ok = embed(note)
      assert length(rows_for(note)) == 500
    end

    test "billing disabled: never capped", %{user: user, vault: vault} do
      with_limits_enforced(false)
      note = insert_note(user, vault, sections(500))
      stub_embedder()

      assert {:ok, 500, _, true} = Indexing.index_note_with_usage(note, vault, user)
    end

    test "a term only in the last 1% reaches both the dense and the sparse leg", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(500, "\n\n## Tail\n\nquixotic finale."))
      stub_embedder()

      {:ok, prepared} = Indexing.prepare_index(note, vault, user)
      assert length(prepared.qdrant_points) == 128

      assert Enum.any?(embedded_texts(), &String.contains?(&1, "quixotic"))

      {:ok, key} = Crypto.dek_filter_key(user)
      dim = QdrantSparse.dim(key, "quixotic")

      assert Enum.any?(prepared.qdrant_points, fn point ->
               dim in QdrantSparse.unpack(point.vector["keyword"]).indices
             end)
    end

    test "an unchanged capped note reuses every point: zero embedder calls", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(500))
      stub_embedder()

      assert {:ok, 128, _, true} = Indexing.index_note_with_usage(note, vault, user)
      ids = Enum.map(rows_for(note), & &1.qdrant_point_id)
      assert length(embedded_texts()) == 128

      assert {:ok, 128, 0, true} = Indexing.index_note_with_usage(note, vault, user)
      assert embedded_texts() == []
      assert Enum.map(rows_for(note), & &1.qdrant_point_id) == ids
    end

    # One group holds the whole note (cap 1): ~150 KB of text estimates over
    # 30,000 tokens. No embedder stub: any Voyage call fails the test.
    test "a merged group over 30,000 estimated tokens floors the note", %{
      user: user,
      vault: vault
    } do
      insert(:user_limit_override, user: user, key: "note_points_cap", value: %{"v" => 1})
      filler = String.duplicate("lorem ipsum dolor ", 55)

      content =
        "# Big\n\n" <> Enum.map_join(1..150, "\n\n", fn i -> "## S#{i}\n\n#{filler}#{i}" end)

      note = insert_note(user, vault, content)
      before = UsageMeters.lifetime_embed_tokens(user.id)

      assert {:ok, 1, 0, false} = Indexing.index_note_with_usage(note, vault, user)
      assert [%{token_count: nil}] = rows_for(note)
      assert reload(note).index_tier == "floor"
      assert UsageMeters.lifetime_embed_tokens(user.id) == before
    end
  end

  describe "reconcile self-heal" do
    # Indexed uncapped (billing off), then the cap applies.
    defp index_uncapped(note) do
      with_limits_enforced(false)
      stub_embedder()
      assert :ok = embed(note)
      assert length(rows_for(note)) == 500
      _ = embedded_texts()
      Application.put_env(:engram, :limits_enforced, true)
    end

    test "a Free note of 500 live chunks is rebuilt to 128, unmetered", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(500))
      index_uncapped(note)

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})

      assert [job] =
               all_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})

      assert job.priority == EmbedNote.backfill_priority()

      before = UsageMeters.lifetime_embed_tokens(user.id)
      assert :ok = perform_job(RebuildStaleNote, job.args)
      assert length(rows_for(note)) == 128
      assert length(embedded_texts()) == 128
      assert UsageMeters.lifetime_embed_tokens(user.id) == before

      indexed = reload(note)
      assert indexed.dense_indexed_hash == indexed.content_hash

      # Healed: the next tick leaves it alone.
      lapse_cooldown(note)
      assert :ok = perform_job(ReconcileEmbeddings, %{})

      assert [_only_the_first] =
               all_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
    end

    test "a Starter note of 500 is not selected", %{user: user, vault: vault} do
      insert(:subscription, user: user, tier: "starter", status: "active")
      note = insert_note(user, vault, sections(500))
      index_uncapped(note)

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
      refute_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    end

    test "billing disabled: never selected", %{user: user, vault: vault} do
      note = insert_note(user, vault, sections(500))
      index_uncapped(note)
      Application.put_env(:engram, :limits_enforced, false)

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
    end
  end
end
