defmodule Engram.MCP.Handlers do
  @moduledoc """
  MCP tool handler implementations.
  Each function takes (user, vault, args) and returns a markdown-formatted string.
  """

  alias Engram.{Notes, Search}

  # -- Vault tools --

  # `vaults` is pre-scoped by the controller to the set THIS credential can use
  # (OAuth binding + API-key restrictions), so we never advertise a vault the
  # caller can't actually read or write (#729).
  def handle("list_vaults", _user, vaults, _args) when is_list(vaults) do
    if vaults == [] do
      {:ok, "No vaults are accessible with this connection."}
    else
      lines =
        Enum.map(vaults, fn v ->
          default = if v.is_default, do: " (default)", else: ""
          desc = if v.description, do: " — #{v.description}", else: ""
          "- **#{v.name}**#{default} (ID: #{v.id})#{desc}"
        end)

      {:ok, Enum.join(lines, "\n")}
    end
  end

  # `accessible` is the credential-scoped vault set (see the controller's
  # dispatch_tool). set_vault does NOT persist anything — MCP is stateless — so
  # it only validates the id against what this credential can reach and echoes
  # the id to thread on subsequent calls. It must never confirm a vault outside
  # the accessible set (#729).
  def handle("set_vault", _user, accessible, args) when is_list(accessible) do
    case args["vault_id"] do
      nil ->
        {:ok,
         "MCP keeps no active-vault state between calls. Pass `vault_id` on each " <>
           "vault-scoped tool call to target a vault. Call list_vaults to see the IDs."}

      vault_id ->
        case Enum.find(accessible, &(to_string(&1.id) == to_string(vault_id))) do
          nil ->
            {:error,
             "Vault not found or not accessible: #{vault_id}. Call list_vaults to see the " <>
               "vaults this connection can use."}

          v ->
            {:ok,
             "Vault **#{v.name}** (ID: #{v.id}) is valid. Pass vault_id=\"#{v.id}\" on each " <>
               "tool call to target it — MCP stores no active vault between calls."}
        end
    end
  end

  # -- Read tools --

  # Cross-vault default (the credential can reach every vault and no vault_id was
  # given): search all vaults at once and label each hit with its vault so the
  # caller can follow up (e.g. get_note) against the right one. `allow_cross_vault`
  # bypasses the Pro billing gate — multi-vault search is the MCP default on every
  # tier (product decision 2026-07-10).
  def handle("search_notes", user, {:cross_vault, vaults}, args) do
    query = args["query"] || ""
    opts = Keyword.merge(build_search_opts(args), cross_vault: true, allow_cross_vault: true)
    names = Map.new(vaults, &{to_string(&1.id), &1.name})
    render_search(Search.search(user, nil, query, opts), names)
  end

  def handle("search_notes", user, vault, args) do
    query = args["query"] || ""
    render_search(Search.search(user, vault, query, build_search_opts(args)), %{})
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

    case Search.search(user, vault, description, limit: 10, diversity: 0) do
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
        {:ok, format_get_note(note)}

      {:error, :not_found} ->
        {:ok, "Note not found: #{source_path}"}
    end
  end

  def handle("get_notes", user, vault, args) do
    paths = args["paths"] || []

    cond do
      not is_list(paths) or paths == [] ->
        {:error, "paths must be a non-empty array"}

      length(paths) > 20 ->
        {:error, "Too many paths (max 20). Split into multiple calls."}

      true ->
        body =
          paths
          |> Enum.map(fn path ->
            case Notes.get_note(user, vault, path) do
              {:ok, note} -> format_get_note(note)
              {:error, :not_found} -> "Note not found: #{path}"
            end
          end)
          |> Enum.join("\n\n---\n\n")

        {:ok, body}
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
      {:ok, _note} ->
        # Read-modify-write via the CAS helper: a write landing between the
        # read and the upsert must trigger a re-read + rebuild, not be deleted
        # by the full-content merge (2026-07-07: MCP appends erased).
        case rmw_upsert(user, vault, path, fn content ->
               String.trim_trailing(content, "\n") <> "\n" <> text
             end) do
          {:ok, _} -> {:ok, "Note appended to: #{path}"}
          {:error, :version_conflict, _} -> {:ok, "Note changed concurrently; retry: #{path}"}
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
                 "mtime" => now(),
                 "base_hash" => note.content_hash
               }) do
            {:ok, _} -> {:ok, "Replaced #{count} occurrence(s) in #{path}"}
            {:error, :version_conflict, _} -> {:ok, "Note changed concurrently; retry: #{path}"}
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
                 "mtime" => now(),
                 "base_hash" => note.content_hash
               }) do
            {:ok, _} -> {:ok, "Section '#{heading}' updated in #{path}"}
            {:error, :version_conflict, _} -> {:ok, "Note changed concurrently; retry: #{path}"}
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

    case Engram.Folders.rename(user, vault, old_folder, new_folder) do
      {:ok, %{notes: n, attachments: a}} ->
        {:ok,
         "Folder renamed: #{old_folder} -> #{new_folder} " <>
           "(#{n} notes, #{a} attachments updated)"}

      {:error, :conflict} ->
        {:ok, "Folder rename conflict: #{new_folder} already exists"}

      # Catch-all (Bug 2): Folders.rename can surface a non-:conflict
      # {:error, reason} (e.g. a crypto failure in the attachment leg). Without
      # this clause it CaseClauseError'd → 500.
      {:error, reason} ->
        {:ok, "Could not rename folder #{old_folder} -> #{new_folder}: #{inspect(reason)}"}
    end
  end

  def handle("delete_note", user, vault, args) do
    path = args["path"] || ""
    Notes.delete_note(user, vault, path)
    {:ok, "Note deleted: #{path}"}
  end

  def handle("move_attachment", user, vault, args) do
    old_path = args["old_path"] || ""
    new_path = args["new_path"] || ""

    case Engram.Attachments.move_attachment(user, vault, old_path, new_path) do
      {:ok, _att} -> {:ok, "Attachment moved: #{old_path} -> #{new_path}"}
      {:error, :not_found} -> {:ok, "Attachment not found: #{old_path}"}
      {:error, :conflict} -> {:ok, "Attachment already exists at: #{new_path}"}
      # Catch-all (Bug 2): move_attachment's crypto `with` head can return an
      # arbitrary {:error, reason}; without this clause it CaseClauseError'd → 500.
      {:error, reason} -> {:ok, "Could not move attachment: #{inspect(reason)}"}
    end
  end

  def handle(name, _user, _vault, _args) do
    {:error, "Unknown tool: #{name}"}
  end

  # -- Public helpers --

  @doc """
  Build the keyword opts list for `Engram.Search.search/4` from MCP tool args.

  Assembles `:limit`, `:mode`, `:tags`, `:folder`, `:type`, the four date-bound
  opts (`:created_after`, `:created_before`, `:updated_after`,
  `:updated_before`), and (when given a number) `:diversity` from the raw args
  map. Absent or non-numeric `diversity` is omitted so the `SearchProfile`
  default applies. Date args are parsed as ISO 8601; a missing, non-string, or
  unparseable value is silently omitted rather than raising, since a bad MCP
  tool arg must not crash the call.
  """
  def build_search_opts(args) do
    limit = min(args["limit"] || 5, 20)
    tags = args["tags"]

    opts = [limit: limit, mode: search_mode(args)]
    opts = if tags, do: Keyword.put(opts, :tags, tags), else: opts
    opts = if args["folder"], do: Keyword.put(opts, :folder, args["folder"]), else: opts
    opts = if args["type"], do: Keyword.put(opts, :type, args["type"]), else: opts

    opts =
      Enum.reduce(
        [
          created_after: "created_after",
          created_before: "created_before",
          updated_after: "updated_after",
          updated_before: "updated_before"
        ],
        opts,
        fn {key, arg}, acc -> put_date_opt(acc, key, args[arg]) end
      )

    if is_number(args["diversity"]),
      do: Keyword.put(opts, :diversity, args["diversity"]),
      else: opts
  end

  defp put_date_opt(opts, key, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> Keyword.put(opts, key, dt)
      _ -> opts
    end
  end

  defp put_date_opt(opts, _key, _value), do: opts

  @doc "Map the MCP `mode` arg to a Search mode (unknown → :hybrid)."
  def search_mode(args) do
    case args["mode"] do
      "keyword" -> :keyword
      "vector" -> :vector
      _ -> :hybrid
    end
  end

  # -- Private helpers --

  @doc false
  # Read-modify-write with compare-and-swap (Phase 0, identity-as-CRDT).
  # Declares the read row's content_hash as `base_hash` so a write landing
  # between the read and the upsert 409s instead of being deleted by the
  # full-content merge, then retries ONCE on a fresh read. `rebuild` receives
  # the current content and returns the new content. Public (doc: false) so
  # the CAS interleaving is unit-testable with a racing rebuild fun.
  def rmw_upsert(user, vault, path, rebuild, attempt \\ 0) do
    with {:ok, note} <- Notes.get_note(user, vault, path) do
      case Notes.upsert_note(user, vault, %{
             "path" => path,
             "content" => rebuild.(note.content),
             "mtime" => now(),
             "base_hash" => note.content_hash
           }) do
        {:error, :version_conflict, _} when attempt == 0 ->
          rmw_upsert(user, vault, path, rebuild, 1)

        other ->
          other
      end
    end
  end

  @doc false
  # Render Search.search/4 output for the search_notes tool. `names` maps
  # vault_id → vault name; when non-empty (cross-vault mode) each hit is labelled
  # with its vault so the caller knows which vault to act against. Public (doc:
  # false) so the vault-labelling can be unit-tested without standing up Qdrant.
  def render_search({:ok, results}, names) when results != [] do
    text =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {r, i} -> format_search_result(r, i, names) end)

    {:ok, text}
  end

  def render_search({:ok, _empty}, _names), do: {:ok, "No results found."}
  def render_search({:error, _reason}, _names), do: {:ok, "Search unavailable."}

  defp format_search_result(r, i, names) do
    ["## Result #{i} (score: #{Float.round(r.score, 3)})"]
    |> maybe_line(vault_label(r, names))
    |> maybe_line(r[:title] && "**Title:** #{r.title}")
    |> maybe_line(r[:heading_path] && "**Section:** #{r.heading_path}")
    |> maybe_line(r[:source_path] && "**Source:** #{r.source_path}")
    |> maybe_line(r[:tags] && r.tags != [] && "**Tags:** #{Enum.join(r.tags, ", ")}")
    |> Kernel.++(["\n#{r.text}\n"])
    |> Enum.join("\n")
  end

  defp maybe_line(lines, line) when is_binary(line), do: lines ++ [line]
  defp maybe_line(lines, _falsy), do: lines

  defp vault_label(_r, names) when map_size(names) == 0, do: nil

  defp vault_label(r, names) do
    case names[to_string(r[:vault_id])] do
      name when is_binary(name) -> "**Vault:** #{name} (#{r[:vault_id]})"
      _ -> nil
    end
  end

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
      case Search.search(user, vault, query, limit: 10, diversity: 0) do
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

  @doc """
  Render a note for the `get_note` MCP response.

  The note body is returned verbatim (read-modify-write callers depend on it).
  Title/Tags are only injected as a convenience header when the body does not
  already carry them — a note's own frontmatter or leading `# H1` is the
  canonical source, so we don't repeat it (#731). Path/Folder are filesystem
  metadata that never live in the body, so they are always included.
  """
  def format_get_note(note) do
    content = note.content || ""
    fm = frontmatter_block(content)

    # Suppress an injected field only when the body actually carries it: a
    # frontmatter `title:`/`tags:` key, or (for the title) a body `# H1`.
    body_has_title = fm_has_key?(fm, "title") or body_has_h1?(content)
    inject_tags? = note.tags && note.tags != [] && not fm_has_key?(fm, "tags")

    title_lines = if body_has_title, do: [], else: ["# #{note.title}"]
    tag_lines = if inject_tags?, do: ["**Tags:** #{Enum.join(note.tags, ", ")}"], else: []

    (title_lines ++
       tag_lines ++
       ["**Path:** #{note.path}", "**Folder:** #{note.folder || ""}", "", content])
    |> Enum.join("\n")
  end

  # The YAML frontmatter block (content between the leading `---` fences), or nil.
  # Tolerates a leading BOM and CRLF line endings.
  defp frontmatter_block(content) do
    case Regex.run(~r/\A\x{FEFF}?---\r?\n(.*?)\r?\n---/su, content, capture: :all_but_first) do
      [fm] -> fm
      _ -> nil
    end
  end

  defp fm_has_key?(nil, _key), do: false
  defp fm_has_key?(fm, key), do: Regex.match?(~r/^\s*#{key}\s*:/mi, fm)

  # A level-1 ATX heading at the top of the body (after any frontmatter). `##`+
  # are subheadings, not the title.
  defp body_has_h1?(content) do
    content
    |> strip_frontmatter()
    |> String.trim_leading()
    |> then(&Regex.match?(~r/\A#(?!#)\s+/, &1))
  end

  defp strip_frontmatter(content),
    do: Regex.replace(~r/\A\x{FEFF}?---\r?\n.*?\r?\n---/su, content, "")
end
