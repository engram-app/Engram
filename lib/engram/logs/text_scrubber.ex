defmodule Engram.Logs.TextScrubber do
  @moduledoc """
  Server-side scrub of client-supplied log text (`message`, `stack`).

  The plugin scrubs before shipping (`scrubLogText`/`scrubStack` in
  `src/error-util.ts`), but every plugin version ever released is still in the
  field, and a stack's first line is the raw error message. This runs once on
  ingest, so neither the `client_logs` row nor the Loki re-emit carries what an
  older client failed to strip.

  A port of the plugin's rules, kept behaviorally identical (the SPA's Sentry
  scrub uses the same three). Every rule is linear: the plugin's earlier
  unquoted-path regex was a ReDoS and ate routes, which is why rule B is a
  bounded token walk rather than a regex.

    * **A: quoted path.** A quote opens and closes only at a word boundary, so
      `can't … won't` is not a quoted span. Content holding a `/` or `\\` (with
      at most 512 chars either side) becomes `<path>`, keeping the quotes.
      Quoted `/api/...` routes are exempt.
    * **C: home directory or Windows drive,** unquoted, up to the next `|` or
      end of line: they name the OS user.
    * **B: unquoted spaced path,** per line. From a token ending in a vault file
      extension, walk back at most 8 tokens to the nearest token with a
      separator, extend over directly preceding separator tokens, never cross a
      `|`/`=` field token, and redact the span.

  Honest gap: a spaced title at the vault ROOT with no separator anywhere
  (`Divorce settlement draft.md`) leaks all but its last word. The plugin's
  `errMsg(e, knownPath)` at the call site is the fix.
  """

  @egress_quoted ~r/(^|[\s(\[{=:,])(?:'([^'\n]{1,1025})'|"([^"\n]{1,1025})"|`([^`\n]{1,1025})`)(?=$|[\s)\]},.;:|])/
  @api_route ~r/^\/api(\/[a-z0-9_:.-]*)*$/
  @home_or_drive ~r/(?:~|\/Users|\/home|\b[A-Za-z]:(?=[\\\/]))[\\\/][^\n|]*/i
  @vault_ext ~r/\.(?:md|markdown|canvas|base|excalidraw|txt|rtf|csv|tsv|json|html?|xml|pdf|epub|docx?|xlsx?|pptx?|odt|ods|odp|key|pages|numbers|png|jpe?g|gif|bmp|svg|webp|avif|heic|heif|tiff?|mp3|wav|ogg|m4a|flac|aac|mp4|mov|webm|mkv|avi|zip)$/i
  @trailing_punct [?,, ?., ?;, ?:, ?), ?], ?}, ?", ?']
  @max_backwalk 8
  @max_side 512

  @spec scrub(String.t() | nil) :: String.t() | nil
  def scrub(text) when is_binary(text) do
    text
    |> then(
      &Regex.replace(@egress_quoted, &1, fn match, pre, s, d, t ->
        redact_quoted(match, pre, s, d, t)
      end)
    )
    |> then(
      &Regex.replace(@home_or_drive, &1, fn m ->
        if String.ends_with?(m, " "), do: "<path> ", else: "<path>"
      end)
    )
    |> String.split("\n")
    |> Enum.map_join("\n", &redact_spaced_paths/1)
  end

  def scrub(other), do: other

  @doc """
  Reduce a stack to its error name and frames, then scrub. A V8 stack's header
  is `Name: <message>`, the raw error message; JSC stacks have no header.
  """
  @spec scrub_stack(String.t() | nil) :: String.t() | nil
  def scrub_stack(stack) when is_binary(stack) do
    lines = String.split(stack, "\n")

    case Enum.find_index(lines, &Regex.match?(~r/^\s*at\s/, &1)) do
      index when is_integer(index) and index > 0 ->
        name =
          case Regex.run(~r/^[\w$.]+(?=:|$)/, hd(lines)) do
            [name] -> name
            _ -> "Error"
          end

        scrub(Enum.join([name | Enum.drop(lines, index)], "\n"))

      _ ->
        scrub(stack)
    end
  end

  def scrub_stack(other), do: other

  defp redact_quoted(match, pre, single, double, tick) do
    {quote, content} =
      cond do
        single != "" -> {"'", single}
        double != "" -> {"\"", double}
        true -> {"`", tick}
      end

    if not Regex.match?(@api_route, content) and separator_within_bounds?(content),
      do: pre <> quote <> "<path>" <> quote,
      else: match
  end

  defp separator_within_bounds?(content) do
    size = byte_size(content)

    content
    |> :binary.matches(["/", "\\"])
    |> Enum.any?(fn {pos, _} -> pos <= @max_side and size - pos - 1 <= @max_side end)
  end

  defp redact_spaced_paths(line) do
    if String.contains?(line, ".") do
      tokens = line |> String.split(" ") |> List.to_tuple()
      line |> spaced_spans(tokens) |> rebuild(tokens)
    else
      line
    end
  end

  # Returns [{start, stop}] token spans to replace with "<path>", left to right.
  # Each token lands in at most one span and the back-walk is bounded: linear.
  defp spaced_spans(_line, tokens) do
    count = tuple_size(tokens)

    {spans, _floor} =
      Enum.reduce(0..(count - 1)//1, {[], 0}, fn i, {spans, floor} ->
        tok = elem(tokens, i)

        if String.contains?(tok, ".") and Regex.match?(@vault_ext, strip_trailing_punct(tok)) do
          start = span_start(tokens, i, floor)
          {[{start, i} | spans], i + 1}
        else
          {spans, floor}
        end
      end)

    Enum.reverse(spans)
  end

  defp span_start(tokens, i, floor) do
    lower = max(floor, i - @max_backwalk)

    Enum.reduce_while(i..lower//-1, i, fn j, acc ->
      tok = elem(tokens, j)

      cond do
        j < i and field?(tok) -> {:halt, acc}
        separator?(tok) -> {:halt, extend_back(tokens, j, floor)}
        true -> {:cont, acc}
      end
    end)
  end

  defp extend_back(tokens, start, floor) do
    if start > floor and separator?(elem(tokens, start - 1)) and
         not field?(elem(tokens, start - 1)),
       do: extend_back(tokens, start - 1, floor),
       else: start
  end

  defp rebuild(spans, tokens) do
    list = Tuple.to_list(tokens)

    {out, rest_from} =
      Enum.reduce(spans, {[], 0}, fn {start, stop}, {out, from} ->
        kept = Enum.slice(list, from, start - from)
        {[["<path>"], kept | out], stop + 1}
      end)

    tail = Enum.drop(list, rest_from)
    Enum.reverse([tail | out]) |> Enum.concat() |> Enum.join(" ")
  end

  defp strip_trailing_punct(token) do
    token
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in @trailing_punct))
    |> Enum.reverse()
    |> List.to_string()
  end

  # Single-string patterns: a list pattern is recompiled on every call, which
  # was the dominant cost on a 25k-token line.
  defp separator?(tok), do: String.contains?(tok, "/") or String.contains?(tok, "\\")
  defp field?(tok), do: String.contains?(tok, "|") or String.contains?(tok, "=")
end
