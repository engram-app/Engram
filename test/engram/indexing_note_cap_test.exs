defmodule Engram.IndexingNoteCapTest do
  # async: false: the limits_enforced toggle is global app env, and the
  # reconcile tests assert on the global Oban job table.
  use Engram.DataCase, async: false

  use Oban.Testing, repo: Engram.Repo

  import Engram.IndexBudgetHelpers
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

  # The v5 index budget is off by default (review H2); these tests are about it.
  setup :enable_index_budget

  setup :verify_on_exit!

  # Over 512 B, so the chunker's min512 merge leaves a section alone.
  @pad String.duplicate("lorem ipsum dolor ", 30)

  # `n` sections, one chunk each; `last` goes in the final section.
  defp sections(n, last \\ "") do
    "# Big\n\n" <>
      Enum.map_join(1..n, "\n\n", fn i -> "## S#{i}\n\nsection#{i} body text here. #{@pad}" end) <>
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

  # Merged rows (several chunks, `member_hmacs` set) keep NULL lengths;
  # groups of one are ordinary chunks with theirs.
  defp assert_merged_lengths_null(rows) do
    {merged, singles} = Enum.split_with(rows, &(&1.member_hmacs != nil))
    assert merged != []
    assert Enum.all?(merged, &is_nil(&1.token_count))
    assert Enum.all?(singles, &(&1.token_count != nil))
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

  # The per-note cap sweep runs in the daily re-verify hour only.
  defp reverify_tick, do: DateTime.new!(Date.utc_today(), ~T[04:02:00])

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

    test "500 chunks to at most 128 contiguous groups, nothing dropped", %{chunks: chunks} do
      capped = Indexing.cap_chunks(chunks, 128)

      assert length(capped) <= 128
      assert Enum.map(capped, & &1.position) == Enum.to_list(0..(length(capped) - 1))
      # A group of one is its chunk unchanged; every other group is merged.
      assert Enum.all?(capped, &(Map.get(&1, :merged, false) == Map.has_key?(&1, :members)))
      assert Enum.all?(capped, &(not Map.has_key?(&1, :members) or length(&1.members) > 1))
      assert hd(capped).char_start == hd(chunks).char_start
      assert List.last(capped).char_end == List.last(chunks).char_end

      # Groups are joined with the same separator as members within a group,
      # so the whole note reads back identically, in order.
      assert Enum.map_join(capped, "\n\n", & &1.text) == Enum.map_join(chunks, "\n\n", & &1.text)

      assert Enum.sum(
               Enum.map(
                 capped,
                 &(Map.get(&1, :token_count) || UsageMeters.estimate_tokens(&1.text))
               )
             ) ==
               Enum.sum(Enum.map(chunks, &UsageMeters.estimate_tokens(&1.text)))

      # Contiguous and ordered: each group starts after the previous one.
      assert capped
             |> Enum.map(& &1.char_start)
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> a < b end)
    end

    # Headroom: the first `g` (a power of two >= 1.25 n / cap) aims at 0.4 to
    # 0.8 x cap groups, so the doubling fallback (which regroups the whole
    # note) is rare. Ten fixed texts: deterministic. 500 chunks: g = 8, ~62
    # groups.
    test "the first g fits without doubling" do
      counts =
        for i <- 1..10 do
          sections(500)
          |> String.replace("body text here", "body text #{i}")
          |> Markdown.parse("Big.md")
          |> Indexing.cap_chunks(128)
          |> length()
        end

      # Doubled to g = 16 would land near 31.
      assert Enum.all?(counts, &(&1 in 45..128)), inspect(counts, charlists: :as_lists)
    end

    test "the same chunks give the same groups", %{chunks: chunks} do
      assert Indexing.cap_chunks(chunks, 128) == Indexing.cap_chunks(chunks, 128)
    end

    # ~200 KB of ~1 KB sections, cap 3: no 3 groups fit under the ceiling, so
    # it closes groups early and the result stays over the cap.
    test "a group closes before passing 7,500 estimated tokens" do
      filler = String.duplicate("lorem ipsum dolor ", 55)
      content = "# Big\n\n" <> Enum.map_join(1..200, "\n\n", &"## S#{&1}\n\n#{filler}#{&1}")
      capped = Indexing.cap_chunks(Markdown.parse(content, "Big.md"), 3)

      assert length(capped) > 3

      assert Enum.all?(
               capped,
               &(UsageMeters.estimate_tokens(IO.iodata_length(&1.embed_text)) <= 7_500)
             )
    end

    test "a merged chunk's inputs are what a single chunk with its text gets", %{
      chunks: chunks
    } do
      [first_group | _] = Indexing.cap_chunks(chunks, 128)
      first = hd(chunks)
      prefix = fn full, text -> binary_part(full, 0, byte_size(full) - byte_size(text)) end

      # Review L5: a merged point spans several sections, so its first
      # member's heading would label the hit wrongly: none until Task 13.1's
      # breadcrumbs.
      assert first_group.merged
      assert first_group.heading_path == nil
      assert first.heading_path != nil

      # iodata on a merged chunk (prefix, text), flattened by each consumer.
      assert IO.iodata_to_binary(first_group.context_text) ==
               prefix.(first.context_text, first.text) <> first_group.text

      assert IO.iodata_to_binary(first_group.embed_text) ==
               prefix.(first.embed_text, first.text) <> first_group.text
    end

    test "under the cap the list is returned unchanged" do
      chunks = Markdown.parse(sections(100), "Big.md")
      assert length(chunks) == 100
      assert Indexing.cap_chunks(chunks, 128) === chunks
      assert Indexing.cap_chunks(chunks, nil) === chunks
    end
  end

  # A numeric table: the chunker calls it "data" (keyword-only, #2041).
  defp table(i) do
    rows = for r <- 1..18, do: "| #{r} | #{4_810 + r * 37 + i} | #{r * 3} | #{rem(r, 4)}.#{i} |"
    Enum.join(["| id | value | count | rate |", "|---|---|---|---|" | rows], "\n")
  end

  # Runs of prose and data sections, `runs` of each kind, `per` sections a run.
  defp mixed(runs, per) do
    "---\ntags: [mixed]\n---\n# Mixed\n\n" <>
      Enum.map_join(1..(runs * 2), "\n\n", fn run ->
        Enum.map_join(1..per, "\n\n", fn j ->
          i = run * 1_000 + j

          if rem(run, 2) == 1,
            do: "## P#{i}\n\nprose#{i} sentence about the topic here. #{@pad}",
            else: "## T#{i}\n\n#{table(i)}"
        end)
      end)
  end

  # A prose section, then a table section, `n` times over: each its own
  # chunk (sections big enough not to coalesce), so 2n kind runs.
  defp interleaved(n) do
    para = String.duplicate("a longer sentence about the topic at hand. ", 16)

    "# Mixed\n\n" <>
      Enum.map_join(1..n, "\n\n", fn i ->
        "## P#{i}\n\nprose#{i} #{para}\n\n## T#{i}\n\n#{table(i)}"
      end)
  end

  # Chunker v5 Task 9.1: a merged group's DENSE input holds only its prose
  # members, its keyword input every member, so data, frontmatter and
  # drawings never become dense and prose never loses its vector. Kinds do
  # not split groups (review H1: a note with more kind runs than its cap
  # would floor). Frontmatter never joins a body group. Boundaries are
  # unkeyed, so a DEK rotation keeps the groups.
  describe "kind-aware groups" do
    setup do
      chunks = Markdown.parse(mixed(3, 50), "Mixed.md")
      kinds = chunks |> Enum.map(& &1.kind) |> Enum.frequencies()
      assert kinds["prose"] > 100 and kinds["data"] > 100 and kinds["frontmatter"] == 1
      %{chunks: chunks}
    end

    test "a merged group embeds only its prose members", %{chunks: chunks} do
      capped = Indexing.cap_chunks(chunks, 128)
      assert length(capped) <= 128
      assert Enum.any?(capped, &Map.get(&1, :merged, false))

      for %{merged: true} = group <- capped do
        kinds = group.members |> Enum.map(& &1.kind) |> MapSet.new()
        embed = IO.iodata_to_binary(group.embed_text)
        context = IO.iodata_to_binary(group.context_text)

        if MapSet.member?(kinds, "prose"), do: assert(group.kind == "prose")

        for m <- group.members do
          assert context =~ m.text

          # A group with no prose is keyword-only: its embed input is unused.
          if group.kind == "prose",
            do: assert(m.kind == "prose" == (embed =~ m.text))
        end
      end

      # Every chunk lands in exactly one group, in order.
      grouped = for g <- capped, m <- Map.get(g, :members, [g]), do: m.text
      assert grouped == Enum.map(chunks, & &1.text)
    end

    test "150 alternating prose and table sections stay dense on Free", %{
      user: user,
      vault: vault
    } do
      chunks = Markdown.parse(interleaved(150), "Mixed.md")
      runs = chunks |> Enum.chunk_by(& &1.kind) |> length()
      assert runs > 128

      note = insert_note(user, vault, interleaved(150), "Mixed.md")
      stub_embedder()

      assert {:ok, count, _, true} = Indexing.index_note_with_usage(note, vault, user)
      assert count <= 128
      assert reload(note).index_tier == nil
      embedded = Enum.join(embedded_texts(), "\n")

      for i <- 1..150, do: assert(embedded =~ "prose#{i} ", "prose #{i} has no dense vector")
      refute embedded =~ "| 4"
    end

    test "frontmatter is never grouped with body chunks", %{chunks: chunks} do
      [fm] =
        for g <- Indexing.cap_chunks(chunks, 128),
            Enum.any?(Map.get(g, :members, [g]), &(&1.kind == "frontmatter")),
            do: g

      assert fm.kind == "frontmatter"
      assert Enum.all?(Map.get(fm, :members, [fm]), &(&1.kind == "frontmatter"))
    end

    test "a data group is never embedded; every prose chunk is", %{user: user, vault: vault} do
      note = insert_note(user, vault, mixed(3, 50), "Mixed.md")
      stub_embedder()

      assert {:ok, count, _, true} = Indexing.index_note_with_usage(note, vault, user)
      assert count <= 128
      embedded = Enum.join(embedded_texts(), "\n")

      for i <- 1..50 do
        assert embedded =~ "prose#{1_000 + i} ", "prose chunk #{i} has no dense vector"
      end

      refute embedded =~ "| 4"
      refute embedded =~ "tags:"
    end

    test "group boundaries do not change when the DEK rotates", %{user: user, vault: vault} do
      # Two users: the same content under two content keys.
      {:ok, other} = Crypto.ensure_user_dek(insert(:user))
      other_vault = insert(:vault, user: other, is_default: true)
      stub_embedder()

      bounds =
        for {u, v} <- [{user, vault}, {other, other_vault}] do
          note = insert_note(u, v, sections(500))
          assert {:ok, _, _, true} = Indexing.index_note_with_usage(note, v, u)
          Enum.map(rows_for(note), &{&1.position, &1.char_start, &1.char_end})
        end

      assert Crypto.dek_content_hash_key(user) != Crypto.dek_content_hash_key(other)
      assert [same, same] = bounds
      assert length(same) < 500
    end
  end

  # Chunker v5 Task 9.2: one pass sends Voyage at most `max_pass_embed_bytes`
  # (12 MiB in prod), so a huge note finishes inside EmbedNote's timeout.
  # Lowered here so a small note crosses it.
  describe "the per-pass embed budget" do
    setup do
      prev = Application.get_env(:engram, :max_pass_embed_bytes)
      Application.put_env(:engram, :max_pass_embed_bytes, 2_000)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:engram, :max_pass_embed_bytes),
          else: Application.put_env(:engram, :max_pass_embed_bytes, prev)
      end)
    end

    test "prose past it is keyword-only; the first prose stays dense, and reuses", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(100))
      stub_embedder()

      # Every section is on the keyword leg, the dense part is a prefix.
      {:ok, prepared} = Indexing.prepare_index(note, vault, user)
      {:ok, key} = Crypto.dek_filter_key(user)
      dim = QdrantSparse.dim(key, "section100")

      assert Enum.any?(
               prepared.qdrant_points,
               &(dim in QdrantSparse.unpack(&1.vector["keyword"]).indices)
             )

      texts = embedded_texts()
      assert texts != []
      assert texts |> Enum.map(&byte_size/1) |> Enum.sum() <= 2_000
      assert hd(texts) =~ "section1 body"
      refute Enum.any?(texts, &(&1 =~ "section100 body"))

      assert {:ok, 100, _, true} = Indexing.index_note_with_usage(note, vault, user)
      assert embedded_texts() == texts

      # Unchanged: every point reused, no embedder call.
      assert {:ok, 100, 0, true} = Indexing.index_note_with_usage(note, vault, user)
      assert embedded_texts() == []
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
      groups = &(&1 |> Markdown.parse("Big.md") |> Indexing.cap_chunks(128) |> length())

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
      assert_merged_lengths_null(rows_for(note))
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

    # Power-of-two `g`: boundary sets nest, so growth regroups the note only
    # when `g` steps (n doubling past 0.8 x cap x g), not every ~100 chunks.
    # Driven through `cap_chunks/3` (500 real index passes outlive the
    # sandbox): a pass embeds exactly the merged chunks whose inputs no
    # stored point has (reuse matches by fingerprint over those inputs, by
    # multiplicity), so that is the embedder-call count per step.
    test "growing 500 -> 1,000 chunks one at a time regroups at most once" do
      inputs = fn n ->
        sections(n)
        |> Markdown.parse("Big.md")
        |> Indexing.cap_chunks(128)
        |> Enum.map(&{&1.context_text, &1.embed_text})
      end

      {steps, _last} =
        Enum.map_reduce(501..1_000, inputs.(500), fn n, previous ->
          current = inputs.(n)
          {{length(current), length(current -- previous)}, current}
        end)

      assert Enum.all?(steps, fn {count, _calls} -> count <= 128 end)
      # An append changes the last group or adds one; a regroup re-embeds most.
      assert Enum.count(steps, fn {_count, calls} -> calls > 3 end) <= 1
    end

    test "appending one chunk to a capped note embeds at most 2 groups", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(600))
      stub_embedder()
      assert {:ok, _, _, true} = Indexing.index_note_with_usage(note, vault, user)
      _ = embedded_texts()

      assert {:ok, count, _, true} =
               Indexing.index_note_with_usage(%{note | content: sections(601)}, vault, user)

      assert count <= 128
      assert length(embedded_texts()) in 1..2
    end

    # Merged under Free, then the cap is raised (an override): a keyword
    # version bump still refreshes every merged point.
    test "resparse refreshes a merged note's points after its cap is raised", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(500))
      stub_embedder()
      assert {:ok, count, _, true} = Indexing.index_note_with_usage(note, vault, user)
      assert count < 500

      insert(:user_limit_override, user: user, key: "note_points_cap", value: %{"v" => 10_000})
      Engram.Billing.OverrideCache.evict(user.id)

      assert {:ok, ^count, 0} = Indexing.resparse_note(note, user)
      assert_merged_lengths_null(rows_for(note))
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

      # The plain note's lengths plus `extra` rows'.
      avgdl_with = fn extra ->
        {:ok, plain_rows} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(from(c in Chunk, where: c.note_id == ^plain.id, select: c.token_count))
          end)

        lengths = plain_rows ++ Enum.map(extra, & &1.token_count)
        Decimal.div(Enum.sum(lengths), length(lengths))
      end

      assert Decimal.equal?(Decimal.round(before, 9), Decimal.round(avgdl_with.([]), 9))

      note = insert_note(user, vault, sections(500))
      assert {:ok, _, _, true} = Indexing.index_note_with_usage(note, vault, user)

      # Merged rows stay out; a group of one is an ordinary chunk and counts.
      {merged, singles} = Enum.split_with(rows_for(note), &(&1.member_hmacs != nil))
      assert merged != []
      assert Enum.all?(merged, &is_nil(&1.token_count))
      assert Enum.all?(singles, &(&1.token_count != nil))
      assert Decimal.equal?(Decimal.round(avgdl.(), 9), Decimal.round(avgdl_with.(singles), 9))
    end

    # One section, ~2 MB: hash-only groups would pass the 7,500-token
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
      assert Enum.all?(embedded_texts(), &(UsageMeters.estimate_tokens(&1) <= 7_500))
    end

    # Over 128 x 30 KB: no 128 groups fit under the ceiling. No embedder
    # stub: any Voyage call fails the test.
    @tag timeout: :timer.minutes(5)
    test "a note needing more than 128 ceiling-sized groups floors", %{
      user: user,
      vault: vault
    } do
      body = Enum.map_join(1..30_000, "\n\n", &"Paragraph #{&1} #{String.duplicate("word ", 38)}")
      note = insert_note(user, vault, "# Huger\n\n" <> body, "Huger.md")
      assert byte_size(note.content) > 128 * 30_000

      # Keyword-only, one point per MiB of body (`Indexing.floor_plan/2`).
      points = Indexing.floor_points(byte_size(note.content))
      assert {:ok, n, 0, false} = Indexing.index_note_with_usage(note, vault, user)
      assert n > 1 and n <= points
      assert reload(note).index_tier == "floor"
    end

    # Cap 1, ~150 KB of text: one group would estimate far over 7,500
    # tokens, so the ceiling needs more groups than the cap allows. No
    # embedder stub: any Voyage call fails the test.
    test "a note needing more than its cap of 7,500-token groups floors", %{
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

  # Hysteresis (adversarial V2): merge only past the cap, un-merge only at
  # or below 0.75 x cap, so an edit that moves the chunk count back and
  # forth across the cap never regroups the whole note more than once.
  describe "oscillating across the cap" do
    @tag timeout: :timer.minutes(5)
    test "20 alternating edits across 128/129 chunks: at most 1 full re-embed", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(128))
      stub_embedder()
      assert {:ok, 128, _, true} = Indexing.index_note_with_usage(note, vault, user)
      _ = embedded_texts()

      calls =
        for i <- 1..20 do
          content = if rem(i, 2) == 1, do: sections(129), else: sections(128)

          {:ok, _count, _, true} =
            Indexing.index_note_with_usage(%{note | content: content}, vault, user)

          length(embedded_texts())
        end

      # A local change re-embeds the last group or two; a regroup most of them.
      assert Enum.count(calls, &(&1 > 3)) <= 1, inspect(calls)
    end

    test "a merged note stays merged at the cap, un-merges at 0.75 x cap", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(129))
      stub_embedder()
      assert {:ok, merged, _, true} = Indexing.index_note_with_usage(note, vault, user)
      assert merged < 129

      assert {:ok, still, _, true} =
               Indexing.index_note_with_usage(%{note | content: sections(97)}, vault, user)

      assert still < 97

      assert {:ok, 96, _, true} =
               Indexing.index_note_with_usage(%{note | content: sections(96)}, vault, user)
    end

    test "a never-merged note at the cap stays unmerged", %{user: user, vault: vault} do
      note = insert_note(user, vault, sections(100))
      stub_embedder()
      assert {:ok, 100, _, true} = Indexing.index_note_with_usage(note, vault, user)

      assert {:ok, 128, _, true} =
               Indexing.index_note_with_usage(%{note | content: sections(128)}, vault, user)
    end

    # A group of one is an ordinary chunk: same fingerprint, same point.
    test "crossing the cap reuses every single-member group's point", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(128))
      stub_embedder()
      assert {:ok, 128, _, true} = Indexing.index_note_with_usage(note, vault, user)
      old_ids = MapSet.new(rows_for(note), & &1.qdrant_point_id)
      _ = embedded_texts()

      assert {:ok, _, _, true} =
               Indexing.index_note_with_usage(%{note | content: sections(129)}, vault, user)

      rows = rows_for(note)
      singles = Enum.filter(rows, &is_nil(&1.member_hmacs))
      reused? = &MapSet.member?(old_ids, &1.qdrant_point_id)

      # Only the merged groups and the new 129th chunk embed.
      assert length(singles) > 1
      assert Enum.count(singles, reused?) >= length(singles) - 1
      assert length(embedded_texts()) == Enum.count(rows, &(not reused?.(&1)))
    end
  end

  # Adversarial V3: the merge is our storage decision, so an edit inside a
  # merged group meters the changed member chunks only. The rest of the
  # group is re-embedded too (a real Voyage call), as our maintenance.
  describe "metering an edit inside a merged group" do
    # The pass's reservation (the user's charge) and our maintenance spend,
    # reported to the test process.
    defp metered_opts do
      parent = self()
      handler = "maintenance-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:engram, :embed, :maintenance],
          fn _event, %{tokens: tokens}, _meta, _ -> send(parent, {:maintenance, tokens}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      [
        reserve_tokens: fn tokens ->
          send(parent, {:reserved, tokens})
          true
        end,
        release_tokens: fn tokens -> send(parent, {:released, tokens}) end
      ]
    end

    defp sum_messages(tag, acc \\ 0) do
      receive do
        {^tag, tokens} -> sum_messages(tag, acc + tokens)
      after
        0 -> acc
      end
    end

    test "a one-paragraph edit charges that paragraph's chunk, not the group", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(500))
      stub_embedder()
      opts = metered_opts()
      assert {:ok, _, _, true} = Indexing.index_note_with_usage(note, vault, user, opts)
      _ = embedded_texts()

      # A first embed: every member is new, all of it is the user's.
      assert sum_messages(:reserved) > 0
      assert sum_messages(:maintenance) == 0

      edited = String.replace(note.content, "section250 body", "section250 edited body")

      assert {:ok, _, _, true} =
               Indexing.index_note_with_usage(%{note | content: edited}, vault, user, opts)

      [changed] =
        edited |> Markdown.parse("Big.md") |> Enum.filter(&String.contains?(&1.text, "edited"))

      sent = embedded_texts() |> Enum.map(&byte_size/1) |> Enum.sum()
      charged = sum_messages(:reserved)

      assert charged == UsageMeters.estimate_tokens(byte_size(changed.embed_text))
      assert UsageMeters.estimate_tokens(sent) > charged
      # The rest of the re-embedded groups is ours.
      assert charged + sum_messages(:maintenance) == UsageMeters.estimate_tokens(sent)
    end

    test "a failed embed gives back the charge and the maintenance", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(500))
      stub_embedder()
      opts = metered_opts()
      assert {:ok, _, _, true} = Indexing.index_note_with_usage(note, vault, user, opts)
      _ = {sum_messages(:reserved), sum_messages(:maintenance)}

      Mox.stub(Engram.MockEmbedder, :embed_texts, fn _ -> {:error, :boom} end)
      edited = String.replace(note.content, "section250 body", "section250 edited body")

      assert {:error, _} =
               Indexing.index_note_with_usage(%{note | content: edited}, vault, user, opts)

      assert sum_messages(:reserved) == sum_messages(:released)
      assert sum_messages(:maintenance) == 0
    end
  end

  # Adversarial S2: a slow pass (a recap, a version rebuild) planned from
  # older content must not commit its rows over a newer edit's: the edit's
  # pass already stamped `embed_hash`, so nothing would ever re-select it.
  describe "a pass whose content was superseded" do
    test "refuses to commit and leaves the newer rows", %{user: user, vault: vault} do
      note = insert_note(user, vault, sections(10))
      stub_embedder()
      assert note.content_hash

      {:ok, prepared} = Indexing.prepare_index(note, %Engram.Vaults.Vault{}, user)

      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(n in Note, where: n.id == ^note.id),
            set: [content_hash: "newer-edit"]
          )
        end)

      assert {:error, :superseded} = Indexing.commit_index(prepared)
      assert rows_for(note) == []
    end

    # Review L1: checked before the purge too. A stale pass that purged by
    # path filter first wiped the newer edit's points, then rolled back.
    test "deletes nothing from Qdrant", %{user: user, vault: vault} do
      note = insert_note(user, vault, sections(10))
      stub_embedder()
      {:ok, prepared} = Indexing.prepare_index(note, %Engram.Vaults.Vault{}, user)

      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(n in Note, where: n.id == ^note.id),
            set: [content_hash: "newer-edit"]
          )
        end)

      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      parent = self()

      Bypass.stub(bypass, :any, :any, fn conn ->
        send(parent, {:qdrant, conn.method, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      _ = deletes()

      assert {:error, :superseded} = Indexing.commit_index(prepared)
      assert deletes() == 0
    end
  end

  # Review M4: a recap or promotion writes its new points before it deletes
  # the old ones, so a refused upsert (507, strict mode) leaves the note's
  # old index whole instead of empty.
  describe "a regroup writes before it deletes" do
    setup %{user: user, vault: vault} do
      with_limits_enforced(false)
      stub_embedder()
      note = insert_note(user, vault, sections(500))
      assert {:ok, 500, _, true} = Indexing.index_note_with_usage(note, vault, user)
      Application.put_env(:engram, :limits_enforced, true)
      %{note: note}
    end

    # Qdrant answers 507 to every upsert and reports each request.
    defp refuse_upserts(bypass) do
      parent = self()

      Bypass.stub(bypass, :any, :any, fn conn ->
        send(parent, {:qdrant, conn.method, conn.request_path})

        if conn.method == "PUT" and String.ends_with?(conn.request_path, "/points"),
          do: Plug.Conn.send_resp(conn, 507, ~s({"status": {"error": "full"}})),
          else:
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)
    end

    defp deletes(acc \\ 0) do
      receive do
        {:qdrant, "POST", path} ->
          deletes(if(String.ends_with?(path, "/points/delete"), do: acc + 1, else: acc))

        {:qdrant, _method, _path} ->
          deletes(acc)
      after
        0 -> acc
      end
    end

    test "a promotion refused by Qdrant keeps the floor point", %{user: user, vault: vault} do
      floored = insert_note(user, vault, sections(20), "Floored.md")

      assert {:ok, 1, 0, false} =
               Indexing.index_note_with_usage(floored, vault, user, index_tier: "floor")

      floored = %{floored | index_tier: "floor"}
      [%{qdrant_point_id: floor_id}] = rows_for(floored)

      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      refuse_upserts(bypass)
      _ = deletes()

      assert {:error, _} = Indexing.index_note_with_usage(floored, vault, user, index_tier: nil)
      assert deletes() == 0
      assert [%{qdrant_point_id: ^floor_id}] = rows_for(floored)
    end

    test "a recap refused by Qdrant deletes nothing", %{user: user, vault: vault, note: note} do
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      refuse_upserts(bypass)
      _ = deletes()

      assert {:error, _} = Indexing.index_note_with_usage(note, vault, user)
      assert deletes() == 0
      assert length(rows_for(note)) == 500
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

      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())
      refute_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})

      assert [job] =
               all_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})

      assert job.priority == EmbedNote.backfill_priority()

      before = UsageMeters.lifetime_embed_tokens(user.id)
      assert :ok = perform_job(RebuildStaleNote, job.args)
      rows = rows_for(note)
      assert length(rows) in 1..128
      # Groups of one reuse the unmerged points; only merged groups embed.
      assert length(embedded_texts()) == Enum.count(rows, &(&1.member_hmacs != nil))
      assert UsageMeters.lifetime_embed_tokens(user.id) == before

      indexed = reload(note)
      assert indexed.dense_indexed_hash == indexed.content_hash

      # Healed: the next tick leaves it alone.
      lapse_cooldown(note)
      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())

      assert [_only_the_first] =
               all_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
    end

    test "a Starter note of 500 is not selected", %{user: user, vault: vault} do
      insert(:subscription, user: user, tier: "starter", status: "active")
      note = insert_note(user, vault, sections(500))
      index_uncapped(note)

      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())
      refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
      refute_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    end

    # The sweep resolves each user's cap the way indexing does.
    test "a Free note under a raised override is not selected", %{user: user, vault: vault} do
      insert(:user_limit_override, user: user, key: "note_points_cap", value: %{"v" => 1_000})
      note = insert_note(user, vault, sections(500))
      index_uncapped(note)

      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())
      refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
    end

    test "a Starter note over a lowered override is selected", %{user: user, vault: vault} do
      insert(:subscription, user: user, tier: "starter", status: "active")
      insert(:user_limit_override, user: user, key: "note_points_cap", value: %{"v" => 100})
      note = insert_note(user, vault, sections(500))
      index_uncapped(note)

      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())
      assert_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id, "recap" => true})
    end

    # Outside the daily re-verify hour the probe does not run at all.
    test "a 5-minute tick outside the re-verify hour selects nothing", %{
      user: user,
      vault: vault
    } do
      note = insert_note(user, vault, sections(500))
      index_uncapped(note)

      tick = DateTime.new!(Date.utc_today(), ~T[03:57:00])
      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: tick)
      refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
    end

    test "billing disabled: never selected", %{user: user, vault: vault} do
      note = insert_note(user, vault, sections(500))
      index_uncapped(note)
      Application.put_env(:engram, :limits_enforced, false)

      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())
      refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
    end
  end
end
