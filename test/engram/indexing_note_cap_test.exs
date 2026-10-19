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

  describe "cap_chunks/3" do
    setup do
      chunks = Markdown.parse(sections(500), "Big.md")
      assert length(chunks) == 500
      %{chunks: chunks, key: :crypto.strong_rand_bytes(32)}
    end

    test "500 chunks to at most 128 contiguous groups, nothing dropped", %{
      chunks: chunks,
      key: key
    } do
      capped = Indexing.cap_chunks(chunks, 128, key)

      assert length(capped) <= 128
      assert Enum.map(capped, & &1.position) == Enum.to_list(0..(length(capped) - 1))
      assert Enum.all?(capped, & &1.merged)
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
    end

    # Headroom: the first `g` aims at ~0.8 x cap, so the doubling fallback
    # (which regroups the whole note) is rare. Fixed keys: deterministic.
    test "the first g fits without doubling", %{chunks: chunks} do
      counts =
        for i <- 1..10 do
          chunks |> Indexing.cap_chunks(128, :crypto.hash(:sha256, "key #{i}")) |> length()
        end

      # Doubled from g = 5 would land near 50.
      assert Enum.all?(counts, &(&1 in 80..128)), inspect(counts, charlists: :as_lists)
    end

    test "the same chunks and key give the same groups", %{chunks: chunks, key: key} do
      assert Indexing.cap_chunks(chunks, 128, key) == Indexing.cap_chunks(chunks, 128, key)
    end

    # ~200 KB of ~1 KB sections, cap 3: no 3 groups fit under the ceiling, so
    # it closes groups early and the result stays over the cap.
    test "a group closes before passing 10,000 estimated tokens", %{key: key} do
      filler = String.duplicate("lorem ipsum dolor ", 55)
      content = "# Big\n\n" <> Enum.map_join(1..200, "\n\n", &"## S#{&1}\n\n#{filler}#{&1}")
      capped = Indexing.cap_chunks(Markdown.parse(content, "Big.md"), 3, key)

      assert length(capped) > 3
      assert Enum.all?(capped, &(UsageMeters.estimate_tokens(&1.embed_text) <= 10_000))
    end

    test "a merged chunk's inputs are what a single chunk with its text gets", %{
      chunks: chunks,
      key: key
    } do
      [first_group | _] = Indexing.cap_chunks(chunks, 128, key)
      first = hd(chunks)
      prefix = fn full, text -> binary_part(full, 0, byte_size(full) - byte_size(text)) end

      assert first_group.heading_path == first.heading_path

      assert first_group.context_text ==
               prefix.(first.context_text, first.text) <> first_group.text

      assert first_group.embed_text == prefix.(first.embed_text, first.text) <> first_group.text
    end

    test "under the cap the list is returned unchanged", %{key: key} do
      chunks = Markdown.parse(sections(100), "Big.md")
      assert length(chunks) == 100
      assert Indexing.cap_chunks(chunks, 128, key) === chunks
      assert Indexing.cap_chunks(chunks, nil, key) === chunks
    end
  end

  describe "indexing a 500-chunk note" do
    test "Free indexes at most 128 points, metered on its first embed", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(500))
      stub_embedder()
      before = UsageMeters.lifetime_embed_tokens(user.id)

      assert :ok = embed(note)
      rows = rows_for(note)
      assert length(rows) in 1..128
      texts = embedded_texts()
      assert length(texts) == length(rows)

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
      assert length(prepared.qdrant_points) <= 128

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

      assert {:ok, count, _, true} = Indexing.index_note_with_usage(note, vault, user)
      assert count <= 128
      ids = Enum.map(rows_for(note), & &1.qdrant_point_id)
      assert length(embedded_texts()) == count

      assert {:ok, ^count, 0, true} = Indexing.index_note_with_usage(note, vault, user)
      assert embedded_texts() == []
      assert Enum.map(rows_for(note), & &1.qdrant_point_id) == ids
    end

    test "editing one middle chunk re-embeds at most 3 groups", %{user: user, vault: vault} do
      content = sections(500)
      note = insert_note(user, vault, content)
      stub_embedder()
      assert {:ok, _, _, true} = Indexing.index_note_with_usage(note, vault, user)
      _ = embedded_texts()

      # An edit that tips the group count over the cap doubles `g` and
      # regroups the whole note (a known cost, see the Task 7 report), so pick
      # a middle chunk whose edit keeps `g`: the count moves by at most one.
      {:ok, key} = Crypto.dek_content_hash_key(user)
      groups = &(&1 |> Markdown.parse("Big.md") |> Indexing.cap_chunks(128, key) |> length())

      edited =
        Enum.find_value(240..260, fn i ->
          e = String.replace(content, "section#{i} body", "section#{i} edited body")
          if abs(groups.(e) - groups.(content)) <= 1, do: e
        end)

      assert edited

      assert {:ok, count, _, true} =
               Indexing.index_note_with_usage(%{note | content: edited}, vault, user)

      assert count <= 128
      assert length(embedded_texts()) in 1..3
    end

    # A keyword-version resparse matches the merged chunks, not the raw ones,
    # and writes no lengths back.
    test "resparse rewrites every merged point, lengths stay NULL", %{user: user, vault: vault} do
      note = insert_note(user, vault, sections(500))
      stub_embedder()
      assert {:ok, count, _, true} = Indexing.index_note_with_usage(note, vault, user)

      assert {:ok, ^count, 0} = Indexing.resparse_note(note, user)
      assert Enum.all?(rows_for(note), &is_nil(&1.token_count))
    end

    # ~50 single-chunk edits, one after another: only crossing the cap (which
    # doubles `g`) regroups the whole note, and the headroom keeps that rare.
    @tag timeout: :timer.minutes(5)
    test "50 single-chunk edits: at most one re-embeds the whole note", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(500))
      stub_embedder()
      assert {:ok, first, _, true} = Indexing.index_note_with_usage(note, vault, user)
      assert first <= 128
      _ = embedded_texts()

      {results, _content} =
        Enum.map_reduce(Enum.to_list(10..490//10), note.content, fn i, content ->
          edited = String.replace(content, "section#{i} body", "section#{i} edited body")
          assert edited != content

          {:ok, count, _, true} =
            Indexing.index_note_with_usage(%{note | content: edited}, vault, user)

          {{count, length(embedded_texts())}, edited}
        end)

      assert length(results) == 49
      assert Enum.all?(results, fn {count, _calls} -> count <= 128 end)
      # A local edit re-embeds 1-3 groups; a whole-note regroup re-embeds most.
      assert Enum.count(results, fn {_count, calls} -> calls > 3 end) <= 1
    end

    test "a capped note leaves the vault's avgdl alone", %{user: user, vault: vault} do
      stub_embedder()
      plain = insert_note(user, vault, "# Plain\n\nA short ordinary note.", "Plain.md")
      assert {:ok, 1, _, true} = Indexing.index_note_with_usage(plain, vault, user)
      # The rows `Stats.avgdl/2` averages, read directly (it caches).
      avgdl = fn ->
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

      before = avgdl.()
      assert before

      note = insert_note(user, vault, sections(500))
      assert {:ok, _, _, true} = Indexing.index_note_with_usage(note, vault, user)

      assert Enum.all?(rows_for(note), &is_nil(&1.token_count))
      assert avgdl.() == before
    end

    # One section, ~2 MB: hash-only groups would pass the 10,000-token
    # ceiling and floor the note; closing groups at the ceiling merges it.
    @tag timeout: :timer.minutes(5)
    test "a 2 MB single-section note merges under the ceiling, no floor", %{
      user: user,
      vault: vault
    } do
      body = Enum.map_join(1..10_000, "\n\n", &"Paragraph #{&1} #{String.duplicate("word ", 38)}")
      note = insert_note(user, vault, "# Huge\n\n" <> body, "Huge.md")
      assert byte_size(note.content) > 2_000_000
      stub_embedder()

      assert {:ok, count, _, true} = Indexing.index_note_with_usage(note, vault, user)
      assert count <= 128
      assert reload(note).index_tier == nil
      assert Enum.all?(embedded_texts(), &(UsageMeters.estimate_tokens(&1) <= 10_000))
    end

    # Over 128 x 40 KB: no 128 groups fit under the ceiling. No embedder
    # stub: any Voyage call fails the test.
    @tag timeout: :timer.minutes(5)
    test "a note needing more than 128 ceiling-sized groups floors", %{
      user: user,
      vault: vault
    } do
      body = Enum.map_join(1..30_000, "\n\n", &"Paragraph #{&1} #{String.duplicate("word ", 38)}")
      note = insert_note(user, vault, "# Huger\n\n" <> body, "Huger.md")
      assert byte_size(note.content) > 128 * 40_000

      assert {:ok, 1, 0, false} = Indexing.index_note_with_usage(note, vault, user)
      assert reload(note).index_tier == "floor"
    end

    # Cap 1, ~150 KB of text: one group would estimate far over 10,000
    # tokens, so the ceiling needs more groups than the cap allows. No
    # embedder stub: any Voyage call fails the test.
    test "a note needing more than its cap of 10,000-token groups floors", %{
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

    test "a Free note of 500 live chunks is rebuilt to at most 128, unmetered", %{
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
      rows = rows_for(note)
      assert length(rows) in 1..128
      assert length(embedded_texts()) == length(rows)
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

    # The sweep resolves each user's cap the way indexing does.
    test "a Free note under a raised override is not selected", %{user: user, vault: vault} do
      insert(:user_limit_override, user: user, key: "note_points_cap", value: %{"v" => 1_000})
      note = insert_note(user, vault, sections(500))
      index_uncapped(note)

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
    end

    test "a Starter note over a lowered override is selected", %{user: user, vault: vault} do
      insert(:subscription, user: user, tier: "starter", status: "active")
      insert(:user_limit_override, user: user, key: "note_points_cap", value: %{"v" => 100})
      note = insert_note(user, vault, sections(500))
      index_uncapped(note)

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id, "recap" => true})
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
