defmodule Engram.Notes.Helpers do
  @moduledoc """
  Pure functions for extracting metadata from note content and paths.
  No DB access — safe to call anywhere. The lone side effect is the
  boundary-instrumented `scrub_utf8/2`, which emits telemetry (and, on the
  write boundary, a log line) when it actually scrubs invalid UTF-8.
  """

  require Logger

  @doc """
  Replaces invalid UTF-8 byte sequences with the Unicode replacement
  character (U+FFFD `�`), returning a guaranteed-valid UTF-8 string.

  Note content is encrypted and stored as `bytea`, which bypasses Postgres's
  UTF-8 validation — so a client can persist invalid bytes (e.g. a multibyte
  char truncated to its lead byte). Those bytes later crash `Jason.encode`
  anywhere content reaches a JSON boundary (search responses, sync Channel
  broadcasts) with a 500. Scrubbing keeps the read/write paths total. Valid
  input is returned byte-identical (no allocation churn for the common case).
  """
  @spec scrub_utf8(String.t()) :: String.t()
  def scrub_utf8(str) when is_binary(str) do
    if String.valid?(str), do: str, else: do_scrub_utf8(str, <<>>)
  end

  @scrub_boundaries [:write, :read, :search, :backfill, :broadcast]

  @doc """
  Boundary-instrumented `scrub_utf8/1`. On the scrub slow path (invalid bytes
  found) it emits a `[:engram, :notes, :utf8_scrub]` counter tagged with
  `boundary` (`:write | :read | :search | :backfill`), and on the `:write`
  boundary it *also* logs a `:data`-category warning.

  The split is deliberate — only `:write` is alert-worthy:
    * **`:write`** — a client just persisted invalid UTF-8: new corruption
      entering at rest, actionable (find the buggy client). The Grafana alert
      fires on this boundary alone.
    * **`:read` / `:search`** — expected on legacy rows until the backfill
      (#739) runs; counter-only to avoid flooding logs on every read.
    * **`:backfill`** — the #739 repair sweep (`Engram.Notes.Utf8Backfill`)
      cleaning legacy rows. A SEPARATE boundary so repairing N rows does NOT
      spike `:write` and page on-call with a false "buggy client" signal — the
      repair pre-scrubs here, then the write path sees already-valid content
      and fast-paths (no `:write` tick).
    * **`:broadcast`** — the sync-Channel egress (#738). Defense-in-depth: the
      `note_changed` payload is scrubbed just before `Jason` encodes it, so even
      a caller that hands the broadcast site content bypassing the write/read
      scrubs (a direct DB or CRDT write) never crashes the serializer. Like
      `:read`, counter-only — never pages.

  Valid input takes the fast path with no telemetry and no allocation.
  """
  @spec scrub_utf8(String.t(), :write | :read | :search | :backfill | :broadcast) :: String.t()
  def scrub_utf8(str, boundary) when is_binary(str) and boundary in @scrub_boundaries do
    if String.valid?(str) do
      str
    else
      report_scrub(boundary)
      do_scrub_utf8(str, <<>>)
    end
  end

  @doc """
  The telemetry (and, on `:write`, the log) of one scrub, for a caller that
  scrubbed outside `scrub_utf8/2`: `Links.Parser`, whose Rust side decodes
  and scrubs percent escapes.
  """
  def report_scrub(boundary) when boundary in @scrub_boundaries do
    :telemetry.execute([:engram, :notes, :utf8_scrub], %{count: 1}, %{boundary: boundary})
    if boundary == :write, do: log_write_scrub()
    :ok
  end

  defp log_write_scrub do
    Logger.warning(
      "invalid UTF-8 scrubbed at write boundary — a client persisted bytes " <>
        "that are not valid UTF-8 (replaced with U+FFFD)",
      Engram.Logger.Metadata.with_category(:warning, :data,
        boundary: :write,
        reason: "invalid_utf8_scrubbed"
      )
    )
  end

  defp do_scrub_utf8(<<>>, acc), do: acc

  defp do_scrub_utf8(<<cp::utf8, rest::binary>>, acc),
    do: do_scrub_utf8(rest, <<acc::binary, cp::utf8>>)

  defp do_scrub_utf8(<<_bad, rest::binary>>, acc),
    do: do_scrub_utf8(rest, <<acc::binary, "�">>)

  # Text fields of a `note_changed` upsert payload that originate from decrypted
  # note content and so could carry invalid UTF-8 at rest. `path` is structural
  # (sanitized + HMAC-validated at write) and always valid, so it is left alone.
  @broadcast_text_fields ~w(content title folder)

  @doc """
  Scrubs the string fields of a `note_changed` broadcast payload to valid UTF-8
  at the sync-Channel egress (#738 defense-in-depth).

  Content/title/folder/tags decrypt from `bytea` ciphertext that bypasses
  Postgres's UTF-8 guard; the write and read boundaries already scrub, but this
  final pass keeps the channel self-defending against any caller (a direct DB or
  CRDT write) that reaches the broadcast site with unscrubbed bytes — invalid
  UTF-8 would otherwise crash the V2 JSON serializer and take down PubSub.

  Only keys that are present and binary are touched, so the metadata-only
  `delete` payload passes through untouched. Valid payloads return unchanged.
  """
  @spec scrub_broadcast_payload(map()) :: map()
  def scrub_broadcast_payload(payload) when is_map(payload) do
    payload
    |> scrub_broadcast_text_fields()
    |> scrub_broadcast_tags()
  end

  defp scrub_broadcast_text_fields(payload) do
    Enum.reduce(@broadcast_text_fields, payload, fn key, acc ->
      case acc do
        %{^key => value} when is_binary(value) ->
          %{acc | key => scrub_utf8(value, :broadcast)}

        _ ->
          acc
      end
    end)
  end

  defp scrub_broadcast_tags(%{"tags" => tags} = payload) when is_list(tags) do
    %{payload | "tags" => Enum.map(tags, &scrub_broadcast_tag/1)}
  end

  defp scrub_broadcast_tags(payload), do: payload

  defp scrub_broadcast_tag(tag) when is_binary(tag), do: scrub_utf8(tag, :broadcast)
  defp scrub_broadcast_tag(tag), do: tag

  @doc """
  Extracts the note title from content (frontmatter > h1 heading outside
  code > filename). The rules run in Rust: native/engram_native/src/meta.rs.
  """
  @spec extract_title(String.t(), String.t()) :: String.t() | nil
  def extract_title(content, path) do
    Engram.Native.note_title(scrub_utf8(content)) || filename_without_extension(path)
  end

  @doc """
  Extracts tags from a note: YAML frontmatter tags merged with inline
  `#tags` (incl. nested `#area/sub`) found in the body.

  Inline scanning skips code (CommonMark ranges), URL fragments, and heading
  markers, and drops purely-numeric matches (`#42`) — none of which are
  tags in Obsidian. Frontmatter tags come first; duplicates are removed.
  Returns [] if none found. The rules run in Rust:
  native/engram_native/src/meta.rs.
  """
  @spec extract_tags(String.t()) :: [String.t()]
  def extract_tags(content) do
    Engram.Native.note_tags(scrub_utf8(content))
  end

  @doc """
  `{extract_title(content, path), extract_tags(content)}` in one NIF call,
  for callers that need both of the same content.
  """
  @spec extract_title_and_tags(String.t(), String.t()) :: {String.t() | nil, [String.t()]}
  def extract_title_and_tags(content, path) do
    {title, tags} = Engram.Native.note_meta(scrub_utf8(content))
    {title || filename_without_extension(path), tags}
  end

  @doc """
  Extracts the folder path (dirname) from a note path.
  Returns "" for root-level notes.
  """
  @spec extract_folder(String.t()) :: String.t()
  def extract_folder(path) do
    case String.split(path, "/") do
      [_filename] -> ""
      parts -> parts |> Enum.drop(-1) |> Enum.join("/")
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp filename_without_extension(path) do
    case String.split(path, "/") |> List.last() do
      nil -> ""
      filename when is_binary(filename) -> Path.rootname(filename)
    end
  end
end
