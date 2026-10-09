defmodule Engram.MCP.Resources do
  @moduledoc """
  MCP resources: notes a user attaches by hand (Claude Desktop's + menu,
  Claude Code's `@`). One template, `engram://{vault}/{+path}`, where the
  vault is its slug and the path is percent-encoded per segment.

  Pure helpers. Vault resolution and the credential scope check stay in
  `EngramWeb.McpController`, the one place tool calls already enforce them.
  """

  alias Engram.Notes

  @scheme "engram://"
  @template "engram://{vault}/{+path}"
  @mime "text/markdown"
  # Pages walk one vault at a time, newest first. Offset paging: a note edited
  # mid-walk can shift by a slot, which a picker tolerates.
  @page_size 50
  # Spec cap for completion values.
  @max_completions 100

  def template_uri, do: @template

  def template do
    %{
      "uriTemplate" => @template,
      "name" => "note",
      "title" => "Vault note",
      "description" => "A note from one of your vaults. Pick the vault, then search by path.",
      "mimeType" => @mime
    }
  end

  @doc """
  One page of notes across `vaults`, newest first within each vault. The
  cursor names a vault by id, and only ids in `vaults` (the credential's
  accessible set) decode, so a cursor cannot widen scope. `:error` on a bad
  cursor.
  """
  def list(_user, [], nil), do: {:ok, %{"resources" => []}}

  def list(user, vaults, cursor) do
    with {:ok, index, offset} <- decode_cursor(cursor, vaults) do
      vault = Enum.at(vaults, index)
      {:ok, notes} = Notes.list_recent_notes(user, vault, @page_size + 1, offset: offset)
      {page, more?} = Enum.split(notes, @page_size)
      prefix? = length(vaults) > 1

      next =
        cond do
          more? != [] -> encode_cursor(vault, offset + @page_size)
          index + 1 < length(vaults) -> encode_cursor(Enum.at(vaults, index + 1), 0)
          true -> nil
        end

      resources =
        Enum.map(page, fn note ->
          %{
            "uri" => uri(vault, note.path),
            "name" => if(prefix?, do: "#{vault.name} › #{note.path}", else: note.path),
            "title" => note.title,
            "mimeType" => @mime
          }
        end)

      {:ok,
       if(next,
         do: %{"resources" => resources, "nextCursor" => next},
         else: %{"resources" => resources}
       )}
    end
  end

  defp encode_cursor(vault, offset),
    do: Base.url_encode64(Jason.encode!(%{"v" => vault.id, "o" => offset}), padding: false)

  defp decode_cursor(nil, _vaults), do: {:ok, 0, 0}

  defp decode_cursor(cursor, vaults) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"v" => id, "o" => offset}} when is_integer(offset) and offset >= 0 <-
           Jason.decode(json),
         index when is_integer(index) <- Enum.find_index(vaults, &(&1.id == id)) do
      {:ok, index, offset}
    else
      _ -> :error
    end
  end

  defp decode_cursor(_cursor, _vaults), do: :error

  def contents(uri, note),
    do: %{"contents" => [%{"uri" => uri, "mimeType" => @mime, "text" => note.content || ""}]}

  def uri(vault, path) do
    encoded =
      path
      |> String.split("/")
      |> Enum.map_join("/", fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)

    @scheme <> vault.slug <> "/" <> encoded
  end

  @doc "Splits a note URI into `{vault_ref, path}`. `:error` for anything else."
  def parse(@scheme <> rest) do
    with [ref, encoded] when ref != "" and encoded != "" <- String.split(rest, "/", parts: 2),
         {:ok, path} <- decode(encoded) do
      {:ok, ref, path}
    else
      _ -> :error
    end
  end

  def parse(_uri), do: :error

  defp decode(encoded) do
    {:ok, URI.decode(encoded)}
  rescue
    ArgumentError -> :error
  end

  def complete_vaults(vaults, value) do
    needle = String.downcase(value)

    vaults
    |> Enum.map(& &1.slug)
    |> Enum.filter(&String.starts_with?(String.downcase(&1), needle))
    |> completion()
  end

  # ponytail: paths are encrypted at rest, so this decrypts every path in the
  # vault per keystroke (~4µs each, 10k ≈ 40ms). Deliberately uncached: a
  # cache would hold decrypted paths in node memory for every active user.
  def complete_paths(user, vault, value) do
    needle = String.downcase(value)
    {:ok, notes} = Notes.list_tree_notes(user, vault)

    notes
    |> Enum.map(& &1.path)
    |> Enum.filter(&String.contains?(String.downcase(&1), needle))
    |> Enum.sort()
    |> completion()
  end

  def completion(values) do
    %{
      "values" => Enum.take(values, @max_completions),
      "total" => length(values),
      "hasMore" => length(values) > @max_completions
    }
  end
end
