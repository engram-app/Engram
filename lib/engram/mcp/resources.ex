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
  # ponytail: recent-N per vault, no cursor. Templates + completion reach the rest.
  @recent_per_vault 50
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

  @doc "Recently edited notes across `vaults`, newest first per vault."
  def list(user, vaults) do
    prefix? = length(vaults) > 1

    Enum.flat_map(vaults, fn vault ->
      {:ok, notes} = Notes.list_recent_notes(user, vault, @recent_per_vault)

      Enum.map(notes, fn note ->
        %{
          "uri" => uri(vault, note.path),
          "name" => if(prefix?, do: "#{vault.name} › #{note.path}", else: note.path),
          "title" => note.title,
          "mimeType" => @mime
        }
      end)
    end)
  end

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
  # vault per keystroke (~4µs each, 10k ≈ 40ms). Cache per vault if it shows up.
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
