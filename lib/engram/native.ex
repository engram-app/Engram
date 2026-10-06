defmodule Engram.Native do
  @moduledoc """
  In-house Rust NIFs (native/engram_native). Each function is pure, runs on a
  dirty CPU scheduler, and takes and returns binaries.

  Memory standard (see `native/engram_native/src/memory.rs`):

    * Rust allocates through `enif_alloc`, so the BEAM's own accounting
      (`:erlang.memory(:system)`, recon_alloc) includes it.
    * Every NIF call reports its native PEAK bytes, emitted as
      `[:engram, :nif, :call, :stop]` by `call/4`, with `nif` and `dirty`
      (whether it ran on a dirty scheduler) as metadata.
    * `live_bytes/0` is this library's live Rust heap, for leak tests.
    * `memory_snapshot/0` sets OS RSS against what the BEAM can see. The gap
      (`unaccounted`) is native memory nothing else reports: a third-party
      NIF on its own allocator (y_ex, lingua) shows up only there.
  """
  use Rustler, otp_app: :engram, crate: "engram_native"

  @doc false
  def encode_documents_nif(_texts, _filter_key, _avgdl, _language),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Keyword query vector: `{indices, values}`, distinct dims, values 1.0."
  def encode_query_nif(_query, _filter_key, _language), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Language codes (strings) with a Snowball stemmer."
  def stem_languages, do: :erlang.nif_error(:nif_not_loaded)

  @doc "The keyword tokenizer: `{tokens, raw_len}`."
  def tokens_with_len(_text, _language), do: :erlang.nif_error(:nif_not_loaded)

  # The note parsers run on the calling scheduler up to this size (well
  # under 1 ms on real notes; 2.8 ms worst seen, on adversarial backtick
  # runs), and on a dirty CPU scheduler above it. Prod has ONE dirty
  # CPU scheduler, and a write must not queue behind a long keyword encode.
  @inline_max 16_384

  @doc false
  def link_extract_nif(_content), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def link_extract_dirty_nif(_content), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def note_title_nif(_content), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def note_title_dirty_nif(_content), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def note_tags_nif(_content), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def note_tags_dirty_nif(_content), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Links for `Engram.Links.Parser`: `{[{position, kind, target_start,
  target_len, target, alias, anchor}], scrub_count}`, in position order.
  `content` must be valid UTF-8.
  """
  def link_extract(content),
    do: parse(:link_extract, content, &link_extract_nif/1, &link_extract_dirty_nif/1)

  @doc false
  def chunk_nif(_content, _folder, _title), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def chunk_dirty_nif(_content, _folder, _title), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def frontmatter_split_nif(_content), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def frontmatter_split_dirty_nif(_content), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Chunks for `Engram.Parsers.Markdown.parse/2`: `[{text, context_text,
  heading_path, char_start, char_end}]`, before positions. Splits
  frontmatter itself. Valid UTF-8 only.
  """
  def chunk(content, folder, title),
    do:
      parse(
        :chunk,
        content,
        &chunk_nif(&1, folder, title),
        &chunk_dirty_nif(&1, folder, title)
      )

  @doc """
  Frontmatter fence offsets for `Engram.Notes.Frontmatter.split/1`:
  `{block_start, block_end, body_start, add_newline}` or nil. Any binary:
  the scan is over bytes.
  """
  def frontmatter_split(content),
    do:
      parse(
        :frontmatter_split,
        content,
        &frontmatter_split_nif/1,
        &frontmatter_split_dirty_nif/1
      )

  @doc false
  def frontmatter_parse_nif(_block), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def frontmatter_parse_dirty_nif(_block), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The common shape of a frontmatter YAML block, parsed natively:
  `[{key, json_value}]` in source order, or nil when the block uses any
  YAML the native rules do not cover (the caller then runs YamlElixir).
  Valid UTF-8 only.
  """
  def frontmatter_parse(block),
    do:
      parse(
        :frontmatter_parse,
        block,
        &frontmatter_parse_nif/1,
        &frontmatter_parse_dirty_nif/1
      )

  @doc false
  def frontmatter_emit_nif(_pairs), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def frontmatter_emit_dirty_nif(_pairs), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Ymlr's render of each `{key, json_value}` as a one-key YAML document
  (no `---`), or nil where the native rules decline and Elixir must render
  it, including for invalid UTF-8.
  """
  def frontmatter_emit(pairs) when is_list(pairs) do
    bytes = Enum.reduce(pairs, 0, fn {k, v}, acc -> acc + byte_size(k) + byte_size(v) end)

    if bytes <= @inline_max,
      do: call(:frontmatter_emit, bytes, %{dirty: false}, fn -> frontmatter_emit_nif(pairs) end),
      else:
        call(:frontmatter_emit, bytes, %{dirty: true}, fn ->
          frontmatter_emit_dirty_nif(pairs)
        end)
  end

  @doc "Frontmatter `title:`, else the first H1 outside code, else nil. Valid UTF-8 only."
  def note_title(content),
    do: parse(:note_title, content, &note_title_nif/1, &note_title_dirty_nif/1)

  @doc "Frontmatter tags then inline `#tags`, deduplicated. Valid UTF-8 only."
  def note_tags(content), do: parse(:note_tags, content, &note_tags_nif/1, &note_tags_dirty_nif/1)

  defp parse(name, content, inline, _dirty) when byte_size(content) <= @inline_max,
    do: call(name, content, %{dirty: false}, fn -> inline.(content) end)

  defp parse(name, content, _inline, dirty),
    do: call(name, content, %{dirty: true}, fn -> dirty.(content) end)

  @doc false
  def mmr_select_nif(_vectors, _scores, _limit, _diversity),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def pack_f32_nif(_values), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def dense_json_nif(_packed), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def sparse_json_nif(_indices, _values), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def hmac_hex_many_nif(_key, _prefix, _texts), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def hmac_hex_many_dirty_nif(_key, _prefix, _texts), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def json_decode_nif(_text), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def json_decode_dirty_nif(_text), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Live bytes held by this library's Rust heap, process-wide."
  def live_bytes, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Batch keyword encode: `[{indices_u32le, values_f64le, doc_len}]`, indices
  ascending. Emits `[:engram, :nif, :call, :stop]`.
  """
  def encode_documents(texts, filter_key, avgdl, language) do
    call(:keyword_encode, texts, %{dirty: true}, fn ->
      encode_documents_nif(texts, filter_key, avgdl, language)
    end)
  end

  @doc """
  MMR picks over a candidate pool: indices into it, in pick order. `vectors`
  holds a float list or `nil` per candidate. Emits `[:engram, :nif, :call, :stop]`.
  """
  def mmr_select(vectors, scores, limit, diversity) do
    # input_bytes: the f64s the NIF holds, from one vector's width. Summing
    # every list's length would walk the whole pool in Elixir, the cost this
    # NIF exists to remove.
    width = Enum.find_value(vectors, 0, &(is_list(&1) && length(&1)))

    call(:mmr_select, length(scores) * (width + 1) * 8, %{dirty: true}, fn ->
      mmr_select_nif(vectors, scores, limit, diversity / 1)
    end)
  end

  @doc """
  A float (or integer) list as packed float32 LE. Raises `ArgumentError` on
  a value outside f32 range. Emits `[:engram, :nif, :call, :stop]`.
  """
  def pack_f32(values) when is_list(values),
    do: call(:pack_f32, length(values) * 8, %{dirty: false}, fn -> pack_f32_nif(values) end)

  @doc """
  Packed float32 LE as JSON array text, each value its shortest f32 decimal.
  Raises `ArgumentError` on a ragged binary or a NaN/infinity.
  """
  def dense_json(packed) when is_binary(packed),
    do: call(:dense_json, packed, %{dirty: false}, fn -> dense_json_nif(packed) end)

  @doc """
  Packed sparse (u32 LE indices, f64 LE values) as `{"indices":[..],"values":[..]}`
  text. Raises `ArgumentError` on ragged or mismatched binaries.
  """
  def sparse_json(indices, values) when is_binary(indices) and is_binary(values) do
    call(:sparse_json, [indices, values], %{dirty: false}, fn ->
      sparse_json_nif(indices, values)
    end)
  end

  @doc """
  Lowercase hex HMAC-SHA256 of `prefix <> text` for each text: the batch form
  of `Engram.Crypto.hmac_content_hash/2`. Up to 16 KB of input runs on the
  calling scheduler; more goes dirty, so a small note never queues behind a
  keyword encode on prod's single dirty scheduler.
  """
  def hmac_hex_many(key, prefix, texts)
      when byte_size(key) == 32 and is_binary(prefix) and is_list(texts) do
    bytes = :erlang.iolist_size(texts) + length(texts) * byte_size(prefix)

    if bytes <= @inline_max do
      call(:hmac_hex_many, bytes, %{dirty: false}, fn -> hmac_hex_many_nif(key, prefix, texts) end)
    else
      call(:hmac_hex_many, bytes, %{dirty: true}, fn ->
        hmac_hex_many_dirty_nif(key, prefix, texts)
      end)
    end
  end

  @doc """
  `Jason.decode/1`'s result, in Rust: string keys, the first of a repeated
  key wins, integers stay integers, floats correctly rounded. Differs only
  where Qdrant never goes: integers past 64 bits and `-0` decode as floats. Malformed text
  (or nesting past 128 levels) is `{:error, :invalid_json}`. Up to 16 KB runs
  on the calling scheduler.
  """
  def json_decode(text) when is_binary(text) do
    term =
      if byte_size(text) <= @inline_max,
        do: call(:json_decode, text, %{dirty: false}, fn -> json_decode_nif(text) end),
        else: call(:json_decode, text, %{dirty: true}, fn -> json_decode_dirty_nif(text) end)

    {:ok, term}
  rescue
    ArgumentError -> {:error, :invalid_json}
  end

  # Every NIF entry point goes through here: one event shape for all of them,
  # so a dashboard or alert written for one covers the next.
  # `input` is the binary/iolist the NIF reads, or its byte count when it
  # reads terms (a float list has no iolist size).
  defp call(name, input, meta, fun) do
    t0 = System.monotonic_time()
    {result, peak} = fun.()

    :telemetry.execute(
      [:engram, :nif, :call, :stop],
      %{
        duration: System.monotonic_time() - t0,
        native_peak_bytes: peak,
        input_bytes: if(is_integer(input), do: input, else: :erlang.iolist_size(input))
      },
      Map.put(meta, :nif, name)
    )

    result
  end

  @doc """
  `%{rss, erlang_total, erlang_system, nif_live, unaccounted}` in bytes.
  `unaccounted = rss - erlang_total`: memory held outside every allocator
  the BEAM knows about.
  """
  def memory_snapshot do
    total = :erlang.memory(:total)
    rss = rss_bytes()

    %{
      rss: rss,
      erlang_total: total,
      erlang_system: :erlang.memory(:system),
      nif_live: live_bytes(),
      unaccounted: rss && rss - total
    }
  end

  defp rss_bytes do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_, kb] <- Regex.run(~r/VmRSS:\s+(\d+) kB/, status),
         do: String.to_integer(kb) * 1024,
         else: (_ -> nil)
  end
end
