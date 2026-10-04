defmodule Engram.Native do
  @moduledoc """
  In-house Rust NIFs (native/engram_native). Each function is pure, runs on a
  dirty CPU scheduler, and takes and returns binaries.

  Memory standard (see `native/engram_native/src/memory.rs`):

    * Rust allocates through `enif_alloc`, so the BEAM's own accounting
      (`:erlang.memory(:system)`, recon_alloc) includes it.
    * Every NIF call reports its native PEAK bytes, emitted as
      `[:engram, :nif, :call, :stop]` by `call/3`.
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

  @doc "The keyword tokenizer: `{tokens, raw_len}`."
  def tokens_with_len(_text, _language), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Live bytes held by this library's Rust heap, process-wide."
  def live_bytes, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Batch keyword encode: `[{indices_u32le, values_f64le, doc_len}]`, indices
  ascending. Emits `[:engram, :nif, :call, :stop]`.
  """
  def encode_documents(texts, filter_key, avgdl, language) do
    call(:keyword_encode, texts, fn ->
      encode_documents_nif(texts, filter_key, avgdl, language)
    end)
  end

  # Every NIF entry point goes through here: one event shape for all of them,
  # so a dashboard or alert written for one covers the next.
  defp call(name, input, fun) do
    t0 = System.monotonic_time()
    {result, peak} = fun.()

    :telemetry.execute(
      [:engram, :nif, :call, :stop],
      %{
        duration: System.monotonic_time() - t0,
        native_peak_bytes: peak,
        input_bytes: :erlang.iolist_size(input)
      },
      %{nif: name}
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
