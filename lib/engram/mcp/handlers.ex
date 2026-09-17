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
    # Structured as well as rendered (#1660). The empty case still carries
    # `vaults: []` rather than dropping the key — the outputSchema requires it,
    # and a client generating types from the schema would break on its absence.
    text =
      if vaults == [] do
        "No vaults are accessible with this connection."
      else
        Enum.map_join(vaults, "\n", fn v ->
          default = if v.is_default, do: " (default)", else: ""
          desc = if v.description, do: " — #{v.description}", else: ""
          "- **#{v.name}**#{default} (ID: #{v.id})#{desc}"
        end)
      end

    {:ok, text, %{"vaults" => Enum.map(vaults, &vault_payload/1)}}
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
           "vault-scoped tool call to target a vault. Call list_vaults to see the IDs.",
         %{"vault" => nil}}

      vault_id ->
        # `filter`, not `find`: two accessible vaults can share a display name
        # (#1665), and confirming the first would echo a UUID the caller did not
        # ask for. Every vault here is already scope-filtered, so naming the
        # candidates leaks nothing this connection cannot already list.
        case vaults_matching_ref(accessible, vault_id) do
          [] ->
            {:error,
             "Vault not found or not accessible: #{vault_id}. Call list_vaults to see the " <>
               "vaults this connection can use."}

          [_, _ | _] = many ->
            {:error,
             "#{length(many)} vaults are named #{vault_id}: " <>
               "#{Enum.map_join(many, ", ", &to_string(&1.id))}. Pass one of those UUIDs, " <>
               "or a slug — slugs are unique."}

          [v] ->
            {:ok,
             "Vault **#{v.name}** (ID: #{v.id}) is valid. Pass vault_id=\"#{v.id}\" on each " <>
               "tool call to target it — MCP stores no active vault between calls.",
             %{"vault" => vault_payload(v)}}
        end
    end
  end

  # -- Read tools --

  # Cross-vault default (no vault_id given): search every vault the credential
  # can reach at once and label each hit with its vault so the caller can follow
  # up (e.g. get_note) against the right one. `allow_cross_vault` bypasses the
  # Pro billing gate — multi-vault search is the MCP default on every tier
  # (product decision 2026-07-10).
  #
  # `vault_ids` is the privacy boundary, not an optimization: it becomes an
  # any-match Qdrant vault filter over exactly `vaults`, so a credential scoped
  # to a SUBSET can search that subset without seeing the vaults it was scoped
  # away from (#729). Without it `vault: nil` would drop the vault clause
  # entirely and search everything the user owns.
  def handle("search_notes", user, {:cross_vault, vaults}, args) do
    query = args["query"] || ""

    opts =
      Keyword.merge(build_search_opts(args),
        cross_vault: true,
        allow_cross_vault: true,
        vault_ids: Enum.map(vaults, &to_string(&1.id))
      )

    names = Map.new(vaults, &{to_string(&1.id), &1.name})
    render_search(Search.search(user, nil, query, opts), names)
  end

  def handle("search_notes", user, vault, args) do
    query = args["query"] || ""
    render_search(Search.search(user, vault, query, build_search_opts(args)), %{})
  end

  def handle("list_tags", user, vault, _args) do
    {:ok, tags} = Notes.list_tags_with_counts(user, vault)

    text =
      if tags == [] do
        "No tags found."
      else
        ["| Tag | Count |", "|-----|-------|"]
        |> Kernel.++(Enum.map(tags, fn t -> "| #{t.name} | #{t.count} |" end))
        |> Enum.join("\n")
      end

    # The empty case keeps the key rather than dropping it — see the same note
    # on list_vaults. A client generating types from the schema breaks on a
    # missing `tags`, and empty is the common first-run state.
    {:ok, text, %{"tags" => Enum.map(tags, &%{"name" => &1.name, "count" => &1.count})}}
  end

  def handle("list_folders", user, vault, _args) do
    {:ok, folders} = Notes.list_folders_with_counts(user, vault)

    text =
      if folders == [] do
        "No folders found."
      else
        ["| Folder | Notes |", "|--------|-------|"]
        |> Kernel.++(
          Enum.map(folders, fn f ->
            "| #{folder_label(f.folder)} | #{f.count} |"
          end)
        )
        |> Enum.join("\n")
      end

    # `folder` carries the RAW path, not the "(root)" label the table shows:
    # it is the value a client passes back to list_folder, and "(root)" is not
    # a folder. The label stays in the text rendering only.
    structured =
      Enum.map(folders, &%{"folder" => &1.folder || "", "count" => &1.count})

    {:ok, text, %{"folders" => structured}}
  end

  def handle("list_folder", user, vault, args) do
    folder = args["folder"] || ""

    with {:ok, notes} <- Notes.list_notes_in_folder(user, vault, folder),
         {:ok, atts} <- Engram.Attachments.list_in_folder(user, vault, folder) do
      render_folder({:ok, notes, atts}, folder)
    else
      error -> render_folder(error, folder)
    end
  end

  def handle("create_folder", user, vault, %{"folder" => folder}) when is_binary(folder) do
    case Notes.create_folder_marker(user, vault, folder) do
      {:ok, marker} ->
        {:ok, "Created folder: #{marker.folder}", %{"folder" => marker.folder}}

      {:error, :root_folder_not_marker} ->
        {:error, "folder must be a non-empty path"}

      {:error, atom} when is_atom(atom) ->
        {:error, "Failed: #{atom}"}

      {:error, _other} ->
        {:error, "Failed to create folder."}
    end
  end

  def handle("suggest_folder", user, vault, args) do
    description = args["description"] || ""
    limit = max(1, min(args["limit"] || 5, 10))

    case Search.search(user, vault, description, limit: 10, diversity: 0) do
      # A spent budget is a plan limit, not an empty vault. Without this the
      # refusal fell into the catch-all and reported "No folders found", which
      # tells the caller to give up rather than to upgrade.
      {:error, :search_cap_exceeded, cap} ->
        {:error, "ai_searches_per_day: daily limit of #{cap} reached"}

      {:ok, results} ->
        suggestions =
          results
          |> folder_counts()
          |> Enum.take(limit)
          |> Enum.with_index(1)
          |> Enum.map(fn {{folder, count}, rank} ->
            %{"rank" => rank, "folder" => folder, "count" => count}
          end)

        text =
          if suggestions == [] do
            "No folders found. The vault may be empty."
          else
            ["| Rank | Folder | Notes |", "|------|--------|-------|"]
            |> Kernel.++(
              Enum.map(suggestions, fn s ->
                "| #{s["rank"]} | #{folder_label(s["folder"])} | #{s["count"]} |"
              end)
            )
            |> Enum.join("\n")
          end

        {:ok, text, %{"suggestions" => suggestions}}

      # Was a catch-all that swallowed every search ERROR into "No folders
      # found. The vault may be empty." — an outage rendered as a fact about
      # the vault, which tells the caller to give up rather than retry.
      {:error, reason} ->
        log_and_error("suggest_folder", reason, "Folder suggestion unavailable.")
    end
  end

  def handle("get_note", user, vault, args) do
    source_path = args["source_path"] || ""

    case Notes.get_note(user, vault, source_path) do
      {:ok, note} ->
        {:ok, format_get_note(note), note_payload(note)}

      # Was `{:ok, "Note not found: ..."}`. The caller named one specific note;
      # not having it is a failed call, not a result. `get_notes` below is the
      # batch case and keeps per-path `found` flags instead, because a batch
      # that resolves some of its paths did succeed.
      {:error, :not_found} ->
        {:error, "Note not found: #{source_path}"}
    end
  end

  def handle("get_notes", user, vault, args) do
    paths = args["paths"] || []

    # `paths` being a list of strings is already enforced by the dispatch-level
    # schema validator (mcp_controller.ex). The two checks left are the ones the
    # schema does NOT declare: it has neither minItems nor maxItems.
    cond do
      paths == [] ->
        {:error, "paths must be a non-empty array"}

      length(paths) > 20 ->
        {:error, "Too many paths (max 20). Split into multiple calls."}

      true ->
        fetched =
          Enum.map(paths, fn path ->
            case Notes.get_note(user, vault, path) do
              {:ok, note} -> {path, note}
              {:error, :not_found} -> {path, nil}
            end
          end)

        body =
          Enum.map_join(fetched, "\n\n---\n\n", fn
            {_path, %{} = note} -> format_get_note(note)
            {path, nil} -> "Note not found: #{path}"
          end)

        notes =
          Enum.map(fetched, fn
            {_path, %{} = note} -> Map.put(note_payload(note), "found", true)
            {path, nil} -> %{"path" => path, "found" => false}
          end)

        {:ok, body, %{"notes" => notes}}
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

    Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => now()})
    |> upsert_reply(
      [
        ok: "Note created: #{path}",
        conflict: "Note changed on the server, retry: #{path}",
        deleted: "Note was deleted: #{path}",
        error: "Failed to create note: #{path}"
      ],
      %{"path" => path}
    )
  end

  def handle("write_note", user, vault, args) do
    path = args["path"] || ""
    content = args["content"] || ""

    # Same ceiling the REST upsert enforces with a 413, declared once in
    # `Notes` so the two transports cannot drift. Checked in the body, not a
    # guard: a guard cannot call a remote function.
    # Was `{:ok, "Error: note exceeds maximum size of 10MB"}` — a refusal whose
    # own text said "Error:" while the envelope said success.
    if byte_size(content) > Notes.max_note_bytes() do
      {:error, "note exceeds maximum size of 10MB"}
    else
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => now()})
      |> upsert_reply(
        [
          ok: "Note saved: #{path}",
          conflict: "Note changed on the server, retry: #{path}",
          deleted: "Note was deleted: #{path}",
          error: "Failed to save note: #{path}"
        ],
        %{"path" => path}
      )
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
        rmw_upsert(user, vault, path, fn content ->
          String.trim_trailing(content, "\n") <> "\n" <> text
        end)
        |> upsert_reply(
          [
            ok: "Note appended to: #{path}",
            conflict: "Note changed concurrently; retry: #{path}",
            error: "Failed to append to note: #{path}"
          ],
          %{"path" => path, "created" => false}
        )

      {:error, :not_found} ->
        content = "# #{Path.basename(path, ".md")}\n\n#{text}"

        Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => now()})
        |> upsert_reply(
          [
            ok: "Note created: #{path}",
            conflict: "Note changed on the server, retry: #{path}",
            deleted: "Note was deleted: #{path}",
            error: "Failed to create note: #{path}"
          ],
          %{"path" => path, "created" => true}
        )
    end
  end

  def handle("patch_note", user, vault, args) do
    path = args["path"] || ""
    find = args["find"] || ""
    replace = args["replace"] || ""
    occurrence = args["occurrence"] || 0

    # Read the AUTHORITY, not the `notes.content` façade: the façade lags a doc
    # write until checkpoint, so patching from it can commit an older body and
    # drop edits made since (#1159).
    with {:ok, note} <- Notes.get_note(user, vault, path),
         {:ok, current} <- Notes.authoritative_content(user, note) do
      if String.contains?(current, find) do
        {new_content, count} = do_replace(current, find, replace, occurrence)

        # `find` is present but the requested occurrence is past the last one,
        # so do_replace/4 returns the content untouched. Rewriting the note
        # with its own bytes and calling that success told the caller the patch
        # landed. Same rule as the "Text not found" branch below.
        if count == 0 do
          {:error, "Occurrence #{occurrence} not found in #{path}"}
        else
          patch_upsert(user, vault, path, note, new_content, count)
        end
      else
        # Nothing was replaced, so the patch did not happen. Was `:ok`.
        {:error, "Text not found in #{path}"}
      end
    else
      {:error, :not_found} -> {:error, "Note not found: #{path}"}
      {:error, reason} -> log_and_error("patch_note", reason, "Could not read #{path}; retry")
    end
  end

  def handle("update_section", user, vault, args) do
    path = args["path"] || ""
    heading = args["heading"] || ""
    new_content = args["content"] || ""
    level = args["level"] || 2

    # Same authority rule as patch_note: section surgery against the stale
    # `notes.content` façade would rewrite the note from an older body (#1159).
    with {:ok, note} <- Notes.get_note(user, vault, path),
         {:ok, current} <- Notes.authoritative_content(user, note) do
      prefix = String.duplicate("#", max(1, min(level, 6))) <> " "
      target = prefix <> heading
      lines = String.split(current, "\n")

      start_idx =
        Enum.find_index(lines, fn line ->
          String.trim(line) == String.trim(target)
        end)

      if start_idx == nil do
        # The section was not updated, so this is not a success. Was `:ok`.
        {:error, "Heading not found: #{target}"}
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

        Notes.upsert_note(user, vault, %{
          "path" => path,
          "content" => final_content,
          "mtime" => now(),
          "base_hash" => note.content_hash
        })
        |> upsert_reply(
          [
            ok: "Section '#{heading}' updated in #{path}",
            conflict: "Note changed concurrently; retry: #{path}",
            error: "Failed to update section in #{path}"
          ],
          %{"path" => path, "heading" => heading}
        )
      end
    else
      {:error, :not_found} -> {:error, "Note not found: #{path}"}
      {:error, reason} -> log_and_error("update_section", reason, "Could not read #{path}; retry")
    end
  end

  def handle("rename_note", user, vault, args) do
    old_path = args["old_path"] || ""
    new_path = args["new_path"] || ""

    case Notes.rename_note(user, vault, old_path, new_path) do
      {:ok, _note} ->
        {:ok, "Note renamed: #{old_path} -> #{new_path}",
         %{"old_path" => old_path, "new_path" => new_path}}

      {:error, :not_found} ->
        {:error, "Note not found: #{old_path}"}

      {:error, :conflict} ->
        {:error, "Note rename conflict: #{new_path} is already taken"}

      # Same catch-all as rename_folder below, and now load-bearing for a second
      # reason: rename_note/5 claims the path in the CRDT authority before
      # moving the row, so it can also surface :rotation_in_progress and
      # snapshot read/write failures. Without this clause every one of them is a
      # CaseClauseError → 500.
      {:error, reason} ->
        log_and_error("rename_note", reason, "Could not rename note: #{old_path}")
    end
  end

  def handle("rename_folder", user, vault, args) do
    old_folder = args["old_folder"] || ""
    new_folder = args["new_folder"] || ""

    case Engram.Folders.rename(user, vault, old_folder, new_folder) do
      {:ok, %{notes: n, attachments: a}} ->
        {:ok,
         "Folder renamed: #{old_folder} -> #{new_folder} " <>
           "(#{n} notes, #{a} attachments updated)",
         %{
           "old_folder" => old_folder,
           "new_folder" => new_folder,
           "notes" => n,
           "attachments" => a
         }}

      {:error, :conflict} ->
        {:error, "Folder rename conflict: #{new_folder} already exists"}

      # Catch-all (Bug 2): Folders.rename can surface a non-:conflict
      # {:error, reason} (e.g. a crypto failure in the attachment leg). Without
      # this clause it CaseClauseError'd → 500.
      {:error, reason} ->
        log_and_error("rename_folder", reason, "Could not rename folder: #{old_folder}")
    end
  end

  def handle("delete_note", user, vault, args) do
    path = args["path"] || ""

    # `delete_note/4` is idempotent and always returns :ok, so it cannot tell
    # us whether anything was there. The handler used to discard its result and
    # announce "Note deleted" either way. Probe first so the payload can say
    # which it was — the call still succeeds on a no-op, since an idempotent
    # delete of an absent note is not a failure.
    #
    # `note_exists?/3`, NOT `get_note/3`: the latter decrypts and raises on a
    # corrupt note, which would make a damaged note undeletable — the one case
    # where you most want the delete to work. `delete_note/4` itself never
    # decrypts, so the probe must not either.
    existed? = Notes.note_exists?(user, vault, path)
    :ok = Notes.delete_note(user, vault, path)

    text = if existed?, do: "Note deleted: #{path}", else: "No note at: #{path}"
    {:ok, text, %{"path" => path, "deleted" => existed?}}
  end

  def handle("delete_folder", user, vault, args) do
    folder = args["folder"] || ""
    recursive = args["recursive"] == true

    if folder == "" do
      {:error, "Refusing to delete the vault root."}
    else
      case Engram.Folders.delete(user, vault, folder, recursive: recursive) do
        {:ok, %{notes: n, attachments: a}} ->
          counts =
            if n == 0 and a == 0, do: "", else: " (#{n} notes, #{a} attachments removed)"

          {:ok, "Folder deleted: #{folder}#{counts}",
           %{"folder" => folder, "notes" => n, "attachments" => a}}

        # A refusal to act, not a completed delete. The caller must re-issue
        # with recursive: true, which it will not do if we report success.
        {:error, {:not_empty, %{notes: n, attachments: a}}} ->
          {:error,
           "Folder #{folder} contains #{n} notes and #{a} attachments. " <>
             "Pass recursive: true to delete them."}

        {:error, reason} ->
          log_and_error("delete_folder", reason, "Could not delete folder: #{folder}")
      end
    end
  end

  def handle("move_attachment", user, vault, args) do
    old_path = args["old_path"] || ""
    new_path = args["new_path"] || ""

    case Engram.Attachments.move_attachment(user, vault, old_path, new_path) do
      {:ok, _att} ->
        {:ok, "Attachment moved: #{old_path} -> #{new_path}",
         %{"old_path" => old_path, "new_path" => new_path}}

      {:error, :not_found} ->
        {:error, "Attachment not found: #{old_path}"}

      {:error, :conflict} ->
        {:error, "Attachment already exists at: #{new_path}"}

      # Plan gate, not a domain outcome: surface it as an MCP error so a client
      # can tell "your plan does not include this" from "that path is free".
      {:error, :feature_not_available} ->
        {:error, "attachments_enabled: not on your plan"}

      # Catch-all (Bug 2): move_attachment's crypto `with` head can return an
      # arbitrary {:error, reason}; without this clause it CaseClauseError'd → 500.
      {:error, reason} ->
        log_and_error("move_attachment", reason, "Could not move attachment: #{old_path}")
    end
  end

  def handle("get_attachment_upload_target", user, vault, _args) do
    base = attachment_api_base_url()
    max_bytes = render_limit(Engram.Billing.cap(user, :max_file_bytes))

    types =
      if Engram.Billing.attachments_all_types?(user),
        do: "images, PDFs, audio, video and other whitelisted binary types",
        else: "text/* only on this plan — images, PDFs, audio and video need a paid plan"

    {:ok,
     """
     Attachments are uploaded over the REST API, not through this tool: the bytes
     never pass through the model. POST the file yourself using the credential
     already authorizing this MCP connection.

     url:    #{base}/api/attachments
     method: POST

     headers:
       content-type: application/json
       authorization: Bearer <the same token this MCP connection uses>
       x-vault-id: #{vault.id}

     json body:
       path            required — vault-relative destination, e.g. _attachments/diagram.png
       content_base64  required — the file bytes, base64 encoded
       mime_type       optional — inferred from the path extension when omitted
       mtime           optional — unix timestamp

     limits for this account:
       max_bytes: #{max_bytes}
       allowed:   #{types}

     A 402 response means a plan limit was hit; the body names which one.
     """,
     %{
       "url" => "#{base}/api/attachments",
       "method" => "POST",
       "vault_id" => to_string(vault.id),
       # `max_bytes` renders as "unlimited" in the prose when the cap is
       # absent; the payload uses null rather than that string, so a client
       # comparing sizes never has to parse an English word.
       "max_bytes" => Engram.Billing.cap(user, :max_file_bytes),
       "all_types" => Engram.Billing.attachments_all_types?(user)
     }}
  end

  # No "unknown tool" clause: `Tools.get/1` gates dispatch in mcp_controller.ex,
  # which answers -32602 for a name that has no definition, so nothing can reach
  # this module with a name it doesn't implement.

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
      Enum.reduce(Search.date_params(), opts, fn key, acc ->
        put_date_opt(acc, key, args[to_string(key)])
      end)

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
  def search_mode(args), do: Search.parse_mode(args["mode"])

  # -- Private helpers --

  @doc false
  # Read-modify-write with compare-and-swap (Phase 0, identity-as-CRDT).
  # Declares the read row's content_hash as `base_hash` so a write landing
  # between the read and the upsert 409s instead of being deleted by the
  # full-content merge, then retries ONCE on a fresh read. `rebuild` receives
  # the current content and returns the new content. Public (doc: false) so
  # the CAS interleaving is unit-testable with a racing rebuild fun.
  def rmw_upsert(user, vault, path, rebuild, attempt \\ 0) do
    with {:ok, note} <- Notes.get_note(user, vault, path),
         # Rebuild from the AUTHORITY, not the `notes.content` façade. The façade
         # is materialized at checkpoint and lags a doc write, so rebuilding from
         # it can commit a shorter or older body (#1159). base_hash still guards
         # the concurrent-REST-write race, but it cannot detect façade lag:
         # content and content_hash go stale together.
         {:ok, current} <- Notes.authoritative_content(user, note) do
      case Notes.upsert_note(user, vault, %{
             "path" => path,
             "content" => rebuild.(current),
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
  def render_search({:ok, results}, names) do
    text =
      if results == [] do
        "No results found."
      else
        results
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {r, i} -> format_search_result(r, i, names) end)
      end

    {:ok, text, %{"results" => Enum.map(results, &search_payload(&1, names))}}
  end

  # A spent budget is a PLAN limit, not an outage. Naming the key lets a client
  # tell "upgrade" from "try again later", and matches the `limit_key` the REST
  # 402 carries for the same refusal.
  def render_search({:error, :search_cap_exceeded, limit}, _names),
    do: {:error, "ai_searches_per_day: daily limit of #{limit} reached"}

  # Was `{:ok, "Search unavailable."}` — an outage reported as success, which
  # no client could distinguish from a genuine zero-hit search, and which a
  # retry loop would never retry.
  def render_search({:error, _reason}, _names), do: {:error, "Search unavailable."}

  # Mirrors `format_search_result/3` field for field, so a client reading
  # structuredContent sees exactly what the markdown shows. `vault_id`/`vault`
  # are present only in cross-vault mode, matching the rendered label.
  defp search_payload(r, names) do
    %{
      "score" => r.score,
      "title" => r[:title],
      "heading_path" => r[:heading_path],
      "source_path" => r[:source_path],
      "tags" => r[:tags] || [],
      "text" => r.text
    }
    |> maybe_vault(r, names)
  end

  defp maybe_vault(payload, _r, names) when names == %{}, do: payload

  defp maybe_vault(payload, r, names) do
    id = r[:vault_id] && to_string(r.vault_id)

    Map.merge(payload, %{"vault_id" => id, "vault" => id && names[id]})
  end

  @doc false
  # Render list_folder output. Public (doc: false) so both branches — including
  # the failure one, which no fixture can force through Notes — are directly
  # testable, the same reason `render_search/2` is public.
  def render_folder({:ok, notes, atts}, folder) do
    label = folder_label(folder)

    text =
      if notes == [] and atts == [] do
        "No notes found in folder: #{label}"
      else
        header = [
          "**Folder:** #{label}",
          "",
          "| Title | Path | Tags |",
          "|-------|------|------|"
        ]

        note_rows =
          Enum.map(notes, fn n ->
            tags = if n.tags && n.tags != [], do: Enum.join(n.tags, ", "), else: ""
            "| #{n.title} | #{n.path} | #{tags} |"
          end)

        att_rows =
          Enum.map(atts, fn a -> "| #{Path.basename(a.path)} | #{a.path} | (attachment) |" end)

        Enum.join(header ++ note_rows ++ att_rows, "\n")
      end

    structured = %{
      # Raw path, not the "(root)" label — this is what a client echoes back.
      "folder" => folder,
      "notes" =>
        Enum.map(notes, fn n ->
          %{"title" => n.title, "path" => n.path, "tags" => n.tags || []}
        end),
      "attachments" =>
        Enum.map(atts, fn a -> %{"name" => Path.basename(a.path), "path" => a.path} end)
    }

    {:ok, text, structured}
  end

  # Was `{:ok, "Could not list folder ...#{inspect(reason)}"}` — a storage
  # failure reported as success, so no client could tell it from an empty
  # folder, and the reason was `inspect/1`ed into the response body. The
  # reason is logged, not returned: it originates deep in Notes/Attachments
  # and can carry decrypted struct fields.
  def render_folder({:error, reason}, folder) do
    require Logger

    Logger.error(
      "mcp list_folder failed",
      Engram.Logger.Metadata.with_category(:error, :http,
        reason_label: Engram.Telemetry.error_kind(reason)
      )
    )

    {:error, "Could not list folder: #{folder_label(folder)}"}
  end

  defp folder_label(folder) when folder in ["", nil], do: "(root)"
  defp folder_label(folder), do: folder

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

  # The one `Notes.upsert_note` result ladder for this module. Two of its
  # clauses are load-bearing and were easy to omit when every write site spelled
  # the ladder out for itself:
  #
  #   * `{:error, :version_conflict, note}` is a 3-TUPLE. `{:error, reason}`
  #     does not match it, so without its own clause a contended write raises
  #     CaseClauseError instead of reporting. #1335 made it reachable for
  #     callers that declare no base_hash, which is all of MCP.
  #   * `:note_deleted` is a distinct outcome, not a generic failure. Callers
  #     that name a `:deleted` message report it as one; the rest fold it into
  #     `:error`, exactly as their own ladders did.
  # Every failure here used to come back as `{:ok, apologetic_sentence}` — a
  # write that did not happen, reported as one that did. A model reading only
  # `isError` had no way to tell a landed write from a version conflict, so it
  # moved on instead of retrying. #1660 flips them; `structured` rides along on
  # the success branch to satisfy the outputSchema promise.
  defp upsert_reply(result, msgs, structured) do
    case result do
      {:ok, _note} -> {:ok, msgs[:ok], structured}
      {:error, :version_conflict, _note} -> {:error, msgs[:conflict]}
      {:error, :note_deleted} -> {:error, msgs[:deleted] || msgs[:error]}
      {:error, _reason} -> {:error, msgs[:error]}
    end
  end

  defp patch_upsert(user, vault, path, note, new_content, count) do
    Notes.upsert_note(user, vault, %{
      "path" => path,
      "content" => new_content,
      "mtime" => now(),
      "base_hash" => note.content_hash
    })
    |> upsert_reply(
      [
        ok: "Replaced #{count} occurrence(s) in #{path}",
        conflict: "Note changed concurrently; retry: #{path}",
        error: "Failed to patch note: #{path}"
      ],
      %{"path" => path, "replacements" => count}
    )
  end

  # A reason from deep in Notes/Folders/Attachments can carry decrypted struct
  # fields, so it is logged with a low-cardinality label and never rendered
  # into the response. Replaces four `inspect(reason)`-into-the-body sites.
  defp log_and_error(op, reason, message) do
    require Logger

    Logger.error(
      "mcp #{op} failed",
      Engram.Logger.Metadata.with_category(:error, :http,
        tool: op,
        reason_label: Engram.Telemetry.error_kind(reason)
      )
    )

    {:error, message}
  end

  # Search hits → `{folder, count}` sorted by descending count. Shared by
  # suggest_folder (which takes the top N) and auto_place_folder (the head).
  defp folder_counts(results) do
    results
    |> Enum.map(&Engram.Notes.Helpers.extract_folder(&1[:source_path] || ""))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_f, c} -> -c end)
  end

  defp auto_place_folder(user, vault, title, content) do
    query =
      "#{title} #{String.slice(content, 0, 300)}" |> String.replace("\n", " ") |> String.trim()

    if query == "" do
      ""
    else
      # Degrades on an empty budget instead of failing the write. This search
      # IS charged — it costs a Voyage embed and a Qdrant query like any other,
      # and leaving it free made the write path an unmetered search channel.
      # But auto-placement is incidental to creating a note, so a spent budget
      # drops the note in the default folder rather than refusing the create.
      case Search.search(user, vault, query, limit: 10, diversity: 0) do
        {:ok, results} when results != [] ->
          case folder_counts(results) do
            [{folder, _} | _] -> folder
            _ -> ""
          end

        # Also the `{:error, :search_cap_exceeded, _}` path, deliberately.
        # `""` means "no suggestion", so a spent budget drops the note in the
        # default folder instead of failing the create — auto-placement is
        # incidental to a write. The search IS charged either way: it costs a
        # Voyage embed and a Qdrant query like any other, and leaving it
        # uncharged made the write path an unmetered search channel.
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

    # One parse for both halves. `Frontmatter.split/1` returns {block | nil,
    # body} and already handles the edge cases the regexes here used to miss
    # (closing fence at EOF, CRLF, empty block). Stripping a leading BOM is the
    # only thing this call site adds over it.
    {fm, body} = content |> String.replace_prefix("﻿", "") |> Engram.Notes.Frontmatter.split()

    # Suppress an injected field only when the body actually carries it: a
    # frontmatter `title:`/`tags:` key, or (for the title) a body `# H1`.
    body_has_title = fm_has_key?(fm, "title") or body_has_h1?(body)
    inject_tags? = note.tags && note.tags != [] && not fm_has_key?(fm, "tags")

    title_lines = if body_has_title, do: [], else: ["# #{note.title}"]
    tag_lines = if inject_tags?, do: ["**Tags:** #{Enum.join(note.tags, ", ")}"], else: []

    (title_lines ++
       tag_lines ++
       ["**Path:** #{note.path}", "**Folder:** #{note.folder || ""}", "", content])
    |> Enum.join("\n")
  end

  defp fm_has_key?(nil, _key), do: false
  defp fm_has_key?(fm, key), do: Regex.match?(~r/^\s*#{key}\s*:/mi, fm)

  # A level-1 ATX heading at the top of the body (frontmatter already split
  # off by the caller). `##`+ are subheadings, not the title.
  defp body_has_h1?(body), do: Regex.match?(~r/\A#(?!#)\s+/, String.trim_leading(body))

  # The upload URL must name the REST host, which on SaaS is NOT the host this
  # MCP request arrived on: `mcp.engram.page` routes to the MCP endpoint and
  # does not serve REST (see `EngramWeb.Plugs.HostRewrite`). Deriving it from
  # the conn would advertise an endpoint that cannot accept an upload.
  #
  # Self-host sets no rewrite and serves everything canonically, so the
  # endpoint URL is correct there. One code path, every deployment shape.
  defp attachment_api_base_url do
    canonical = EngramWeb.Endpoint.url()

    with opts when is_list(opts) <- Application.get_env(:engram, :host_rewrite),
         host when is_binary(host) and host != "" <- opts[:api_host] do
      "#{URI.parse(canonical).scheme}://#{host}"
    else
      _ -> canonical
    end
  end

  # `Billing.cap/2` collapses all three "no cap" spellings (`nil`, `:unlimited`,
  # `-1`) to nil before this sees them — rendering `-1` literally used to
  # advertise a negative byte cap, which a model reads as "uploads are
  # disabled". Anything else, including a corrupt negative, stays visible
  # rather than being silently laundered into "unlimited".
  defp render_limit(n) when is_integer(n), do: to_string(n)
  # nil (no cap) or a malformed override — `to_string/1` on a map raises
  # Protocol.UndefinedError, which would take out the whole tool call. This
  # string is advisory: the enforcing gate is
  # `Engram.Attachments.validate_max_file_bytes/2`, which fails CLOSED, so an
  # over-permissive number here cannot let an oversized upload through.
  defp render_limit(_), do: "unlimited"

  # Mirrors what `Vaults.get_vault_by_ref/2` does for every other vault-scoped
  # tool: a UUID matches by id, anything else is slugified and matched against
  # the slug. Done against the already-loaded accessible list rather than by
  # calling that function, so the scope filter stays the only source of truth
  # for what this connection may see.
  # Mirrors `Vaults.get_vault_by_ref/2`'s precedence exactly — UUID, then exact
  # display name, then slug — because `set_vault` resolves against the
  # already-scoped list instead of going through that function, and the two
  # disagreeing is what teaches a model that names are unreliable.
  #
  # Name before slug is load-bearing (#1665): with vaults "Test Vault"
  # (slug `test-vault`) and "Test-Vault" (slug `test-vault-2`), the ref
  # "Test-Vault" slugifies onto the FIRST vault's slug while being the second's
  # exact name. Slug-first would confirm the wrong vault.
  #
  # `slugify_ref/1`, not `slugify/1`: the latter substitutes the literal "vault"
  # for a ref that reduces to nothing, which would match the "vault"-slugged
  # vault for any junk input.
  #
  # Returns every match so the caller can refuse an ambiguous one rather than
  # taking the first. `name` is nil when decryption failed, which matches
  # nothing — correct, since an unreadable name cannot have been referenced.
  defp vaults_matching_ref(accessible, ref) do
    ref = to_string(ref)

    by_slug =
      case Engram.Vaults.slugify_ref(ref) do
        {:ok, slug} -> Enum.filter(accessible, &(&1.slug == slug))
        :error -> []
      end

    cond do
      (ids = Enum.filter(accessible, &(to_string(&1.id) == ref))) != [] -> ids
      (named = Enum.filter(accessible, &(&1.name == ref))) != [] -> named
      true -> by_slug
    end
  end

  # Mirrors the header `format_get_note/1` injects, minus the rendering: the
  # markdown suppresses an injected title/tags when the body already carries
  # them, but the payload always states them — a client reading structured
  # output should not have to parse frontmatter to learn a note's title.
  defp note_payload(note) do
    %{
      "path" => note.path,
      "title" => note.title,
      "folder" => note.folder || "",
      "tags" => note.tags || [],
      "content" => note.content || ""
    }
  end

  defp vault_payload(v) do
    %{
      "id" => to_string(v.id),
      "name" => v.name,
      "slug" => v.slug,
      "is_default" => v.is_default,
      "description" => v.description
    }
  end
end
