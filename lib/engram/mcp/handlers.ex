defmodule Engram.MCP.Handlers do
  @moduledoc """
  MCP tool handler implementations.
  Each function takes (user, vault, args) and returns a markdown-formatted string.
  """

  alias Engram.{Notes, Search, Vaults}

  # -- Vault tools --

  def handle("list_vaults", user, _vault, _args) do
    vaults = Vaults.list_vaults(user)

    lines =
      Enum.map(vaults, fn v ->
        default = if v.is_default, do: " (default)", else: ""
        desc = if v.description, do: " — #{v.description}", else: ""
        "- **#{v.name}**#{default} (ID: #{v.id})#{desc}"
      end)

    {:ok, Enum.join(lines, "\n")}
  end

  def handle("set_vault", user, _vault, args) do
    case args["vault_id"] do
      nil ->
        case Vaults.get_default_vault(user) do
          {:ok, v} -> {:ok, "Active vault: **#{v.name}** (default)"}
          {:error, _} -> {:error, "No default vault found"}
        end

      vault_id ->
        case Vaults.get_vault(user, vault_id) do
          {:ok, v} -> {:ok, "Active vault: **#{v.name}**"}
          {:error, _} -> {:error, "Vault not found"}
        end
    end
  end

  # -- Read tools --

  def handle("search_notes", user, vault, args) do
    query = args["query"] || ""
    limit = min(args["limit"] || 5, 20)
    tags = args["tags"]

    opts = [limit: limit, mode: search_mode(args)]
    opts = if tags, do: Keyword.put(opts, :tags, tags), else: opts

    case Search.search(user, vault, query, opts) do
      {:ok, results} when results != [] ->
        text =
          results
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {r, i} ->
            lines = ["## Result #{i} (score: #{Float.round(r.score, 3)})"]
            lines = if r[:title], do: lines ++ ["**Title:** #{r.title}"], else: lines

            lines =
              if r[:heading_path], do: lines ++ ["**Section:** #{r.heading_path}"], else: lines

            lines =
              if r[:source_path], do: lines ++ ["**Source:** #{r.source_path}"], else: lines

            lines =
              if r[:tags] && r.tags != [],
                do: lines ++ ["**Tags:** #{Enum.join(r.tags, ", ")}"],
                else: lines

            lines = lines ++ ["\n#{r.text}\n"]
            Enum.join(lines, "\n")
          end)

        {:ok, text}

      {:ok, []} ->
        {:ok, "No results found."}

      {:error, _reason} ->
        {:ok, "Search unavailable."}
    end
  end

  def handle("list_tags", user, vault, _args) do
    {:ok, tags} = Notes.list_tags_with_counts(user, vault)

    if tags == [] do
      {:ok, "No tags found."}
    else
      lines = ["| Tag | Count |", "|-----|-------|"]
      lines = lines ++ Enum.map(tags, fn t -> "| #{t.name} | #{t.count} |" end)
      {:ok, Enum.join(lines, "\n")}
    end
  end

  def handle("list_folders", user, vault, _args) do
    {:ok, folders} = Notes.list_folders_with_counts(user, vault)

    if folders == [] do
      {:ok, "No folders found."}
    else
      lines = ["| Folder | Notes |", "|--------|-------|"]

      lines =
        lines ++
          Enum.map(folders, fn f ->
            folder_name = if f.folder == "" or is_nil(f.folder), do: "(root)", else: f.folder
            "| #{folder_name} | #{f.count} |"
          end)

      {:ok, Enum.join(lines, "\n")}
    end
  end

  def handle("list_folder", user, vault, args) do
    folder = args["folder"] || ""
    {:ok, notes} = Notes.list_notes_in_folder(user, vault, folder)

    if notes == [] do
      folder_label = if folder == "", do: "(root)", else: folder
      {:ok, "No notes found in folder: #{folder_label}"}
    else
      folder_label = if folder == "", do: "(root)", else: folder

      lines = [
        "**Folder:** #{folder_label}",
        "",
        "| Title | Path | Tags |",
        "|-------|------|------|"
      ]

      lines =
        lines ++
          Enum.map(notes, fn n ->
            tags = if n.tags && n.tags != [], do: Enum.join(n.tags, ", "), else: ""
            "| #{n.title} | #{n.path} | #{tags} |"
          end)

      {:ok, Enum.join(lines, "\n")}
    end
  end

  def handle("create_folder", user, vault, %{"folder" => folder}) when is_binary(folder) do
    case Notes.create_folder_marker(user, vault, folder) do
      {:ok, marker} ->
        {:ok, "Created folder: #{marker.folder}"}

      {:error, :root_folder_not_marker} ->
        {:error, "folder must be a non-empty path"}

      {:error, atom} when is_atom(atom) ->
        {:error, "Failed: #{atom}"}

      {:error, _other} ->
        {:error, "Failed to create folder."}
    end
  end

  def handle("create_folder", _user, _vault, _args) do
    {:error, "folder parameter is required"}
  end

  def handle("suggest_folder", user, vault, args) do
    description = args["description"] || ""
    limit = max(1, min(args["limit"] || 5, 10))

    case Search.search(user, vault, description, limit: 10) do
      {:ok, results} when results != [] ->
        folder_counts =
          results
          |> Enum.map(fn r ->
            path = r[:source_path] || ""

            if String.contains?(path, "/") do
              path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
            else
              ""
            end
          end)
          |> Enum.frequencies()
          |> Enum.sort_by(fn {_f, c} -> -c end)
          |> Enum.take(limit)

        if folder_counts == [] do
          {:ok, "No folders found. The vault may be empty."}
        else
          lines = ["| Rank | Folder | Notes |", "|------|--------|-------|"]

          lines =
            (lines ++
               Enum.with_index(folder_counts, 1))
            |> Enum.map(fn {{folder, count}, rank} ->
              folder_name = if folder == "", do: "(root)", else: folder
              "| #{rank} | #{folder_name} | #{count} |"
            end)

          {:ok, Enum.join(lines, "\n")}
        end

      _ ->
        {:ok, "No folders found. The vault may be empty."}
    end
  end

  def handle("get_note", user, vault, args) do
    source_path = args["source_path"] || ""

    case Notes.get_note(user, vault, source_path) do
      {:ok, note} ->
        lines = ["# #{note.title}"]

        lines =
          if note.tags && note.tags != [],
            do: lines ++ ["**Tags:** #{Enum.join(note.tags, ", ")}"],
            else: lines

        lines = lines ++ ["**Path:** #{note.path}"]
        lines = lines ++ ["**Folder:** #{note.folder || ""}\n"]
        lines = lines ++ [note.content]
        {:ok, Enum.join(lines, "\n")}

      {:error, :not_found} ->
        {:ok, "Note not found: #{source_path}"}
    end
  end

  # -- Write tools --

  def handle("create_note", user, vault, args) do
    title = args["title"] || "Untitled"
    content = args["content"] || ""
    suggested_folder = args["suggested_folder"]

    folder =
      if suggested_folder && suggested_folder != "" do
        String.trim_trailing(suggested_folder, "/")
      else
        auto_place_folder(user, vault, title, content)
      end

    filename = String.replace(title, "/", "-") <> ".md"
    path = if folder != "", do: "#{folder}/#{filename}", else: filename

    content =
      if String.starts_with?(String.trim(content), "# ") do
        content
      else
        "# #{title}\n\n#{content}"
      end

    case Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => now()}) do
      {:ok, _note} -> {:ok, "Note created: #{path}"}
      {:error, _} -> {:ok, "Failed to create note: #{path}"}
    end
  end

  def handle("write_note", _user, _vault, %{"content" => content})
      when byte_size(content) > 10 * 1024 * 1024 do
    {:ok, "Error: note exceeds maximum size of 10MB"}
  end

  def handle("write_note", user, vault, args) do
    path = args["path"] || ""
    content = args["content"] || ""

    case Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => now()}) do
      {:ok, _note} -> {:ok, "Note saved: #{path}"}
      {:error, _} -> {:ok, "Failed to save note: #{path}"}
    end
  end

  def handle("append_to_note", user, vault, args) do
    path = args["path"] || ""
    text = args["text"] || ""

    case Notes.get_note(user, vault, path) do
      {:ok, note} ->
        content = String.trim_trailing(note.content, "\n") <> "\n" <> text

        case Notes.upsert_note(user, vault, %{
               "path" => path,
               "content" => content,
               "mtime" => now()
             }) do
          {:ok, _} -> {:ok, "Note appended to: #{path}"}
          {:error, _} -> {:ok, "Failed to append to note: #{path}"}
        end

      {:error, :not_found} ->
        title =
          path
          |> String.split("/")
          |> List.last()
          |> String.trim_trailing(".md")

        content = "# #{title}\n\n#{text}"

        case Notes.upsert_note(user, vault, %{
               "path" => path,
               "content" => content,
               "mtime" => now()
             }) do
          {:ok, _} -> {:ok, "Note created: #{path}"}
          {:error, _} -> {:ok, "Failed to create note: #{path}"}
        end
    end
  end

  def handle("patch_note", user, vault, args) do
    path = args["path"] || ""
    find = args["find"] || ""
    replace = args["replace"] || ""
    occurrence = args["occurrence"] || 0

    case Notes.get_note(user, vault, path) do
      {:ok, note} ->
        if String.contains?(note.content, find) do
          {new_content, count} = do_replace(note.content, find, replace, occurrence)

          case Notes.upsert_note(user, vault, %{
                 "path" => path,
                 "content" => new_content,
                 "mtime" => now()
               }) do
            {:ok, _} -> {:ok, "Replaced #{count} occurrence(s) in #{path}"}
            {:error, _} -> {:ok, "Failed to patch note: #{path}"}
          end
        else
          {:ok, "Text not found in #{path}"}
        end

      {:error, :not_found} ->
        {:ok, "Note not found: #{path}"}
    end
  end

  def handle("update_section", user, vault, args) do
    path = args["path"] || ""
    heading = args["heading"] || ""
    new_content = args["content"] || ""
    level = args["level"] || 2

    case Notes.get_note(user, vault, path) do
      {:ok, note} ->
        prefix = String.duplicate("#", max(1, min(level, 6))) <> " "
        target = prefix <> heading
        lines = String.split(note.content, "\n")

        start_idx =
          Enum.find_index(lines, fn line ->
            String.trim(line) == String.trim(target)
          end)

        if start_idx == nil do
          {:ok, "Heading not found: #{target}"}
        else
          end_idx =
            Enum.find_index(Enum.drop(lines, start_idx + 1), fn line ->
              stripped = String.trim_leading(line)

              if String.starts_with?(stripped, "#") do
                h_level =
                  stripped
                  |> String.graphemes()
                  |> Enum.take_while(&(&1 == "#"))
                  |> length()

                rest = String.slice(stripped, h_level, 1)
                h_level <= level and rest in [" ", ""]
              else
                false
              end
            end)

          end_idx =
            if end_idx == nil,
              do: length(lines),
              else: start_idx + 1 + end_idx

          new_lines =
            Enum.slice(lines, 0, start_idx + 1) ++
              [String.trim_trailing(new_content, "\n")] ++
              Enum.slice(lines, end_idx, length(lines))

          final_content = Enum.join(new_lines, "\n")

          case Notes.upsert_note(user, vault, %{
                 "path" => path,
                 "content" => final_content,
                 "mtime" => now()
               }) do
            {:ok, _} -> {:ok, "Section '#{heading}' updated in #{path}"}
            {:error, _} -> {:ok, "Failed to update section in #{path}"}
          end
        end

      {:error, :not_found} ->
        {:ok, "Note not found: #{path}"}
    end
  end

  def handle("rename_note", user, vault, args) do
    old_path = args["old_path"] || ""
    new_path = args["new_path"] || ""

    case Notes.rename_note(user, vault, old_path, new_path) do
      {:ok, _note} -> {:ok, "Note renamed: #{old_path} -> #{new_path}"}
      {:error, :not_found} -> {:ok, "Note not found: #{old_path}"}
    end
  end

  def handle("rename_folder", user, vault, args) do
    old_folder = args["old_folder"] || ""
    new_folder = args["new_folder"] || ""

    case Notes.rename_folder(user, vault, old_folder, new_folder) do
      {:ok, count} ->
        {:ok, "Folder renamed: #{old_folder} -> #{new_folder} (#{count} notes updated)"}
    end
  end

  def handle("delete_note", user, vault, args) do
    path = args["path"] || ""
    Notes.delete_note(user, vault, path)
    {:ok, "Note deleted: #{path}"}
  end

  def handle(name, _user, _vault, _args) do
    {:error, "Unknown tool: #{name}"}
  end

  # -- Public helpers --

  @doc "Map the MCP `mode` arg to a Search mode (unknown → :hybrid)."
  def search_mode(args) do
    case args["mode"] do
      "keyword" -> :keyword
      "vector" -> :vector
      _ -> :hybrid
    end
  end

  # -- Private helpers --

  defp do_replace(content, find, replace, -1) do
    count = content |> String.split(find) |> length() |> Kernel.-(1)
    {String.replace(content, find, replace), count}
  end

  defp do_replace(content, find, replace, occurrence) do
    parts = String.split(content, find)

    if occurrence >= length(parts) - 1 do
      {content, 0}
    else
      before = Enum.take(parts, occurrence + 1) |> Enum.join(find)
      after_parts = Enum.drop(parts, occurrence + 1) |> Enum.join(find)
      {before <> replace <> after_parts, 1}
    end
  end

  defp auto_place_folder(user, vault, title, content) do
    query =
      "#{title} #{String.slice(content, 0, 300)}" |> String.replace("\n", " ") |> String.trim()

    if query == "" do
      ""
    else
      case Search.search(user, vault, query, limit: 10) do
        {:ok, results} when results != [] ->
          folder_counts =
            results
            |> Enum.map(fn r ->
              path = r[:source_path] || ""

              if String.contains?(path, "/") do
                path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
              else
                ""
              end
            end)
            |> Enum.frequencies()
            |> Enum.sort_by(fn {_f, c} -> -c end)

          case folder_counts do
            [{folder, _} | _] -> folder
            _ -> ""
          end

        _ ->
          ""
      end
    end
  end

  defp now, do: :os.system_time(:second) |> Kernel./(1) |> Float.round(1)
end
