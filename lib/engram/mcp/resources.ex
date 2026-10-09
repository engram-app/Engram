defmodule Engram.MCP.Resources do
  @moduledoc """
  MCP resources: notes a user attaches by hand (Claude Desktop's + menu,
  Claude Code's `@`). One template, `engram://{vault}/{+path}`, where the
  vault is its slug and the path is percent-encoded per segment.

  Pure helpers. Vault resolution and the credential scope check stay in
  `EngramWeb.McpController`, the one place tool calls already enforce them.
  """

  alias Engram.Notes
  alias Engram.Notes.NameIndex

  @scheme "engram://"
  @template "engram://{vault}/{+path}"
  @mime "text/markdown"
  # Pages walk one vault at a time, newest first, keyset on (updated_at, id).
  # A note edited mid-walk jumps to the front and is not revisited this walk.
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
    with {:ok, index, before} <- decode_cursor(cursor, vaults),
         do: {:ok, page(user, vaults, index, before)}
  end

  # A page fills across vaults: an exhausted or empty vault rolls straight
  # into the next one, so a short page means every remaining vault is done.
  defp page(user, vaults, index, before, acc \\ []) do
    vault = Enum.at(vaults, index)
    room = @page_size - length(acc)
    {:ok, notes} = Notes.list_recent_notes(user, vault, room + 1, before: before)
    {taken, more} = Enum.split(notes, room)
    acc = acc ++ entries(vault, taken, vaults)
    next_vault = Enum.at(vaults, index + 1)

    cond do
      more != [] -> result(acc, encode_cursor(vault, List.last(taken)))
      next_vault && length(acc) < @page_size -> page(user, vaults, index + 1, nil, acc)
      next_vault -> result(acc, encode_cursor(next_vault, nil))
      true -> result(acc, nil)
    end
  end

  defp result(resources, nil), do: %{"resources" => resources}
  defp result(resources, cursor), do: %{"resources" => resources, "nextCursor" => cursor}

  defp entries(vault, notes, vaults) do
    prefix? = length(vaults) > 1

    Enum.map(notes, fn note ->
      %{
        "uri" => uri(vault, note.path),
        "name" => if(prefix?, do: "#{vault.name} › #{note.path}", else: note.path),
        "title" => note.title || note.path,
        "mimeType" => @mime
      }
    end)
  end

  # `{v}` starts a vault from the top; `{v, u, i}` continues after the note
  # with that updated_at and id.
  defp encode_cursor(vault, nil), do: pack(%{"v" => vault.id})

  defp encode_cursor(vault, note),
    do: pack(%{"v" => vault.id, "u" => DateTime.to_iso8601(note.updated_at), "i" => note.id})

  defp pack(map), do: Base.url_encode64(Jason.encode!(map), padding: false)

  defp decode_cursor(nil, _vaults), do: {:ok, 0, nil}

  defp decode_cursor(cursor, vaults) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"v" => vault_id} = fields} <- Jason.decode(json),
         index when is_integer(index) <- Enum.find_index(vaults, &(&1.id == vault_id)),
         {:ok, before} <- decode_position(fields) do
      {:ok, index, before}
    else
      _ -> :error
    end
  end

  defp decode_cursor(_cursor, _vaults), do: :error

  defp decode_position(%{"u" => u, "i" => i} = fields)
       when is_binary(u) and is_binary(i) and map_size(fields) == 3 do
    with {:ok, updated_at, 0} <- DateTime.from_iso8601(u),
         {:ok, id} <- Ecto.UUID.cast(i) do
      {:ok, {updated_at, id}}
    else
      _ -> :error
    end
  end

  defp decode_position(fields) when map_size(fields) == 1, do: {:ok, nil}
  defp decode_position(_fields), do: :error

  def contents(uri, note),
    do: %{"contents" => [%{"uri" => uri, "mimeType" => @mime, "text" => note.content || ""}]}

  def uri(vault, path) do
    encoded =
      path
      |> String.split("/")
      |> Enum.map_join("/", fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)

    @scheme <> vault.slug <> "/" <> encoded
  end

  @doc """
  Splits a note URI into `{vault_slug, path}`. `:error` for anything else.
  The scheme is case-insensitive (RFC 3986); the slug is matched exactly.
  """
  def parse(<<scheme::binary-size(9), rest::binary>>) do
    with true <- String.downcase(scheme) == @scheme,
         [ref, encoded] when ref != "" and encoded != "" <- String.split(rest, "/", parts: 2),
         {:ok, path} <- decode(encoded) do
      {:ok, ref, path}
    else
      _ -> :error
    end
  end

  def parse(_uri), do: :error

  @doc """
  The vault in `vaults` (the credential's accessible set) with this slug.
  Slug only: a display name can collide with another vault's slug, and a
  listed URI must read the vault it was listed from. Out of scope and
  nonexistent are the same `:error`, so no existence oracle.
  """
  def find_vault(vaults, slug) do
    case Enum.find(vaults, &(&1.slug == slug)) do
      nil -> :error
      vault -> {:ok, vault}
    end
  end

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

  # Fuzzy over path and title in the vault's native name index
  # (`Engram.Notes.NameIndex`): built once per vault, then patched live.
  def complete_paths(user, vault, value, client \\ nil) do
    case NameIndex.search(user, vault, value, @max_completions, client) do
      {:ok, paths, total} ->
        %{"values" => paths, "total" => total, "hasMore" => total > length(paths)}

      _superseded_or_error ->
        completion([])
    end
  end

  def completion(values) do
    %{
      "values" => Enum.take(values, @max_completions),
      "total" => length(values),
      "hasMore" => length(values) > @max_completions
    }
  end
end
