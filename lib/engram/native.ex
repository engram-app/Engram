defmodule Engram.Native do
  @moduledoc """
  In-house Rust NIFs (native/engram_native, a Cargo workspace member). Each function is pure; which
  scheduler it runs on is set per NIF (see `@sized` and the Scheduling
  section of docs/context/native-nifs.md).

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
  # Rustler tracks the crate and its path dependencies (engram_core), not the
  # Cargo workspace root: without these a lockfile bump, a release-profile
  # change or a toolchain pin would not rebuild the NIF on `mix compile`.
  for file <- ~w(Cargo.toml Cargo.lock rust-toolchain.toml) do
    @external_resource Path.join("native", file)
  end

  use Rustler, otp_app: :engram, crate: "engram_native"

  # The built library itself, recorded after `use Rustler` wrote it. Every
  # MIX_ENV shares this one file (`_build/<env>/lib/engram/priv` links to
  # priv/), and prod builds it without the `test-hooks` NIFs. Without this,
  # a `MIX_ENV=prod mix compile` left dev/test loading the prod library
  # until something else recompiled this module; now the changed digest
  # recompiles it, and Rustler rebuilds the env's own library.
  @external_resource "priv/native/engram_native.so"

  @doc "Keyword query vector: `{indices, values}`, distinct dims, values 1.0."
  def encode_query_nif(_query, _filter_key, _language), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Language codes (strings) with a Snowball stemmer."
  def stem_languages, do: :erlang.nif_error(:nif_not_loaded)

  @doc "The keyword tokenizer: `{tokens, raw_len}`."
  def tokens_with_len(_text, _language), do: :erlang.nif_error(:nif_not_loaded)

  # These run on the calling scheduler up to this many input bytes (well
  # under 1 ms on real notes; 2.8 ms worst seen, on adversarial backtick
  # runs), and on a dirty CPU scheduler above it. Prod has ONE dirty
  # CPU scheduler, and a write must not queue behind a long keyword encode.
  @inline_max 16_384

  # Every NIF with an inline and a dirty variant: `{name, inline_nif,
  # dirty_nif, arity}`. Rust exports both; `sized/3` picks one by size.
  # Spelled out (not built from `name`) so a grep for either NIF lands here.
  @sized [
    {:link_extract, :link_extract_nif, :link_extract_dirty_nif, 2},
    {:note_title, :note_title_nif, :note_title_dirty_nif, 1},
    {:note_meta, :note_meta_nif, :note_meta_dirty_nif, 1},
    {:chunk, :chunk_nif, :chunk_dirty_nif, 3},
    {:frontmatter_split, :frontmatter_split_nif, :frontmatter_split_dirty_nif, 1},
    {:frontmatter_parse, :frontmatter_parse_nif, :frontmatter_parse_dirty_nif, 1},
    {:text_diff, :text_diff_nif, :text_diff_dirty_nif, 2},
    {:utf16_offsets, :utf16_offsets_nif, :utf16_offsets_dirty_nif, 2},
    {:hmac_hex_many, :hmac_hex_many_nif, :hmac_hex_many_dirty_nif, 3},
    {:json_decode, :json_decode_nif, :json_decode_dirty_nif, 1},
    {:envelope_seal, :envelope_seal_nif, :envelope_seal_dirty_nif, 4},
    {:envelope_open, :envelope_open_nif, :envelope_open_dirty_nif, 4},
    {:envelope_open_many, :envelope_open_many_nif, :envelope_open_many_dirty_nif, 3}
  ]

  # NIFs reached only through a wrapper below that fixes their schedule.
  @single [
    encode_documents_nif: 4,
    mmr_select_nif: 4,
    pack_f32_nif: 1,
    dense_json_nif: 1,
    sparse_json_nif: 2,
    md_outline_nif: 1,
    envelope_counts_nif: 0,
    name_index_build_nif: 4,
    name_index_search_nif: 3,
    name_index_put_nif: 4,
    name_index_delete_nif: 3
  ]

  # Test hooks, built only with the crate's `test-hooks` feature, which
  # config/dev.exs and config/test.exs enable (see there for why both): the
  # release NIF does not export them, and neither does this module. The
  # fixed-nonce seal exists for byte parity with :crypto; a repeated nonce
  # under one key breaks AES-GCM.
  @test_hooks (if "test-hooks" in Application.compile_env(:engram, [__MODULE__, :features], []) do
                 [envelope_seal_with_nonce_nif: 5]
               else
                 []
               end)

  # Stubs Rustler replaces on load.
  for {nif, arity} <-
        @single ++ @test_hooks ++ Enum.flat_map(@sized, fn {_, i, d, a} -> [{i, a}, {d, a}] end) do
    @doc false
    def unquote(nif)(unquote_splicing(List.duplicate(Macro.var(:_, nil), arity))),
      do: :erlang.nif_error(:nif_not_loaded)
  end

  for {name, inline_nif, dirty_nif, _arity} <- @sized,
      do: defp(nifs(unquote(name)), do: {unquote(inline_nif), unquote(dirty_nif)})

  @doc """
  Links for `Engram.Links.Parser`: `{[{position, kind, target_start,
  target_len, target, alias, anchor}], scrub_count, cut?}`, in position
  order, the first `limit` of them (`cut?`: more were dropped).
  `content` must be valid UTF-8.
  """
  def link_extract(content, limit), do: sized(:link_extract, content, [content, limit])

  @doc """
  Chunks for `Engram.Parsers.Markdown.parse/2`: `[{text, context_text,
  heading_path, char_start, char_end}]`, before positions. Splits
  frontmatter itself. Valid UTF-8 only.
  """
  def chunk(content, folder, title), do: sized(:chunk, content, [content, folder, title])

  @doc """
  Frontmatter fence offsets for `Engram.Notes.Frontmatter.split/1`:
  `{block_start, block_end, body_start, add_newline}` or nil. Any binary:
  the scan is over bytes.
  """
  def frontmatter_split(content), do: sized(:frontmatter_split, content, [content])

  @doc """
  The common shape of a frontmatter YAML block, parsed natively:
  `[{key, json_value}]` in source order, or nil when the block uses any
  YAML the native rules do not cover (the caller then runs YamlElixir).
  Valid UTF-8 only.
  """
  def frontmatter_parse(block), do: sized(:frontmatter_parse, block, [block])

  @doc "Frontmatter `title:`, else the first H1 outside code, else nil. Valid UTF-8 only."
  def note_title(content), do: sized(:note_title, content, [content])

  @doc """
  `{note_title(content), tags}` in one call, tags being frontmatter tags then
  inline `#tags`, deduplicated: the code ranges both need are parsed once.
  Valid UTF-8 only.
  """
  def note_meta(content), do: sized(:note_meta, content, [content])

  @doc """
  The single-span diff for `CrdtBridge.diff_into_text/2`: `{prefix_u16,
  delete_u16, insert_start, insert_len}`. The first two are UTF-16 units into
  `current`; the insert is a byte range of `incoming`, for `binary_part/3`.
  Valid UTF-8 only.
  """
  def text_diff(current, incoming),
    do: sized(:text_diff, [current, incoming], [current, incoming])

  @doc """
  What `Engram.MCP.Sections` reads from a CommonMark parse (comrak) of a
  note as stored (BOM and frontmatter handled here): `{[{line, level, text,
  raw, span}], explained_lines, safe_line_ranges}`, lines 0-indexed, text
  and raw trimmed. nil when the note has more than 100,000 of them
  (outline.rs MAX_ITEMS). Valid UTF-8 only. Always on a dirty scheduler:
  16 KB of dense markup takes ~10 ms in comrak.
  """
  def md_outline(text) when is_binary(text),
    do: call(:md_outline, text, %{dirty: true}, fn -> md_outline_nif(text) end)

  @doc """
  The UTF-16 offset (the unit of every `Yex.Text` offset) of each byte
  offset in `offsets` into `text`, in one pass. `offsets` must be sorted
  and on codepoint boundaries; anything else raises `ArgumentError`.
  Valid UTF-8 only.
  """
  def utf16_offsets(text, offsets) when is_binary(text) and is_list(offsets),
    do: sized(:utf16_offsets, text, [text, offsets])

  # `input` as for `call/4`; up to @inline_max bytes of it runs `<name>_nif`
  # on the calling scheduler, more runs `<name>_dirty_nif`. `force_dirty`
  # is for a call whose work its input size does not bound.
  defp sized(name, input, args, force_dirty \\ false) do
    bytes = if is_integer(input), do: input, else: :erlang.iolist_size(input)
    dirty = force_dirty or bytes > @inline_max
    {inline_nif, dirty_nif} = nifs(name)
    nif = if dirty, do: dirty_nif, else: inline_nif
    call(name, bytes, %{dirty: dirty}, fn -> apply(__MODULE__, nif, args) end)
  end

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
    sized(:hmac_hex_many, bytes, [key, prefix, texts])
  end

  @doc """
  Batch `envelope_open/4` for one column across many rows under one key:
  `{:ok, [plaintext]}` in row order, or `:error` if any row fails (the
  per-row path raises on the same rows). Each row is `{raw_id, bind?, ct,
  nonce}`; the AAD is `prefix <> raw_id` when `bind?`, else empty, which is
  `Crypto.aad_for_row/3` / the legacy rule built in one place. `prefix`
  comes from `Crypto.aad_prefix/2`, so the AAD shape keeps one definition.
  """
  def envelope_open_many(key, prefix, rows)
      when byte_size(key) == 32 and is_binary(prefix) and is_list(rows) do
    bytes = Enum.reduce(rows, 0, fn {_, _, ct, _}, acc -> acc + byte_size(ct) end)

    case sized(:envelope_open_many, bytes, [key, prefix, rows]) do
      nil -> :error
      plain -> {:ok, plain}
    end
  end

  @doc """
  Builds a vault's name index (`native/engram_native/src/names.rs`):
  `{:ok, handle, approx_bytes}` or `:error`. Rows are `{raw_id, bind?,
  path_ct, path_nonce, title_ct | nil, title_nonce | nil}`; the AAD rule is
  `envelope_open_many/3`'s. Decrypted names stay in native memory; the
  handle is an opaque reference.
  """
  def name_index_build(key, path_prefix, title_prefix, rows)
      when byte_size(key) == 32 and is_list(rows) do
    bytes = Enum.reduce(rows, 0, fn row, acc -> acc + byte_size(elem(row, 2)) end)

    case call(:name_index_build, bytes, %{dirty: true}, fn ->
           name_index_build_nif(key, path_prefix, title_prefix, rows)
         end) do
      {handle, approx_bytes} -> {:ok, handle, approx_bytes}
      nil -> :error
    end
  end

  @doc "`{paths, total}`: fuzzy matches over path and title, best first."
  def name_index_search(handle, query, limit)
      when is_binary(query) and is_integer(limit) and limit > 0 do
    call(:name_index_search, query, %{dirty: true}, fn ->
      {paths, total, peak} = name_index_search_nif(handle, query, limit)
      {{paths, total}, peak}
    end)
  end

  @doc "Insert or update one note's names. An empty title keeps the current one."
  def name_index_put(handle, raw_id, path, title)
      when byte_size(raw_id) == 16 and is_binary(path) and is_binary(title),
      do: name_index_put_nif(handle, raw_id, path, title)

  @doc "Removes one note's names, but only while its indexed path is still `path`."
  def name_index_delete(handle, raw_id, path) when byte_size(raw_id) == 16 and is_binary(path),
    do: name_index_delete_nif(handle, raw_id, path)

  @doc """
  `Jason.decode/1`'s result, in Rust: string keys, the first of a repeated
  key wins, integers stay integers, floats correctly rounded. Differs only
  where Qdrant never goes: integers past 64 bits and `-0` decode as floats. Malformed text
  (or nesting past 128 levels) is `{:error, :invalid_json}`. Up to 16 KB runs
  on the calling scheduler.
  """
  def json_decode(text) when is_binary(text) do
    {:ok, sized(:json_decode, text, [text])}
  rescue
    ArgumentError -> {:error, :invalid_json}
  end

  # Inline envelope calls (seal with mode :none, and every open of at most
  # @inline_max bytes of ciphertext) skip call/4: no per-call event. They are
  # the hottest NIF calls (every title, path and tag a listing decrypts), and
  # with PromEx's three handlers attached the event made a 40-byte decrypt
  # 7x :crypto (docs/context/native-nifs.md, "Envelope telemetry"). Nothing is
  # lost: such a call takes microseconds (the duration histogram starts at
  # 1 ms) and its peak is bounded by its input (an inline open inflates at
  # most 16 KB), so per call those histograms only counted it. The counting
  # moved into the NIF: relaxed atomics (`envelope_counts/0`) that see EVERY
  # seal and open, polled by `Engram.PromEx.Native`. Format-1 seals and
  # dirty calls still emit per call.

  @doc """
  `[{nif, calls, input_bytes}]` for `:envelope_seal` and `:envelope_open`:
  every call since the NIF loaded, inline or dirty, any format.
  """
  def envelope_counts do
    {seal_calls, seal_bytes, open_calls, open_bytes} = envelope_counts_nif()
    [{:envelope_seal, seal_calls, seal_bytes}, {:envelope_open, open_calls, open_bytes}]
  end

  @doc """
  `Engram.Crypto.Envelope.encrypt/3`'s engine: `{ct_with_tag, nonce_field}`.
  `mode` `:none` writes format 0 (byte for byte what `:crypto` wrote);
  `:zstd`/`:auto` write format 1 (see `native/engram_core/src/envelope.rs`).
  Raises `ArgumentError` on a key that is not 32 bytes (as `:crypto` did) or
  if the OS RNG fails.
  """
  def envelope_seal(plain, key, aad, mode)
      when is_binary(plain) and is_binary(key) and is_binary(aad) and
             mode in [:none, :zstd, :auto] do
    sealed =
      if mode == :none and byte_size(plain) <= @inline_max,
        do: elem(envelope_seal_nif(plain, key, aad, mode), 0),
        else: sized(:envelope_seal, plain, [plain, key, aad, mode])

    case sealed do
      {_ct, _nonce} = sealed ->
        sealed

      :error ->
        raise ArgumentError, "envelope_seal failed: key must be 32 bytes, or the RNG failed"
    end
  end

  @doc """
  `Engram.Crypto.Envelope.decrypt/4`'s engine: `{:ok, plain}` for any
  format, `:error` for anything that does not authenticate (wrong key,
  AAD, nonce, tampered or truncated ciphertext).

  Up to 16 KB of ciphertext runs inline, any format. A zstd row there
  inflates inline only if its frame declares at most 16 KB (the NIF holds it
  to that); otherwise the NIF answers `:reschedule` without decoding and the
  open reruns dirty: a zstd row of a few KB can inflate to tens of MB, so
  its ciphertext size does not bound the work. More ciphertext runs dirty.
  """
  def envelope_open(ct, nonce, key, aad)
      when is_binary(ct) and is_binary(nonce) and is_binary(key) and is_binary(aad) do
    args = [ct, nonce, key, aad]

    opened =
      if byte_size(ct) <= @inline_max do
        case envelope_open_nif(ct, nonce, key, aad) do
          {:reschedule, _peak} -> sized(:envelope_open, ct, args, true)
          {opened, _peak} -> opened
        end
      else
        sized(:envelope_open, ct, args)
      end

    case opened do
      :error -> :error
      plain -> {:ok, plain}
    end
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
