defmodule Engram.IndexingHugeNotesTest do
  @moduledoc """
  Huge-note stress matrix: every shape at every size, Free (128 points a
  note) and paid (1,024), through the real index pipeline against Postgres,
  a recording Qdrant (Bypass) and a validating fake Voyage.

  Documents are generated from a seed per case, never committed. Every
  ~1 KB of text carries a unique letters-only sentinel word, so "every word
  is findable" is checked exactly on the sentinels, end to end.

  1 and 3 MB run everywhere. 10 and 30 MB are `@tag :huge` (excluded by
  default; CI runs them in their own job with `--only huge`).
  """
  # async: false: limits_enforced is global app env, and the memory peak is
  # read node-wide.
  use Engram.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.KeywordIndex.QdrantSparse
  alias Engram.Notes.Chunk
  alias Engram.Notes.Helpers
  alias Engram.Search
  alias Engram.ServiceConfig

  setup :verify_on_exit!

  @mib 1024 * 1024

  # Voyage: 1,000 inputs and 120,000 tokens a request, 32,000 tokens an
  # input. A token is never shorter than a byte, so bytes bound tokens for
  # any tokenizer: checking bytes proves the token limits.
  @voyage_inputs 1_000
  @voyage_request_tokens 120_000
  @voyage_input_tokens 32_000

  # Qdrant's default `service.max_request_size_mb` (Qdrant Cloud keeps it) is
  # 32 MiB. A request's size must not grow with the note, so the bound is a
  # quarter of that, whatever the size: it holds at 3 MB only if it holds at
  # 30 MB.
  @qdrant_max_request 8 * @mib

  # Worker task: 2,048 MiB, container 1,844 MiB, `embed` queue concurrency
  # 5 (engram-infra main/envs/prod/ecs.tf). With ~600 MB of node baseline,
  # five concurrent embeds get ~250 MB each. A pass may hold at most that:
  # the job process's heap plus the binaries it references, sampled. The
  # node-wide peak is logged too, but it also carries this test's Bypass
  # server and every other process, so it is not what is asserted.
  @per_job_memory 250 * @mib

  # Wall-clock bound. EmbedNote's Oban timeout is 10 minutes and the whole
  # attempt (Voyage round trips included, ~0.3-1 s per batch in prod) must
  # fit it. Local work here excludes the network, so it may use a tenth:
  # 6 s per MB leaves the rest of the 10 minutes for Voyage at 30 MB.
  @seconds_per_mb 6

  @shapes ~w(paragraph tiny_sections small_sections table code_fence mixed_blobs
             cjk_emoji long_lines nested_lists wikilinks frontmatter duplicates canvas
             log_ids)a

  defp tier_setup(:free, user) do
    put_limits_enforced(true)
    user
  end

  # Self-host: billing off, so no per-note cap at all (one point a chunk).
  defp tier_setup(:selfhost, user) do
    put_limits_enforced(false)
    user
  end

  # Floored by the index points budget (a full Free account): one
  # sparse-only point for the whole note, at any size.
  defp tier_setup(:floor, user), do: tier_setup(:free, user)

  defp tier_setup(:paid, user) do
    put_limits_enforced(true)
    insert(:subscription, user: user, tier: "starter", status: "active")
    user
  end

  defp put_limits_enforced(value) do
    prev = Application.get_env(:engram, :limits_enforced)
    Application.put_env(:engram, :limits_enforced, value)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :limits_enforced),
        else: Application.put_env(:engram, :limits_enforced, prev)
    end)
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "huge-notes-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Bypass.stub(bypass, :any, :any, &record_qdrant(&1, dir))

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user, is_default: true)
    %{user: user, vault: vault, dir: dir}
  end

  @tiers [:free, :paid, :floor, :selfhost]

  # Every shape once at 1 MB on the paid path, in the default suite (~30 s).
  for shape <- @shapes do
    @tag size: 1, shape: shape, headings: false, tier: :paid
    test("1 MB #{shape} headings=false paid", ctx, do: run_case(ctx))
  end

  # The full matrix is `:huge` (its own CI job, HUGE_TESTS=1). HUGE_MAX_MB
  # (default 30) drops the larger sizes for a local run on a shared box.
  @sizes Enum.filter(
           [1, 3, 10, 30],
           &(&1 <= String.to_integer(System.get_env("HUGE_MAX_MB", "30")))
         )

  for size <- @sizes,
      shape <- @shapes,
      headings <- [false, true],
      tier <- @tiers,
      {size, headings, tier} != {1, false, :paid} do
    @tag :huge
    @tag size: size, shape: shape, headings: headings, tier: tier
    # The ExUnit default (60 s) is the harness's, not the pipeline's: the
    # bound under test is `@seconds_per_mb` x size, asserted below.
    @tag timeout: (@seconds_per_mb * size + 60) * 1_000
    test("#{size} MB #{shape} headings=#{headings} #{tier}", ctx, do: run_case(ctx))
  end

  # Real Qdrant (the unit-tests CI job runs `:qdrant_integration`): a word in
  # the note's last section, searched for, comes back with a snippet that
  # shows it, merged (paid) and floored (CJK, several floor points).
  describe "deep-section search (real Qdrant)" do
    @describetag :qdrant_integration
    @describetag timeout: 120_000

    setup %{user: user} do
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
        {:ok, Enum.map(texts, fn _ -> <<0::size(dims * 32)>> end)}
      end)

      %{collection: col, user: tier_setup(:paid, user)}
    end

    test "3 MB merged: the last sentinel is found, its snippet shows it", ctx do
      {hit, word} = index_and_search(ctx, :paragraph, [])
      assert {:ok, [out]} = decrypt(ctx, hit)
      assert Search.snippet(out.text, word) =~ word
    end

    test "3 MB CJK floored: the last sentinel is found on its floor point", ctx do
      {hit, _word} = index_and_search(ctx, :cjk_emoji, index_tier: "floor")
      assert {:ok, [out]} = decrypt(ctx, hit)
      assert out.text == ""
    end
  end

  defp index_and_search(%{user: user, vault: vault, collection: col}, shape, opts) do
    {content, sentinels} = generate(shape, 3 * @mib, false, 3)
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "Deep.md", content: content})
    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)

    assert {:ok, _points, _bytes, _dense?} =
             Indexing.index_note_with_usage(note, vault, nil, opts)

    word = List.last(sentinels)
    {:ok, key} = Crypto.dek_filter_key(user)
    hits = await_hits(col, user, vault, QdrantSparse.encode_query(word, key), 50)
    ids = MapSet.new(rows_for(note), & &1.qdrant_point_id)
    assert [hit | _] = hits, "no hit for #{word}"
    assert MapSet.member?(ids, hit.qdrant_id)
    {hit, word}
  end

  defp await_hits(col, user, vault, sparse, tries) do
    {:ok, hits} =
      Engram.Vector.Qdrant.sparse_search(col, sparse,
        user_id: to_string(user.id),
        vault_id: to_string(vault.id),
        limit: 5
      )

    if hits != [] or tries == 0,
      do: hits,
      else: Process.sleep(100) && await_hits(col, user, vault, sparse, tries - 1)
  end

  defp decrypt(%{user: user, vault: vault, collection: col}, hit),
    do: Crypto.decrypt_qdrant_candidates([hit], user, %{to_string(vault.id) => vault}, col)

  # Links are extracted from the same content by ExtractNoteLinks, not the
  # index pass: 3 MB is ~120k wikilinks and embeds.
  @tag :huge
  @tag timeout: 120_000
  test "3 MB of wikilinks: extract and store the edges", %{user: user, vault: vault} do
    {content, _} = generate(:wikilinks, 3 * @mib, false, 1)
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "Links.md", content: "x"})

    {{micros, links}, _peak} =
      measure_peak(fn ->
        :timer.tc(fn ->
          links = Engram.Links.Parser.extract(content)
          :ok = Engram.Links.replace_links(user, vault, note.id, links)
          links
        end)
      end)

    IO.puts(
      "HUGE links #{length(links)} in #{div(micros, 1000)} ms, " <>
        "job #{Float.round(Process.get(:job_peak) / @mib, 1)} MB"
    )

    assert micros <= @seconds_per_mb * 3 * 1_000_000
    assert Process.get(:job_peak) <= @per_job_memory
  end

  defp run_case(%{user: user, vault: vault, dir: dir} = ctx) do
    %{size: size, shape: shape, headings: headings, tier: tier} = ctx
    user = tier_setup(tier, user)
    path = if shape == :canvas, do: "Huge/Board.canvas", else: "Huge/Note.md"
    {content, sentinels} = generate(shape, size * @mib, headings, seed(ctx))

    {_title, tags} = Helpers.extract_title_and_tags(content, path)

    note =
      Engram.Fixtures.insert_note!(user, vault, %{path: path, content: content, tags: tags})

    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)
    stub_voyage(dir)

    {{micros, result}, peak} =
      measure_peak(fn ->
        :timer.tc(fn -> Indexing.index_note_with_usage(note, vault, nil, index_opts(tier)) end)
      end)

    report = %{
      size_mb: size,
      shape: shape,
      headings: headings,
      tier: tier,
      ms: div(micros, 1000),
      peak_mb: Float.round(peak / @mib, 1),
      job_mb: Float.round(Process.get(:job_peak) / @mib, 1),
      tags: length(tags)
    }

    assert {:ok, points, _bytes, dense?} = result, "#{inspect(report)}: #{inspect(result)}"

    # Floor rows (forced here, or a Free note too big for its cap) have no
    # length and no reuse fingerprint.
    floored? = Enum.all?(rows_for(note), &(is_nil(&1.token_count) and is_nil(&1.context_hmac)))
    report = Map.merge(report, %{points: points, floored: floored?, dense: dense?})
    log(report, qdrant_sizes(dir), voyage_calls(dir))

    cap =
      %{
        free: 128,
        paid: 1_024,
        floor: Indexing.floor_points(byte_size(content)),
        # One point a chunk; a chunk holds at least half of MAX_CHUNK unless
        # its section is smaller, so this is loose but finite.
        selfhost: length(Engram.Parsers.Markdown.parse(content, path))
      }[tier]

    assert points <= cap, "#{inspect(report)}: #{points} points over the cap #{cap}"

    assert micros <= @seconds_per_mb * size * 1_000_000,
           "#{inspect(report)}: over #{@seconds_per_mb * size} s"

    assert Process.get(:job_peak) <= @per_job_memory, "#{inspect(report)}: job over 250 MB"

    for bytes <- qdrant_sizes(dir) do
      assert bytes <= @qdrant_max_request,
             "#{inspect(report)}: a #{bytes}-byte Qdrant request is over 8 MiB"
    end

    for {count, request_bytes, max_input} <- voyage_calls(dir) do
      assert count <= @voyage_inputs
      assert request_bytes <= @voyage_request_tokens, "#{inspect(report)}: Voyage batch"
      assert max_input <= @voyage_input_tokens, "#{inspect(report)}: Voyage input"
    end

    {:ok, filter_key} = Crypto.dek_filter_key(user)
    dims = keyword_dims(dir)
    lost = Enum.reject(sentinels, &MapSet.member?(dims, QdrantSparse.dim(filter_key, &1)))

    assert lost == [],
           "#{inspect(report)}: #{length(lost)}/#{length(sentinels)} sentinels not " <>
             "keyword-findable, first #{inspect(Enum.take(lost, 3))}"

    unless floored? do
      # Sentinels are letters only, so a split on anything else finds them
      # whole, and a word cut in two is (rightly) not found.
      embedded = dir |> embedded_texts() |> String.split(~r/[^a-z]+/) |> MapSet.new()
      dense_lost = Enum.reject(sentinels, &MapSet.member?(embedded, &1))

      assert dense_lost == [],
             "#{inspect(report)}: #{length(dense_lost)}/#{length(sentinels)} sentinels " <>
               "in no dense input, first #{inspect(Enum.take(dense_lost, 3))}"

      deep = List.last(sentinels)
      assert Search.snippet(input_holding(dir, deep), deep) =~ deep
    end
  end

  defp index_opts(:floor), do: [index_tier: "floor"]
  defp index_opts(_tier), do: []

  defp seed(%{size: s, shape: sh, headings: h}), do: :erlang.phash2({s, sh, h})

  defp rows_for(note) do
    {:ok, rows} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.all(from(c in Chunk, where: c.note_id == ^note.id, order_by: c.position))
      end)

    rows
  end

  # One line per case, so the CI log is the matrix.
  defp log(report, qdrant, voyage) do
    IO.puts(
      "HUGE " <>
        Jason.encode!(
          Map.merge(report, %{
            qdrant_requests: length(qdrant),
            qdrant_max_mb: Float.round(Enum.max(qdrant, fn -> 0 end) / @mib, 2),
            voyage_calls: length(voyage),
            voyage_inputs: voyage |> Enum.map(&elem(&1, 0)) |> Enum.sum(),
            voyage_max_input: voyage |> Enum.map(&elem(&1, 2)) |> Enum.max(fn -> 0 end)
          })
        )
    )
  end

  # ---------------------------------------------------------------------------
  # Peak memory: node-wide `:erlang.memory(:total)` (NIF allocations go
  # through enif_alloc, so they are in it), sampled every 2 ms, minus the
  # level before the call.
  # ---------------------------------------------------------------------------

  defp measure_peak(fun) do
    :erlang.garbage_collect()
    base = :erlang.memory(:total)
    parent = self()
    sampler = spawn_link(fn -> sample(parent, base, 0) end)
    result = fun.()
    send(sampler, :stop)

    receive do
      {:peak, peak, job} ->
        Process.put(:job_peak, job)
        {result, peak - base}
    end
  end

  # Node total every 2 ms; every 10th sample also the job process's own heap
  # plus the binaries it references (what prod's worker holds per job, with
  # no Bypass or test-side cost in it).
  defp sample(parent, peak, job, n \\ 0) do
    peak = max(peak, :erlang.memory(:total))
    job = if rem(n, 10) == 0, do: max(job, job_bytes(parent)), else: job

    receive do
      :stop -> send(parent, {:peak, peak, max(job, job_bytes(parent))})
    after
      2 -> sample(parent, peak, job, n + 1)
    end
  end

  defp job_bytes(pid) do
    case Process.info(pid, [:memory, :binary]) do
      [memory: m, binary: bins] -> m + Enum.sum(for {_id, size, _refc} <- bins, do: size)
      nil -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # Fake Voyage: validates each request against Voyage's limits and records
  # it to disk (so recording costs no memory inside the measured window).
  # ---------------------------------------------------------------------------

  defp stub_voyage(dir) do
    log = Path.join(dir, "voyage.log")
    texts = Path.join(dir, "voyage.txt")

    Mox.stub(Engram.MockEmbedder, :embed_texts, fn inputs ->
      sizes = Enum.map(inputs, &byte_size/1)
      File.write!(log, "#{length(inputs)} #{Enum.sum(sizes)} #{Enum.max(sizes)}\n", [:append])
      File.write!(texts, Enum.map(inputs, &[&1, "\n\u0000\n"]), [:append])

      if length(inputs) > @voyage_inputs or Enum.sum(sizes) > @voyage_request_tokens or
           Enum.max(sizes) > @voyage_input_tokens,
         do: {:error, {400, %{"detail" => "over a Voyage limit"}}},
         else: {:ok, Enum.map(inputs, fn _ -> <<0::size(1024 * 32)>> end)}
    end)
  end

  defp voyage_calls(dir) do
    case File.read(Path.join(dir, "voyage.log")) do
      {:ok, body} ->
        for line <- String.split(body, "\n", trim: true) do
          [c, b, m] = line |> String.split() |> Enum.map(&String.to_integer/1)
          {c, b, m}
        end

      {:error, :enoent} ->
        []
    end
  end

  defp embedded_texts(dir) do
    case File.read(Path.join(dir, "voyage.txt")) do
      {:ok, body} -> body
      {:error, :enoent} -> ""
    end
  end

  # The chunk text (prefix dropped) of the dense input holding `word`.
  defp input_holding(dir, word) do
    input =
      dir |> embedded_texts() |> String.split("\n\u0000\n") |> Enum.find(&(&1 =~ word))

    [_prefix, text] = String.split(input, "\n\n", parts: 2)
    text
  end

  # ---------------------------------------------------------------------------
  # Recording Qdrant: every request body streams to its own file; the size
  # list and the keyword dims of upserted points are read back after the
  # measured call.
  # ---------------------------------------------------------------------------

  defp record_qdrant(conn, dir) do
    file = Path.join(dir, "q-#{System.unique_integer([:positive, :monotonic])}.json")
    {conn, bytes} = stream_body(conn, File.open!(file, [:write, :raw]), 0)
    File.write!(Path.join(dir, "qdrant.log"), "#{conn.method} #{bytes} #{file}\n", [:append])

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, ~s({"result": true}))
  end

  defp stream_body(conn, io, bytes) do
    case Plug.Conn.read_body(conn, length: @mib, read_length: @mib) do
      {:ok, data, conn} ->
        :ok = IO.binwrite(io, data)
        File.close(io)
        {conn, bytes + byte_size(data)}

      {:more, data, conn} ->
        :ok = IO.binwrite(io, data)
        stream_body(conn, io, bytes + byte_size(data))
    end
  end

  defp qdrant_log(dir) do
    case File.read(Path.join(dir, "qdrant.log")) do
      {:ok, body} ->
        for line <- String.split(body, "\n", trim: true) do
          [method, bytes, file] = String.split(line)
          {method, String.to_integer(bytes), file}
        end

      {:error, :enoent} ->
        []
    end
  end

  defp qdrant_sizes(dir), do: for({_m, b, _f} <- qdrant_log(dir), do: b)

  defp keyword_dims(dir) do
    for {"PUT", _b, file} <- qdrant_log(dir),
        body = file |> File.read!() |> Jason.decode!(),
        point <- Map.get(body, "points", []),
        index <- get_in(point, ["vector", "keyword", "indices"]) || [],
        into: MapSet.new(),
        do: index
  end

  # ---------------------------------------------------------------------------
  # Generators. Each returns `{content, sentinels}`; content is built as
  # iodata and flattened once.
  # ---------------------------------------------------------------------------

  @doc false
  def generate(shape, bytes, headings, seed) do
    :rand.seed(:exsss, {seed, 7, 13})
    {body, sentinels} = body(shape, bytes, headings)
    {IO.iodata_to_binary(body), sentinels}
  end

  # Letters-only, unique: one token to every tokenizer, never a blob.
  defp sentinel(n), do: "zqx" <> letters(n) <> "qz"

  defp letters(n) when n < 26, do: <<?a + n>>
  defp letters(n), do: letters(div(n, 26) - 1) <> <<?a + rem(n, 26)>>

  @vocab List.to_tuple(for i <- 0..3_999, do: "w" <> Integer.to_string(i * 7919, 36))

  defp word, do: elem(@vocab, :rand.uniform(4_000) - 1)

  defp words(n), do: Enum.map_intersperse(1..n, " ", fn _ -> word() end)

  # Fills `bytes` with units from `unit.(i)` (iodata, ~1 KB each, holding
  # sentinel i), with a `## Section i` heading before every 8th unit when
  # `headings`.
  defp fill(bytes, headings, sep, unit) do
    Stream.iterate(0, &(&1 + 1))
    |> Enum.reduce_while({[], 0, []}, fn i, {acc, size, sents} ->
      if size >= bytes do
        {:halt, {acc, size, sents}}
      else
        piece = unit.(i)
        head = if headings and rem(i, 8) == 0, do: ["## Section ", letters(i), "\n\n"], else: []
        piece = [head, piece, sep]
        {:cont, {[acc | piece], size + IO.iodata_length(piece), [sentinel(i) | sents]}}
      end
    end)
    |> then(fn {acc, _size, sents} -> {acc, Enum.reverse(sents)} end)
  end

  defp prose(i), do: [words(70), " ", sentinel(i), " ", words(70), "."]

  defp body(:paragraph, bytes, h), do: fill(bytes, h, " ", &prose/1)

  defp body(:tiny_sections, bytes, h) do
    fill(bytes, h, "\n", fn i ->
      if h,
        do: ["### t", letters(i), "\n", sentinel(i), "\n"],
        else: [sentinel(i), "\n\n"]
    end)
  end

  # Many ~500-byte sections, each under its own heading: the chunk-count
  # and row-count end of the matrix (self-host has no cap on rows).
  defp body(:small_sections, bytes, _h) do
    fill(bytes, false, "\n\n", fn i ->
      ["## s", letters(i), "\n\n", words(70), " ", sentinel(i)]
    end)
  end

  defp body(:table, bytes, h) do
    {rows, s} =
      fill(bytes, h, "\n", fn i ->
        [
          "| ",
          word(),
          " | ",
          sentinel(i),
          " | ",
          Enum.map_intersperse(1..20, " | ", fn _ -> word() end),
          " |"
        ]
      end)

    {["| a | b | c |\n|---|---|---|\n", rows], s}
  end

  # Without headings: one fence around the whole note. With: one fence per
  # line, so the headings between them are real headings.
  defp body(:code_fence, bytes, false) do
    {lines, s} = fill(bytes, false, "\n", &code_line/1)
    {["```rust\n", lines, "```\n"], s}
  end

  defp body(:code_fence, bytes, true),
    do: fill(bytes, true, "\n", &["```rust\n", code_line(&1), "\n```\n"])

  defp body(:mixed_blobs, bytes, h) do
    fill(bytes, h, "\n\n", fn i ->
      case rem(i, 3) do
        0 -> prose(i)
        1 -> [prose(i), "\n\n", wrapped_base64(3_000)]
        2 -> [prose(i), "\n\n", hex_run(2_000)]
      end
    end)
  end

  defp body(:cjk_emoji, bytes, h) do
    fill(bytes, h, "\n\n", fn i ->
      [cjk(250), " ", sentinel(i), " ", emoji(40)]
    end)
  end

  # One line of 1 MB at a time: comma-joined words, no space, no newline
  # inside a line.
  defp body(:long_lines, bytes, h) do
    fill(bytes, h, "", fn i ->
      sep = if rem(i, 1_000) == 999, do: "\n", else: ","
      [Enum.map_intersperse(1..120, ",", fn _ -> word() end), ",", sentinel(i), sep]
    end)
  end

  defp body(:nested_lists, bytes, h) do
    fill(bytes, h, "\n", fn i ->
      depth = rem(i, 40)
      [String.duplicate("  ", depth), "- ", words(60), " ", sentinel(i), " ", words(60)]
    end)
  end

  defp body(:wikilinks, bytes, h) do
    fill(bytes, h, "\n", fn i ->
      links = for j <- 1..40, do: ["[[Note ", Integer.to_string(i * 40 + j), "]] "]
      [links, "![[img", Integer.to_string(i), ".png]] ", sentinel(i)]
    end)
  end

  # 10,000 aliases and 10,000 tags, then prose.
  defp body(:frontmatter, bytes, h) do
    fm = [
      "---\naliases:\n",
      for(i <- 1..10_000, do: ["  - alias ", Integer.to_string(i), "\n"]),
      "tags:\n",
      for(i <- 1..10_000, do: ["  - tag", Integer.to_string(i), "\n"]),
      "---\n"
    ]

    {rest, s} = fill(bytes - IO.iodata_length(fm), h, "\n\n", &prose/1)
    {[fm, rest], s}
  end

  # The same ~8 KB section over and over, one sentinel per repeat.
  defp body(:duplicates, bytes, h) do
    :rand.seed(:exsss, {1, 2, 3})
    block = words(1_100)
    fill(bytes, h, "\n\n", fn i -> [block, " ", sentinel(i)] end)
  end

  defp body(:canvas, bytes, _h) do
    {nodes, s} =
      fill(bytes, false, ",", fn i ->
        [
          ~s({"id":"n),
          Integer.to_string(i),
          ~s(","type":"text","x":0,"y":0,"width":250,"height":60,"text":"),
          words(60),
          " ",
          sentinel(i),
          ~s("})
        ]
      end)

    {[~s({"nodes":[), nodes, ~s({"id":"end","type":"text","text":"end"}],"edges":[]})], s}
  end

  # A service log: every line carries a fresh UUID and hex id, so nearly
  # every token is unique (the vocabulary grows with the note).
  defp body(:log_ids, bytes, h) do
    fill(bytes, h, "\n", fn i ->
      for _ <- 1..12 do
        [
          "2026-10-19T12:00:00Z req=",
          Ecto.UUID.generate(),
          " user=",
          hex_run(16),
          " ok\n"
        ]
      end
      |> then(&[&1, "event ", sentinel(i)])
    end)
  end

  defp code_line(i),
    do: ["fn ", sentinel(i), "(x: u64) -> u64 { let y = x * 3; ", words(30), " }"]

  defp wrapped_base64(n) do
    :crypto.strong_rand_bytes(n)
    |> Base.encode64()
    |> String.codepoints()
    |> Enum.chunk_every(76)
    |> Enum.map_intersperse("\n", &Enum.join/1)
  end

  defp hex_run(n), do: Base.encode16(:crypto.strong_rand_bytes(div(n, 2)), case: :lower)

  defp cjk(n), do: for(_ <- 1..n, into: "", do: <<0x4E00 + :rand.uniform(5_000)::utf8>>)
  defp emoji(n), do: for(_ <- 1..n, into: "", do: <<0x1F600 + :rand.uniform(70)::utf8>>)
end
