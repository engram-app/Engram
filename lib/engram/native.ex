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

  @doc "Frontmatter `title:`, else the first H1 outside code, else nil. Valid UTF-8 only."
  def note_title(content),
    do: parse(:note_title, content, &note_title_nif/1, &note_title_dirty_nif/1)

  @doc "Frontmatter tags then inline `#tags`, deduplicated. Valid UTF-8 only."
  def note_tags(content), do: parse(:note_tags, content, &note_tags_nif/1, &note_tags_dirty_nif/1)

  defp parse(name, content, inline, _dirty) when byte_size(content) <= @inline_max,
    do: call(name, content, %{dirty: false}, fn -> inline.(content) end)

  defp parse(name, content, _inline, dirty),
    do: call(name, content, %{dirty: true}, fn -> dirty.(content) end)

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

  # Every NIF entry point goes through here: one event shape for all of them,
  # so a dashboard or alert written for one covers the next.
  defp call(name, input, meta, fun) do
    t0 = System.monotonic_time()
    {result, peak} = fun.()

    :telemetry.execute(
      [:engram, :nif, :call, :stop],
      %{
        duration: System.monotonic_time() - t0,
        native_peak_bytes: peak,
        input_bytes: :erlang.iolist_size(input)
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
