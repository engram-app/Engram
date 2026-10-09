defmodule Engram.MCP.Handlers do
  @moduledoc """
  MCP tool handler implementations.
  Each function takes (user, vault, args) and returns a markdown-formatted string.
  """

  alias Engram.MCP.{ParseGate, Sections}
  alias Engram.{Notes, Repo, Search}
  alias Engram.Notes.Frontmatter

  # #1710: every MCP note write is the "mcp" history actor. The
  # HandlersWriteActorTest counts that every upsert_note call passes this.
  @too_large "note would exceed the maximum size of 10MB"
  @write_opts [actor: "mcp"]

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
          desc = if v.description, do: ": #{v.description}", else: ""
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
               "or a slug; slugs are unique."}

          [v] ->
            {:ok,
             "Vault **#{v.name}** (ID: #{v.id}) is valid. Pass vault_id=\"#{v.id}\" on each " <>
               "tool call to target it; MCP stores no active vault between calls.",
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
    names = Map.new(vaults, &{to_string(&1.id), &1.name})

    opts =
      Keyword.merge(build_search_opts(args),
        cross_vault: true,
        allow_cross_vault: true,
        vault_ids: Enum.map(vaults, &to_string(&1.id))
      )

    case search_kind(args) do
      {:ok, :recent} ->
        limit = max(1, min(args["limit"] || 5, 20))

        vaults
        |> Enum.flat_map(fn v ->
          {:ok, notes} = Notes.list_recent_notes(user, v, limit)
          Enum.map(notes, &{&1, v})
        end)
        |> Enum.sort_by(fn {n, _v} -> n.updated_at end, {:desc, DateTime})
        |> Enum.take(limit)
        |> render_recent(names)

      {:ok, :query} ->
        render_search(Search.search(user, nil, args["query"], opts), names)

      {:ok, :similar} ->
        path = args["similar_to"]

        with {:ok, note} <- similar_source(user, vaults, path),
             {:ok, ids} <- stored_points(note, path) do
          render_similar(Search.similar(user, nil, ids, opts), names, note, path)
        end

      {:error, _} = err ->
        err
    end
  end

  def handle("search_notes", user, vault, args) do
    case search_kind(args) do
      {:ok, :recent} ->
        {:ok, notes} = Notes.list_recent_notes(user, vault, max(1, min(args["limit"] || 5, 20)))
        render_recent(Enum.map(notes, &{&1, vault}), %{})

      {:ok, :query} ->
        render_search(Search.search(user, vault, args["query"], build_search_opts(args)), %{})

      {:ok, :similar} ->
        path = args["similar_to"]

        with {:ok, note} <- similar_source(user, [vault], path),
             {:ok, ids} <- stored_points(note, path) do
          render_similar(
            Search.similar(user, vault, ids, build_search_opts(args)),
            %{},
            note,
            path
          )
        end

      {:error, _} = err ->
        err
    end
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
    recursive? = args["recursive"] || false

    # `list_folders_with_counts/2` aggregates the WHOLE vault, not just
    # `folder`'s children — one query per call regardless of folder depth,
    # then `subfolders/3` slices it down in BEAM.
    with {:ok, notes} <- Notes.list_notes_in_folder(user, vault, folder),
         {:ok, atts} <- Engram.Attachments.list_in_folder(user, vault, folder),
         {:ok, all_folders} <- Notes.list_folders_with_counts(user, vault) do
      render_folder({:ok, notes, atts, subfolders(all_folders, folder, recursive?)}, folder)
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
    section = args["section"]
    outline? = args["outline"] == true

    # `paths` being a list of strings is already enforced by the dispatch-level
    # schema validator (mcp_controller.ex). The checks left are the ones the
    # schema does NOT declare.
    cond do
      paths == [] ->
        {:error, "paths must be a non-empty array"}

      length(paths) > 20 ->
        {:error, "Too many paths (max 20). Split into multiple calls."}

      is_binary(section) and outline? ->
        {:error, "Pass section or outline, not both"}

      is_binary(section) and String.trim(section) == "" ->
        {:error, "section must name a heading, e.g. \"Todo\""}

      is_binary(section) and length(paths) > 1 ->
        {:error, "section reads one note at a time; pass a single path"}

      true ->
        fetch = fn path ->
          case Notes.get_note(user, vault, path) do
            {:ok, note} -> note
            {:error, :not_found} -> nil
          end
        end

        # One parse deadline for the whole call, across every path.
        gate = ParseGate.call_opts()
        links? = args["include_links"] == true

        if is_binary(section) do
          # Section reads take one path, so fetching it up front is fine.
          with {:ok, [{path, note}]} <-
                 narrow_to_section([{hd(paths), fetch.(hd(paths))}], section, gate),
               do: render_notes(user, [{path, fn -> note end}], outline?, links?, gate)
        else
          # Fetched one at a time as each entry renders, so a note's content
          # is released once its entry is built (20 x 10 MB held at once was
          # ~200 MB before the reply was even assembled).
          render_notes(user, Enum.map(paths, &{&1, fn -> fetch.(&1) end}), outline?, links?, gate)
        end
    end
  end

  # -- Write tools --

  def handle("create_note", user, vault, args) do
    title = title(args)
    content = args["content"] || ""

    folder =
      explicit_folder(args) ||
        Map.get_lazy(args, :placed_folder, fn ->
          auto_place_folder(user, vault, title, content)
        end)

    filename = String.replace(title, "/", "-") <> ".md"
    path = if folder != "", do: "#{folder}/#{filename}", else: filename

    content =
      if String.starts_with?(String.trim(content), "# ") do
        content
      else
        "# #{title}\n\n#{content}"
      end

    # create_note is advertised non-destructive, so it must never replace a note
    # at its derived path. Upsert sanitizes the path, so check the same form.
    # ponytail: check-then-write, two concurrent creates of one title can still
    # race; a create-only mode on upsert_note closes it if that ever matters.
    if Notes.note_exists?(user, vault, Notes.PathSanitizer.sanitize(path)) do
      {:error,
       "A note already exists at #{path}. Use get_notes to read it, or write_note " <>
         "to replace it, or pick a different title."}
    else
      Notes.upsert_note(
        user,
        vault,
        %{"path" => path, "content" => content, "mtime" => now()},
        @write_opts
      )
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
      Notes.upsert_note(
        user,
        vault,
        %{"path" => path, "content" => content, "mtime" => now()},
        @write_opts
      )
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

    with {:ok, position} <- resolve_append_position(args["position"]) do
      # The frontmatter-misparse guard runs INSIDE rebuild, so it checks the
      # content rmw_upsert actually rebuilds from (the locked row's).
      rebuild = fn content ->
        case guard_start_frontmatter_safety(position, content, text) do
          :ok -> place_text(content, text, position)
          {:error, _msg} = error -> error
        end
      end

      # One transaction (re-entrant inside the MCP request's): a miss returns
      # with the vault lock held, so the create below cannot race another.
      Repo.with_tenant!(user.id, fn -> append_or_create(user, vault, path, text, rebuild) end)
    end
  end

  def handle("patch_note", user, vault, args) do
    path = args["path"] || ""
    find = args["find"] || ""
    replace = args["replace"] || ""
    occurrence = args["occurrence"] || 0

    patch_text(
      user,
      vault,
      path,
      %{find: find, replace: replace, occurrence: occurrence},
      nil,
      "patch_note"
    )
  end

  def handle("update_section", user, vault, args) do
    path = args["path"] || ""
    heading = args["heading"] || ""
    new_content = args["content"] || ""
    level = args["level"] || 2

    replace_section(user, vault, path, heading, new_content, level, "update_section")
  end

  @text_params ~w(find replace occurrence expected_replacements old_text new_text)
  @section_params ~w(heading content level)

  def handle("edit_note", user, vault, %{"mode" => mode} = args) do
    path = args["path"] || ""

    with :ok <- reject_other_mode(args, mode) do
      run_edit(user, vault, path, mode, args)
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

    # The payload says whether anything was there; the call still succeeds on
    # a no-op, since an idempotent delete of an absent note is not a failure.
    # `delete_note_reporting/3` never decrypts, so a damaged note stays
    # deletable (the one case where you most want the delete to work).
    existed? = Notes.delete_note_reporting(user, vault, path) == :deleted

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
        else: "text/* only on this plan; images, PDFs, audio and video need a paid plan"

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
       path            required: vault-relative destination, e.g. _attachments/diagram.png
       content_base64  required: the file bytes, base64 encoded
       mime_type       optional: inferred from the path extension when omitted
       mtime           optional: unix timestamp

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

  # -- edit_note (replaces patch_note / update_section) --

  defp reject_other_mode(args, "replace_text") do
    with :ok <- reject_params(args, @section_params, "replace_section or insert_section"),
         do: reject_params(args, ["position"], "insert_section")
  end

  defp reject_other_mode(args, "replace_section") do
    with :ok <- reject_params(args, @text_params, "replace_text"),
         do: reject_params(args, ["position"], "insert_section")
  end

  defp reject_other_mode(args, "insert_section"),
    do: reject_params(args, @text_params, "replace_text")

  defp reject_other_mode(_args, mode),
    do:
      {:error,
       "mode must be replace_text, replace_section or insert_section, got #{inspect(mode)}"}

  # A strict-schema client (OpenAI strict mode) sends every declared property
  # on every call, nulling out the ones it isn't using. `validate_tool_args/2`
  # already lets an explicit `null` through for an optional key, so `Map.has_key?`
  # alone treated that as a stray cross-mode param and edit_note would refuse
  # EVERY such call. Only a present, non-nil value from the other mode is
  # actually a mistake.
  defp reject_params(args, params, owner) do
    case Enum.find(params, &(Map.has_key?(args, &1) and not is_nil(Map.get(args, &1)))) do
      nil -> :ok
      p -> {:error, "#{p} is only valid with mode #{owner}"}
    end
  end

  defp run_edit(user, vault, path, "replace_text", args) do
    find = args["find"] || args["old_text"]
    replace = args["replace"] || args["new_text"]

    cond do
      is_nil(find) ->
        {:error, "find is required for mode replace_text"}

      not is_binary(find) ->
        {:error, "find must be a string"}

      not is_binary(replace) ->
        {:error, "replace is required for mode replace_text"}

      true ->
        user
        |> patch_text(
          vault,
          path,
          %{find: find, replace: replace, occurrence: args["occurrence"] || 0},
          args["expected_replacements"],
          "edit_note"
        )
        |> tag_mode("replace_text", %{"heading" => nil})
    end
  end

  defp run_edit(user, vault, path, "replace_section", args) do
    cond do
      not is_binary(args["heading"]) ->
        {:error, "heading is required for mode replace_section"}

      not is_binary(args["content"]) ->
        {:error, "content is required for mode replace_section"}

      true ->
        user
        |> replace_section(
          vault,
          path,
          args["heading"],
          args["content"],
          args["level"] || 2,
          "edit_note"
        )
        |> tag_mode("replace_section", %{"replacements" => nil})
    end
  end

  defp run_edit(user, vault, path, "insert_section", args) do
    level = args["level"] || 2

    cond do
      not is_binary(args["heading"]) ->
        {:error, "heading is required for mode insert_section"}

      not is_binary(args["content"]) or String.trim(args["content"]) == "" ->
        {:error, "content is required for mode insert_section"}

      level < 1 or level > 6 ->
        {:error, "level must be between 1 and 6"}

      true ->
        with {:ok, position} <- resolve_insert_position(args["position"]) do
          user
          |> insert_section(vault, path, args["heading"], level, position, args["content"])
          |> tag_mode("insert_section", %{"replacements" => nil})
        end
    end
  end

  defp resolve_insert_position(nil), do: {:ok, "end"}
  defp resolve_insert_position(p) when p in ["start", "end"], do: {:ok, p}
  defp resolve_insert_position(_), do: {:error, "position must be start or end"}

  # Through rmw_upsert: the rebuild runs against the authority (#1159) of the
  # locked row, and a missing heading refuses inside it, so nothing is written.
  defp insert_section(user, vault, path, heading, level, position, text) do
    gate = ParseGate.call_opts()

    rebuild = fn current ->
      case Sections.insert(current, heading, level, position, text, gate) do
        {:ok, updated} ->
          updated

        {:error, reason} ->
          {:error, section_error(heading, reason)}

        :error ->
          {:error, "Heading not found: #{String.duplicate("#", level)} #{heading}"}
      end
    end

    case rmw_upsert(user, vault, path, rebuild) do
      {:error, :not_found} ->
        {:error, "Note not found: #{path}"}

      result ->
        upsert_reply(
          result,
          [
            ok: "Inserted at the #{position} of section '#{heading}' in #{path}",
            conflict: "Note changed concurrently; retry: #{path}",
            error: "Failed to update section in #{path}"
          ],
          %{"path" => path, "heading" => heading}
        )
    end
  end

  # Every fixable refusal from Engram.MCP.Sections, as the message the
  # caller sees. `line` is 0-indexed internally (Sections works in line
  # indices); report it 1-indexed, matching how a human (or Obsidian) counts.
  defp section_error(heading, {:hidden_heading, line}) do
    "Section '#{heading}' may run past line #{line + 1}, which looks like a heading but is " <>
      "hidden (by an unclosed code block, HTML block or %% comment); close it or edit with " <>
      "replace_text"
  end

  defp section_error(heading, :ambiguous),
    do: "Heading '#{heading}' matches several headings; pass the exact heading text"

  defp section_error(_heading, :busy),
    do: "The server is busy parsing other notes; try again shortly"

  defp section_error(_heading, reason) when reason in [:parse_timeout, :too_complex] do
    "This note is too complex to parse for section edits or outline; edit with replace_text " <>
      "or read it with get_notes without section/outline"
  end

  defp section_error(_heading, :deadline) do
    "This request ran out of time before this note could be parsed; try again shortly, " <>
      "or with fewer paths"
  end

  defp section_error(_heading, :parse_failed),
    do: "Parsing this note failed; edit with replace_text"

  defp section_error(_heading, :invalid_utf8),
    do: "This note contains invalid UTF-8; use edit_note replace_text"

  defp tag_mode({:ok, text, structured}, mode, blanks),
    do: {:ok, text, structured |> Map.merge(blanks) |> Map.put("mode", mode)}

  defp tag_mode(other, _mode, _blanks), do: other

  # Read the AUTHORITY, not the `notes.content` façade: the façade lags a doc
  # write until checkpoint, so patching from it can commit an older body and
  # drop edits made since (#1159).
  #
  # Both guards below are shared with the hidden `patch_note` alias, which
  # calls this function directly (bypassing run_edit's cond entirely). They
  # used to live only in run_edit, which left patch_note free to send the
  # same corrupting input:
  #   - `find == ""` passes is_binary and String.contains?/2 (every string
  #     contains ""), so do_replace/4 happily prepends (occurrence 0) or
  #     interleaves (occurrence -1) empty "replacements" and reports success —
  #     a write that corrupts the note while claiming to have worked.
  #   - `occurrence` has no schema minimum, so e.g. -2 reaches do_replace/4's
  #     second clause, where `Enum.take(parts, occurrence + 1)` gets a
  #     NEGATIVE count. Enum.take/drop silently read from the END of the list
  #     for a negative count instead of refusing, so the "replace" landed at
  #     the wrong position and the write reported success.
  defp patch_text(
         user,
         vault,
         path,
         %{find: find, replace: replace, occurrence: occurrence},
         expected,
         op
       ) do
    cond do
      find == "" ->
        {:error, "find must not be empty for mode replace_text"}

      occurrence != -1 and occurrence < 0 ->
        {:error, "occurrence must be -1 (all) or 0 or greater"}

      true ->
        do_patch_text(user, vault, path, find, replace, occurrence, expected, op)
    end
  end

  defp do_patch_text(user, vault, path, find, replace, occurrence, expected, op) do
    rebuild = fn current -> patched_text(current, path, {find, replace, occurrence}, expected) end

    case rmw(user, vault, path, rebuild) do
      {{:error, :not_found} = e, _} ->
        read_error(e, op, path)

      {{:error, {:authority, reason}}, _} ->
        read_error({:error, reason}, op, path)

      {result, count} ->
        upsert_reply(
          result,
          [
            ok: "Replaced #{count} occurrence(s) in #{path}",
            conflict: "Note changed concurrently; retry: #{path}",
            error: "Failed to patch note: #{path}"
          ],
          %{"path" => path, "replacements" => count}
        )
    end
  end

  # The patch as a rebuild: `{new_text, count}` or `{:error, message}`.
  defp patched_text(current, path, {find, replace, occurrence}, expected) do
    hits = count_matches(current, find, 0, 0)
    replaced = if occurrence == -1, do: hits, else: min(hits, 1)
    grown = byte_size(current) + replaced * (byte_size(replace) - byte_size(find))

    cond do
      # Nothing was replaced, so the patch did not happen. Was `:ok`.
      hits == 0 ->
        {:error, "Text not found in #{path}"}

      grown > Notes.max_note_bytes() ->
        {:error, @too_large}

      true ->
        {new_content, count} = do_replace(current, find, replace, occurrence)

        # `find` is present but the requested occurrence is past the last one,
        # so do_replace/4 returns the content untouched. Rewriting the note with
        # its own bytes and calling that success told the caller the patch
        # landed. Same rule as the "Text not found" branch above.
        cond do
          count == 0 ->
            {:error, "Occurrence #{occurrence} not found in #{path}"}

          is_integer(expected) and expected != count ->
            {:error,
             "expected #{expected} replacement(s), found #{count} in #{path}; nothing was changed"}

          true ->
            {new_content, count}
        end
    end
  end

  defp read_error({:error, :not_found}, _op, path), do: {:error, "Note not found: #{path}"}

  defp read_error({:error, reason}, op, path),
    do: log_and_error(op, reason, "Could not read #{path}; retry")

  # Non-overlapping, left to right (String.split/2's count), without building
  # the parts: the size check runs before anything the size of the result.
  defp count_matches(content, find, from, n) do
    case :binary.match(content, find, scope: {from, byte_size(content) - from}) do
      {at, len} -> count_matches(content, find, at + len, n + 1)
      :nomatch -> n
    end
  end

  # Same authority rule as patch_text: section surgery against the stale
  # `notes.content` façade would rewrite the note from an older body (#1159).
  #
  # Shared with the hidden `update_section` alias, which calls this function
  # directly. The heading-match prefix used to clamp `level` to 1..6
  # (`max(1, min(level, 6))`) while the section-END scan below compared
  # against the RAW `level` — so level 0 (or > 6) never satisfied
  # `h_level <= level` for any real heading, the end of the section was never
  # found, and every following section got swallowed into the replacement.
  # Refusing the out-of-range level outright (before any heading search)
  # removes the mismatch instead of also clamping the end-scan to match.
  # The finder (`Engram.MCP.Sections.find/3`) is a CommonMark parser;
  # the level guard still refuses 0 or 7+ before any lookup.
  defp replace_section(_user, _vault, _path, _heading, _new_content, level, _op)
       when level < 1 or level > 6 do
    {:error, "level must be between 1 and 6"}
  end

  defp replace_section(user, vault, path, heading, new_content, level, op) do
    rebuild = fn current -> replaced_section(current, heading, new_content, level) end

    case rmw(user, vault, path, rebuild) do
      {{:error, :not_found} = e, _} ->
        read_error(e, op, path)

      {{:error, {:authority, reason}}, _} ->
        read_error({:error, reason}, op, path)

      {result, _} ->
        upsert_reply(
          result,
          [
            ok: "Section '#{heading}' updated in #{path}",
            conflict: "Note changed concurrently; retry: #{path}",
            error: "Failed to update section in #{path}"
          ],
          %{"path" => path, "heading" => heading}
        )
    end
  end

  # The section replacement as a rebuild: the new text or `{:error, message}`.
  defp replaced_section(current, heading, new_content, level) do
    case Sections.find(current, heading, level, ParseGate.call_opts()) do
      :error ->
        # The section was not updated, so this is not a success. Was `:ok`.
        {:error, "Heading not found: #{String.duplicate("#", level)} #{heading}"}

      {:error, reason} ->
        {:error, section_error(heading, reason)}

      # Defense in depth: a heading-shaped line inside the section is not a
      # heading in the parse (an unclosed block or %% comment hid it), so
      # `stop` may not be a real section boundary. Replacing through it
      # could silently delete what was hidden. Refuse; write nothing.
      {:ok, %{hidden_heading_at: line}} when is_integer(line) ->
        {:error, section_error(heading, {:hidden_heading, line})}

      {:ok, %{start: s, stop: e, span: span}} ->
        lines = String.split(current, "\n")
        replacement = String.trim_trailing(new_content, "\n")

        # `s + span` keeps the whole heading: span is 2+ for a setext
        # heading (every paragraph line plus the underline), 1 for ATX.
        # splice_eol/5 keeps the CRLF conversion LOCAL to `replacement`
        # (and the one boundary line next to it, if replacing lands at end
        # of file with no trailing newline) -- it never touches any other
        # line in the note.
        {lines, replacement} = Sections.splice_eol(lines, s + span, e, replacement, current)

        final_content =
          (Enum.slice(lines, 0, s + span) ++
             [replacement] ++ Enum.drop(lines, e))
          |> Enum.join("\n")

        final_content
    end
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

  defp append_or_create(user, vault, path, text, rebuild) do
    case rmw_upsert(user, vault, path, rebuild) do
      {:error, :not_found} ->
        content = "# #{Path.basename(path, ".md")}\n\n#{text}"

        Notes.upsert_note(
          user,
          vault,
          %{
            "path" => path,
            "content" => content,
            "mtime" => now()
          },
          @write_opts
        )
        |> upsert_reply(
          [
            ok: "Note created: #{path}",
            conflict: "Note changed on the server, retry: #{path}",
            deleted: "Note was deleted: #{path}",
            error: "Failed to create note: #{path}"
          ],
          %{"path" => path, "created" => true}
        )

      result ->
        upsert_reply(
          result,
          [
            ok: "Note appended to: #{path}",
            conflict: "Note changed concurrently; retry: #{path}",
            error: "Failed to append to note: #{path}"
          ],
          %{"path" => path, "created" => false}
        )
    end
  end

  @doc false
  # Read-modify-write through `Notes.rmw_note/5` (optimistic unlocked rebuild,
  # then a locked recompute if the row moved). `rebuild` receives the current
  # content and returns the new content (a binary), OR `{:error, reason}` to
  # refuse the write entirely: rmw_upsert returns that error as-is and writes
  # nothing. Returns `{:error, :not_found}` for a missing note, with the vault
  # lock held until the caller's transaction ends. Public (doc: false) for tests.
  def rmw_upsert(user, vault, path, rebuild) do
    case rmw(user, vault, path, rebuild) do
      {{:error, {:authority, reason}}, _} -> {:error, reason}
      {result, _meta} -> result
    end
  end

  defp rmw(user, vault, path, rebuild),
    do: Notes.rmw_note(user, vault, path, rebuild, [mtime: now()] ++ @write_opts)

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

  @search_filters ~w(tags folder type created_after created_before updated_after updated_before)

  # `:recent` when query is blank AND similar_to is absent. `similar_to` and a
  # non-blank query never combine: naming a source note AND asking a question
  # is an ambiguous request, not a widened one. A blank query plus a ranking
  # filter is a fixable error, not a silently-ignored one: the recent listing
  # is unfiltered, so honoring the call would silently return the wrong answer
  # to a filtered ask.
  defp search_kind(args) do
    similar = args["similar_to"]
    blank? = String.trim(args["query"] || "") == ""

    cond do
      is_binary(similar) and not blank? ->
        {:error, "Pass query or similar_to, not both"}

      is_binary(similar) and String.trim(similar) == "" ->
        {:error, "similar_to must be a note path"}

      is_binary(similar) ->
        {:ok, :similar}

      blank? ->
        case Enum.find(@search_filters, &(not is_nil(args[&1]))) do
          nil ->
            {:ok, :recent}

          p ->
            {:error, "#{p} needs a query or similar_to; omit it to list recently updated notes"}
        end

      true ->
        {:ok, :query}
    end
  end

  # The source must be unambiguous: the same path can exist in several vaults.
  # `get_note_metadata/3`, not `get_note/3` — this never reads title/content/
  # tags, so decrypting them would be pure overhead (and a needless crash
  # surface on corrupt ciphertext). Resolution still goes through the same
  # `user_id AND vault_id` scoped query `get_note/3` uses (Notes.scoped/2),
  # not just RLS, so a path that exists only in another user's vault, or only
  # in a vault outside the `vaults` list this credential was given, resolves
  # to :not_found here — never a cross-tenant hit.
  defp similar_source(user, vaults, path) do
    hits = for v <- vaults, {:ok, note} <- [Notes.get_note_metadata(user, v, path)], do: {note, v}

    case hits do
      [{note, _v}] ->
        {:ok, note}

      [] ->
        {:error, "Note not found: #{path}"}

      many ->
        names = Enum.map_join(many, ", ", fn {_n, v} -> v.name end)
        {:error, "#{path} exists in #{length(many)} vaults (#{names}); pass vault_id to pick one"}
    end
  end

  # `dense_indexed_hash` is nil unless the last index pass wrote dense vectors
  # (EmbedNote.stamp_embed_hash/3). Qdrant rejects a recommend whose positive
  # point has no dense vector, so refuse here with a message the caller can act on.
  defp stored_points(%{dense_indexed_hash: nil}, path), do: {:error, not_embedded(path)}

  defp stored_points(note, path) do
    case Engram.Indexing.point_ids_for_note(note) do
      [] -> {:error, not_embedded(path)}
      ids -> {:ok, ids}
    end
  end

  defp not_embedded(path),
    do:
      "#{path} has no stored embedding yet (it may be new, empty, or not embedded on " <>
        "your plan); try again later, or use query instead"

  # Renders a `Search.similar/4` result for the `similar_to` tool path.
  #
  # A Qdrant 400/404 on `recommend` means the positive point ids it was given
  # no longer resolve to a stored dense vector (stale/deleted points — the
  # `dense_indexed_hash` pre-check in `stored_points/2` catches the note-level
  # case, this catches the point-level one). That is the same fixable
  # situation `not_embedded/1` already names, not a generic outage.
  #
  # On success, drop any hit that is the source note itself: `must_not:
  # has_id` in `Qdrant.recommend_body/2` excludes the positive points by id,
  # but a stale point a failed `delete_points_for_note`/reindex left behind
  # can still belong to the source note and surface under its
  # {vault_id, source_path} after grouping. Filtered here, after grouping,
  # because that's where source_path/vault_id are finally decrypted.
  defp render_similar({:error, {status, _body}}, _names, _note, path) when status in [400, 404],
    do: {:error, not_embedded(path)}

  defp render_similar({:ok, results}, names, note, path) do
    render_search({:ok, Enum.reject(results, &source_result?(&1, note, path))}, names)
  end

  defp render_similar(other, names, _note, _path), do: render_search(other, names)

  defp source_result?(result, note, path),
    do: result[:source_path] == path and to_string(result[:vault_id]) == to_string(note.vault_id)

  # Same result shape as render_search/2; vault labels only in cross-vault mode.
  defp render_recent(pairs, names) do
    text =
      if pairs == [] do
        "No notes yet."
      else
        Enum.join(
          [
            "Recently updated:"
            | Enum.map(pairs, fn {n, _v} -> "- #{n.path} (#{n.updated_at})" end)
          ],
          "\n"
        )
      end

    results =
      Enum.map(pairs, fn {n, v} ->
        payload = %{
          "score" => 0,
          "title" => n.title,
          "source_path" => n.path,
          "tags" => n.tags || [],
          "text" => ""
        }

        if names == %{},
          do: payload,
          else:
            Map.merge(payload, %{"vault_id" => to_string(v.id), "vault" => names[to_string(v.id)]})
      end)

    {:ok, text, %{"results" => results}}
  end

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
  def render_folder({:ok, notes, atts, folders}, folder) do
    label = folder_label(folder)

    text =
      if notes == [] and atts == [] and folders == [] do
        "No notes found in folder: #{label}"
      else
        entry_rows =
          if notes == [] and atts == [] do
            []
          else
            note_rows =
              Enum.map(notes, fn n ->
                tags = if n.tags && n.tags != [], do: Enum.join(n.tags, ", "), else: ""
                "| #{n.title} | #{n.path} | #{tags} |"
              end)

            att_rows =
              Enum.map(atts, fn a ->
                "| #{Path.basename(a.path)} | #{a.path} | (attachment) |"
              end)

            ["", "| Title | Path | Tags |", "|-------|------|------|"] ++ note_rows ++ att_rows
          end

        folder_rows =
          if folders == [] do
            []
          else
            rows = Enum.map(folders, fn f -> "| #{f["folder"]} | #{f["count"]} |" end)
            ["", "**Subfolders:**", "", "| Folder | Notes |", "|--------|-------|"] ++ rows
          end

        Enum.join(["**Folder:** #{label}"] ++ entry_rows ++ folder_rows, "\n")
      end

    structured = %{
      # Raw path, not the "(root)" label — this is what a client echoes back.
      "folder" => folder,
      "notes" =>
        Enum.map(notes, fn n ->
          %{"title" => n.title, "path" => n.path, "tags" => n.tags || []}
        end),
      "attachments" =>
        Enum.map(atts, fn a -> %{"name" => Path.basename(a.path), "path" => a.path} end),
      "folders" => folders
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

  # Direct subfolders of `folder`, or every descendant when `recursive?`.
  # `all_folders` is the full vault-wide list from `list_folders_with_counts/2`
  # (already fetched once by the caller); filtered here in BEAM rather than
  # re-querying per folder depth.
  #
  # `list_folders_with_counts/2` only returns a row for a folder that holds a
  # note DIRECTLY, so an intermediate folder (e.g. "P" when only "P/Q/x.md"
  # exists) has no row of its own. Deriving children straight from existing
  # rows made "P" invisible at the root — its only note was unreachable by
  # navigation. Instead: derive every child/ancestor path from the full path
  # of each descendant ROW (which always exists, even when intermediate
  # segments don't), and look up each derived path's count in the row map,
  # defaulting to 0 when there is none.
  defp subfolders(all_folders, folder, recursive?) do
    prefix = if folder == "", do: "", else: folder <> "/"
    counts = Map.new(all_folders, &{&1.folder || "", &1.count})

    descendant_rows =
      counts
      |> Map.keys()
      |> Enum.filter(&(&1 != "" and &1 != folder and String.starts_with?(&1, prefix)))

    paths =
      if recursive? do
        descendant_rows |> Enum.flat_map(&ancestor_chain(&1, folder)) |> Enum.uniq()
      else
        descendant_rows |> Enum.map(&first_child(&1, folder)) |> Enum.uniq()
      end

    paths
    |> Enum.sort()
    |> Enum.map(&%{"folder" => &1, "count" => Map.get(counts, &1, 0)})
  end

  # The single path segment of `descendant` immediately under `folder` —
  # e.g. "P/Q/R" under folder "" -> "P", under folder "P" -> "P/Q".
  defp first_child(descendant, folder) do
    prefix = if folder == "", do: "", else: folder <> "/"
    segment = descendant |> String.replace_prefix(prefix, "") |> String.split("/") |> hd()
    if folder == "", do: segment, else: folder <> "/" <> segment
  end

  # Every intermediate ancestor path strictly between `folder` and
  # `descendant`, inclusive of `descendant` itself — e.g. "P/Q/R" under
  # folder "" -> ["P", "P/Q", "P/Q/R"].
  defp ancestor_chain(descendant, folder) do
    prefix = if folder == "", do: "", else: folder <> "/"
    segments = descendant |> String.replace_prefix(prefix, "") |> String.split("/")

    {chain, _} =
      Enum.reduce(segments, {[], folder}, fn seg, {acc, path} ->
        new_path = if path == "", do: seg, else: path <> "/" <> seg
        {[new_path | acc], new_path}
      end)

    Enum.reverse(chain)
  end

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

  defp do_replace(content, find, replace, -1),
    do: {String.replace(content, find, replace), count_matches(content, find, 0, 0)}

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
  #   * a binary reason is a message a `rmw_upsert` rebuild function already
  #     built for the caller (e.g. a content-shape guard), so it is passed
  #     through verbatim rather than replaced with the generic `msgs[:error]`.
  #     `Notes.upsert_note/4`'s own error reasons are never binaries (its spec
  #     is Ecto.Changeset.t() | atom() | {atom(), ...}), so this can't shadow
  #     an internal failure detail leaking to the caller.
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
      {:error, :too_large} -> {:error, @too_large}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _reason} -> {:error, msgs[:error]}
    end
  end

  # "end" stays byte-identical to the pre-position append (existing tests
  # pin the old behavior). "start" inserts right after the frontmatter
  # fence when present, so frontmatter bytes are never touched; with no
  # frontmatter (or an empty note) it goes to the very top.
  defp place_text(content, text, "end"), do: String.trim_trailing(content, "\n") <> "\n" <> text

  defp place_text(content, text, "start") do
    case Frontmatter.split(content) do
      {nil, body} ->
        text <> "\n" <> body

      {_frontmatter, body} ->
        # `content` minus the `body` suffix is everything up to and including
        # the closing fence. When the note is ONLY frontmatter with no
        # trailing newline, `body` is "" and that prefix is `content`
        # unchanged (ends in "---", not "\n") — gluing `text` straight onto
        # the fence instead of starting a new line after it, exactly the
        # shape Frontmatter.project/4 always guarantees on write
        # (`"---\n" <> block <> "---\n" <> body`, frontmatter.ex ~418).
        prefix = String.replace_suffix(content, body, "")
        prefix = if String.ends_with?(prefix, "\n"), do: prefix, else: prefix <> "\n"
        prefix <> text <> "\n" <> body
    end
  end

  # nil (missing key, or an explicit JSON null from a strict-schema client) is
  # the only thing that defaults to "end". Everything else, including the
  # boolean false, must be exactly "end" or "start" or it is a fixable error
  # rather than a silent default.
  defp resolve_append_position(nil), do: {:ok, "end"}
  defp resolve_append_position(position) when position in ["end", "start"], do: {:ok, position}
  defp resolve_append_position(_), do: {:error, "position must be end or start"}

  # position "end" never changes the note's shape, so it needs no guard.
  #
  # position "start" prepends `text` in front of the current body (after any
  # frontmatter fence). The resulting body (`text <> "\n" <> body`) is what
  # CrdtBridge.ingest_plaintext/2 re-splits into frontmatter/body on the next
  # write, and what CrdtBridge.normalize_doc/1 re-splits on the next CRDT room
  # bind. If that combined body itself parses as starting with real
  # frontmatter (e.g. caller text opens with "---" and later text closes it
  # into a YAML map), the accidental block gets silently lifted into the
  # note's real frontmatter, regardless of whether the note had frontmatter
  # before this write, since the body is checked independently of any
  # existing frontmatter prefix. Refuse rather than write something that only
  # misparses later.
  defp guard_start_frontmatter_safety("end", _current, _text), do: :ok

  defp guard_start_frontmatter_safety("start", current, text) do
    {_frontmatter, body} = Frontmatter.split(current)

    case Frontmatter.split(text <> "\n" <> body) do
      {nil, _} ->
        :ok

      {_frontmatter, _body} ->
        {:error,
         "text would be read as frontmatter at the top of this note; start it with " <>
           "something other than a --- line, or use position end"}
    end
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

  @doc """
  The part of a tool call that does external I/O, run BEFORE the request
  transaction opens (`EngramWeb.McpController`) so no pooled connection is
  held across it. `create_note`'s auto-placement is a Voyage embed plus a
  Qdrant query; its answer rides in `args` under the atom key
  `:placed_folder`, which JSON arguments can never carry.
  """
  @spec before_txn(String.t(), map(), term(), map()) :: map()
  def before_txn("create_note", user, vault, args) do
    if explicit_folder(args),
      do: args,
      else:
        Map.put(
          args,
          :placed_folder,
          auto_place_folder(user, vault, title(args), args["content"] || "")
        )
  end

  def before_txn(_tool, _user, _vault, args), do: args

  defp title(args), do: args["title"] || "Untitled"

  defp explicit_folder(%{"suggested_folder" => f}) when is_binary(f) and f != "",
    do: String.trim_trailing(f, "/")

  defp explicit_folder(_args), do: nil

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
    {fm, body} = content |> String.replace_prefix("﻿", "") |> Frontmatter.split()

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
  # `[ \t]*`, not `\s*`: `\s` crosses newlines, so a miss backtracked from
  # every line start (28 s on 200 KB of blank frontmatter lines).
  defp fm_has_key?(fm, key), do: Regex.match?(~r/^[ \t]*#{key}[ \t]*:/mi, fm)

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

  defp narrow_to_section([{_path, nil}] = fetched, _section, _gate), do: {:ok, fetched}

  defp narrow_to_section([{path, note}], section, gate) do
    case Sections.section(note.content || "", section, gate) do
      {:ok, text} -> {:ok, [{path, %{note | content: text}}]}
      {:error, {:not_found, hs}} -> {:error, heading_missing_msg(path, section, hs)}
      {:error, reason} -> {:error, section_error(section, reason)}
    end
  end

  # A note-scoped list, not a network response, so 50/100 are arbitrary but
  # generous caps meant only to stop a huge note from flooding the reply.
  @max_listed_headings 50
  @max_heading_chars 100

  defp heading_missing_msg(path, section, []),
    do: "Heading not found in #{path}: #{section}. This note has no headings."

  defp heading_missing_msg(path, section, hs) do
    total = length(hs)
    listed = hs |> Enum.take(@max_listed_headings) |> Enum.map_join(", ", &truncate_heading/1)

    more =
      if total > @max_listed_headings,
        do: ", and #{total - @max_listed_headings} more",
        else: ""

    "Heading not found in #{path}: #{section}. Headings: #{listed}#{more}"
  end

  defp truncate_heading(%{text: text}) do
    if String.length(text) > @max_heading_chars do
      String.slice(text, 0, @max_heading_chars) <> "..."
    else
      text
    end
  end

  # Content bytes one get_notes call may return across its notes (an
  # outline returns no content, so it is never held to it). A client cannot
  # use 200 MB in one reply either; the first note is always returned whole.
  @get_notes_budget 4 * 1024 * 1024

  @doc false
  def get_notes_budget, do: @get_notes_budget

  # `entries` is [{path, fetch_fn}]. Each note is fetched, budgeted and
  # rendered before the next, so at most the kept content plus one note is
  # alive.
  defp render_notes(user, entries, outline?, links?, gate) do
    {rendered, _spent} =
      Enum.map_reduce(entries, 0, fn {path, fetch}, spent ->
        case fetch.() do
          nil ->
            {{"Note not found: #{path}", %{"path" => path, "found" => false}}, spent}

          note ->
            size = if outline?, do: 0, else: byte_size(note.content || "")

            if spent == 0 or spent + size <= @get_notes_budget,
              do: {render_note(user, note, outline?, links?, gate), spent + size},
              else: {over_budget(path), spent}
        end
      end)

    {texts, notes} = Enum.unzip(rendered)
    {:ok, Enum.join(texts, "\n\n---\n\n"), %{"notes" => notes}}
  end

  defp over_budget(path) do
    msg =
      "Not returned: this call's content budget (#{div(@get_notes_budget, 1_048_576)} MB) " <>
        "is spent. Fetch #{path} in its own call."

    {"#{path}: #{msg}", %{"path" => path, "found" => true, "error" => msg}}
  end

  defp render_note(user, note, outline?, links?, gate) do
    {text, payload} =
      if outline?,
        do: outline_entry(note, gate),
        else: {format_get_note(note), note_payload(note)}

    payload = Map.put(payload, "found", true)

    # One backlinks + outgoing query pair per note (N+1), not batched.
    # Fine at get_notes' 20-path cap; revisit only if that cap rises.
    if links? do
      {links, truncation} = links_payload(user, note)
      {text <> "\n\n" <> format_links(links, truncation), Map.merge(payload, links)}
    else
      {text, payload}
    end
  end

  # Both reads are user-scoped by the Links context; vault scoping holds
  # because an edge only ever resolves inside its source note's vault
  # (Links.resolve_target/4), so a cross-vault same-named note never binds.
  #
  # `backlinks_for_note/2` is DB-capped; fetching `limit + 1` DISTINCT
  # sources is how we tell "exactly at the cap" apart from "there would have
  # been more" without an unbounded COUNT. `distinct_sources: true` is
  # required here because one source note can carry several edges to the
  # same target, so a raw edge count would over-report truncation.
  # `outgoing`/`unresolved` come from one note's own edges (links_for_note/2,
  # never DB-limited), so their true length is always known and the cap is
  # applied here, after dedup, with an exact overage.
  #
  # `@doc false` and public (not `defp`) only so a test can pass a small
  # `limit` directly instead of manufacturing `Links.backlinks_limit/0` + 1
  # real notes.
  @doc false
  @spec links_payload(map(), map(), pos_integer()) ::
          {map(), {boolean(), non_neg_integer(), non_neg_integer()}}
  def links_payload(user, note, limit \\ Engram.Links.backlinks_limit()) do
    raw_backlinks =
      Engram.Links.backlinks_for_note(user, note.id, limit: limit + 1, distinct_sources: true)

    backlinks_more? = length(raw_backlinks) > limit

    backlinks =
      raw_backlinks |> Enum.map(& &1.source_path) |> Enum.reject(&is_nil/1) |> Enum.take(limit)

    outgoing_edges = Engram.Links.links_for_note(user, note.id)

    {targets, outgoing_extra} =
      outgoing_edges
      |> Enum.map(& &1.target_path)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> cap(limit)

    {unresolved, unresolved_extra} =
      outgoing_edges
      |> Enum.filter(& &1.dangling)
      |> Enum.map(& &1.target_text)
      |> Enum.uniq()
      |> cap(limit)

    links = %{
      "backlinks" => backlinks,
      "outgoing" => targets,
      "unresolved" => unresolved,
      "links_truncated" => backlinks_more? or outgoing_extra > 0 or unresolved_extra > 0
    }

    {links, {backlinks_more?, outgoing_extra, unresolved_extra}}
  end

  # Slices a deduped list to `limit`, returning {sliced, extra} where `extra`
  # is the exact count of items dropped (0 when nothing was dropped).
  defp cap(list, limit) do
    count = length(list)
    if count > limit, do: {Enum.take(list, limit), count - limit}, else: {list, 0}
  end

  # Public + `@doc false` alongside `links_payload/3`, so a test can render
  # the text for a `links_payload/3` call made with a small injected limit.
  @doc false
  @spec format_links(map(), {boolean(), non_neg_integer(), non_neg_integer()}) :: String.t()
  def format_links(links, {backlinks_more?, outgoing_extra, unresolved_extra}) do
    Enum.join(
      [
        "Backlinks: " <> suffixed(links["backlinks"], backlinks_more?),
        "Links to: " <> suffixed(links["outgoing"], outgoing_extra),
        "Unresolved: " <> suffixed(links["unresolved"], unresolved_extra)
      ],
      "\n"
    )
  end

  # `more` is `true` when the count past the cap is unknown (backlinks, from
  # the limit+1 probe), a positive integer when it is known exactly
  # (outgoing/unresolved), or `false`/`0` when the list was not truncated.
  defp suffixed(items, true), do: list_or_none(items) <> ", and more"

  defp suffixed(items, more) when is_integer(more) and more > 0,
    do: list_or_none(items) <> ", and #{more} more"

  defp suffixed(items, _), do: list_or_none(items)

  defp list_or_none([]), do: "none"
  defp list_or_none(items), do: Enum.join(items, ", ")

  # A parse refusal (busy, timeout, invalid UTF-8) is a per-note `error`
  # entry, so one note does not fail a whole multi-path call.
  defp outline_entry(note, gate) do
    base = note |> note_payload() |> Map.delete("content")

    case Sections.headings(note.content || "", gate) do
      {:ok, hs} ->
        outline_ok(note, base, hs)

      {:error, reason} ->
        msg = section_error(nil, reason)
        {"**Path:** #{note.path}\n#{msg}", Map.put(base, "error", msg)}
    end
  end

  defp outline_ok(note, base, hs) do
    outline = Enum.map(hs, &%{"level" => &1.level, "heading" => &1.text})

    lines =
      if outline == [],
        do: ["(no headings)"],
        else:
          Enum.map(outline, &(String.duplicate("  ", &1["level"] - 1) <> "- " <> &1["heading"]))

    {Enum.join(["**Path:** #{note.path}" | lines], "\n"), Map.put(base, "outline", outline)}
  end

  defp vault_payload(v) do
    %{
      "id" => to_string(v.id),
      "name" => v.name,
      "slug" => v.slug,
      "is_default" => v.is_default
    }
  end
end
