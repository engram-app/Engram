defmodule Engram.Test.McpOverwrite do
  @moduledoc """
  `write_note` as an agent that read the note first: it passes the note's
  current `content_hash` as `base_hash`, which replacing an existing note
  requires (#2480). A missing note gets no base, so this also creates.

  For tests that overwrite on purpose and are not about the base check.
  """

  alias Engram.MCP.Handlers
  alias Engram.Notes

  def write_note(user, vault, %{"path" => path} = args) do
    base =
      case Notes.get_note(user, vault, path) do
        {:ok, note} -> %{"base_hash" => note.content_hash}
        {:error, :not_found} -> %{}
      end

    Handlers.handle("write_note", user, vault, Map.merge(base, args))
  end
end
