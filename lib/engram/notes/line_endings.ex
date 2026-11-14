defmodule Engram.Notes.LineEndings do
  @moduledoc """
  LF-only line endings for markdown note docs (Relay's model).

  A markdown note's CRDT doc holds LF only. Text is converted ONCE, where it
  enters the doc (`Notes` write merge, the room-open heal in
  `CrdtBridge.normalize_doc/1`); every reader downstream sees LF. Non-markdown
  docs (`.canvas`, `.base`) stay byte-exact.

  Readers keep tolerating CRLF (frontmatter fence rule, chunker, MCP outline):
  a note nobody has opened or written since this shipped is still CRLF.
  """

  alias Engram.Notes.CrdtBridge

  @doc ~S'Every `\r\n` and every lone `\r` becomes `\n`.'
  @spec to_lf(String.t()) :: String.t()
  # A multi-pattern replace takes the longest match at a position, so
  # `\r\n` wins over its own `\r`.
  def to_lf(text) when is_binary(text), do: String.replace(text, ["\r\n", "\r"], "\n")

  @doc "`to_lf/1` for a markdown `path`; any other path's text is returned as is."
  @spec for_path(String.t(), term()) :: String.t()
  def for_path(text, path) when is_binary(text) do
    if CrdtBridge.markdown_path?(path), do: to_lf(text), else: text
  end
end
