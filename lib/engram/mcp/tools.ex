defmodule Engram.MCP.Tools do
  @moduledoc """
  MCP tool definitions — name, description, inputSchema, handler.
  Each tool maps to a handler function in Engram.MCP.Handlers.
  """

  alias Engram.MCP.Handlers

  # `outputSchema` is OPTIONAL and added per-tool (#1660). Declaring it is a
  # promise: a tool that advertises one MUST return `structuredContent` on
  # success, so the two are added together or not at all. Handlers signal it by
  # returning the 3-tuple; `run_tool_handler/4` is the only place that cares.
  @type tool_def :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:inputSchema) => map(),
          optional(:title) => String.t(),
          optional(:annotations) => map(),
          optional(:outputSchema) => map(),
          required(:handler) => (map(), map(), map() ->
                                   {:ok, String.t()}
                                   | {:ok, String.t(), map()}
                                   | {:error, String.t()})
        }

  # Tools that do NOT operate on a single vault's contents, so they take no
  # `vault_id`: `list_vaults` spans all of them, `set_vault` has its own.
  @vault_scoping_exempt ~w(list_vaults set_vault)

  # MCP is stateless HTTP JSON-RPC: there is no session to hold an "active vault"
  # between tool calls, so every vault-scoped tool advertises an optional
  # `vault_id`. Injected here (not hand-written per tool) so new tools inherit it.
  # Deliberately NOT `"format" => "uuid"`: the field accepts a vault NAME too,
  # and advertising a uuid format makes strict clients reject a valid name
  # before it ever reaches us.
  @vault_id_property %{
    "type" => "string",
    "description" =>
      "Target vault — its name (e.g. \"Engram\") or its UUID. REQUIRED when you own " <>
        "more than one vault — the server keeps no active-vault state between calls, so " <>
        "it must be passed on every vault-scoped call. Omit only if you have a single " <>
        "vault. Call list_vaults if a name does not resolve."
  }

  # MCP tool annotations, keyed by tool name. The Claude and ChatGPT app
  # directories reject a server without them, and clients use `readOnlyHint` to
  # skip the confirmation prompt. `destructive` = overwrites or removes content
  # the user wrote. No tool is `openWorldHint`: every one stays inside the
  # caller's own vaults. A tool missing here crashes `list/0`, which is the point.
  # Each value: {title, readOnlyHint, destructiveHint, idempotentHint}.
  @annotations %{
    "list_vaults" => {"List Vaults", true, false, true},
    "set_vault" => {"Check Vault", true, false, true},
    "search_notes" => {"Search Notes", true, false, true},
    "list_tags" => {"List Tags", true, false, true},
    "list_folders" => {"List Folders", true, false, true},
    "list_folder" => {"List Folder Contents", true, false, true},
    "create_folder" => {"Create Folder", false, false, true},
    "suggest_folder" => {"Suggest Folder", true, false, true},
    "get_note" => {"Read Note", true, false, true},
    "get_notes" => {"Read Notes", true, false, true},
    "create_note" => {"Create Note", false, false, false},
    "write_note" => {"Write Note", false, true, true},
    "append_to_note" => {"Append to Note", false, false, false},
    "patch_note" => {"Find and Replace in Note", false, true, false},
    "update_section" => {"Replace Note Section", false, true, true},
    "rename_note" => {"Rename Note", false, false, false},
    "rename_folder" => {"Rename Folder", false, false, false},
    "delete_note" => {"Delete Note", false, true, true},
    "delete_folder" => {"Delete Folder", false, true, true},
    "move_attachment" => {"Move Attachment", false, false, false},
    "get_attachment_upload_target" => {"Get Attachment Upload Target", true, false, true}
  }

  @spec list() :: [tool_def()]
  def list do
    [
      list_vaults_def(),
      set_vault_def(),
      search_notes_def(),
      list_tags_def(),
      list_folders_def(),
      list_folder_def(),
      create_folder_def(),
      suggest_folder_def(),
      get_note_def(),
      get_notes_def(),
      create_note_def(),
      write_note_def(),
      append_to_note_def(),
      patch_note_def(),
      update_section_def(),
      rename_note_def(),
      rename_folder_def(),
      delete_note_def(),
      delete_folder_def(),
      move_attachment_def(),
      get_attachment_upload_target_def()
    ]
    |> Enum.map(&(&1 |> with_vault_id() |> with_annotations()))
  end

  defp with_annotations(%{name: name} = tool) do
    {title, read_only, destructive, idempotent} = Map.fetch!(@annotations, name)

    Map.merge(tool, %{
      title: title,
      annotations: %{
        "title" => title,
        "readOnlyHint" => read_only,
        "destructiveHint" => destructive,
        "idempotentHint" => idempotent,
        "openWorldHint" => false
      }
    })
  end

  defp with_vault_id(%{name: name} = tool) when name in @vault_scoping_exempt, do: tool

  # search_notes spans all vaults by default, so vault_id is an optional narrower
  # there — not the "required when multi-vault" contract the other tools carry.
  defp with_vault_id(%{name: "search_notes"} = tool) do
    put_vault_id_property(tool, %{
      "type" => "string",
      "description" =>
        "Optional: limit the search to a single vault, by name (e.g. \"Engram\") or " <>
          "UUID. Omit to search across ALL your vaults. Call list_vaults to see them."
    })
  end

  defp with_vault_id(tool), do: put_vault_id_property(tool, @vault_id_property)

  # `put_in(tool, [:inputSchema, "properties", "vault_id"], ...)` would raise
  # if a future tool def ever omitted "properties" — a single malformed tool
  # def would then crash Tools.list/0 for every tool, since it's rebuilt on
  # every request (found in adversarial review of #1491/#1492's fix).
  defp put_vault_id_property(tool, property) do
    update_in(tool, [:inputSchema, "properties"], fn
      nil -> %{"vault_id" => property}
      properties -> Map.put(properties, "vault_id", property)
    end)
  end

  @spec get(String.t()) :: {:ok, tool_def()} | :error
  def get(name) do
    case Enum.find(list(), &(&1.name == name)) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end

  @doc "Tool names that take no `vault_id` — see `@vault_scoping_exempt`."
  @spec vault_scoping_exempt() :: [String.t()]
  def vault_scoping_exempt, do: @vault_scoping_exempt

  # -- Tool definitions --

  defp list_vaults_def do
    %{
      name: "list_vaults",
      description: "List all vaults owned by the current user with IDs, names, and descriptions.",
      inputSchema: %{"type" => "object", "properties" => %{}},
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "vaults" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "id" => %{"type" => "string", "description" => "Vault UUID"},
                # Nullable on purpose: `name` is a VIRTUAL field and
                # `decrypt_vault_if_needed/2` returns the row undecrypted on a
                # crypto failure, leaving it nil. A client validating against
                # this schema would turn a degraded-but-readable listing into a
                # hard failure — on list_vaults, which is the recovery path.
                "name" => %{"type" => ["string", "null"], "description" => "Display name"},
                # Display only — deliberately NOT advertised as a vault_id ref.
                # Resolution puts exact display name before slug (#1665), so a
                # vault whose slug is ALSO another vault's literal name loses:
                # emit `test-vault` for vault A, pass it back, and it resolves
                # to the vault literally NAMED "test-vault". `id` is in this
                # same payload and always round-trips; pointing a code-mode
                # client at the one handle that does not would be a
                # wrong-target write.
                "slug" => %{"type" => "string", "description" => "URL-safe handle"},
                "is_default" => %{"type" => "boolean"},
                "description" => %{"type" => ["string", "null"]}
              },
              "required" => ["id", "name", "slug", "is_default"]
            }
          }
        },
        "required" => ["vaults"]
      },
      handler: &Handlers.handle("list_vaults", &1, &2, &3)
    }
  end

  defp set_vault_def do
    %{
      name: "set_vault",
      description:
        "Validate and echo a vault by name or ID. NOTE: this does NOT persist an " <>
          "active vault — MCP keeps no state between calls. To read or write a " <>
          "specific vault, pass its vault_id on each tool call; a vault's name works " <>
          "there too, so this need not be called first. Use list_vaults to see them.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "vault_id" => %{
            "type" => "string",
            "description" => "Vault to validate — its name (e.g. \"Engram\") or its UUID"
          }
        }
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          # Null when called with no vault_id: the tool then only explains that
          # MCP holds no active-vault state, so there is no vault to report.
          "vault" => %{
            "type" => ["object", "null"],
            "properties" => %{
              "id" => %{"type" => "string"},
              "name" => %{"type" => ["string", "null"]},
              "slug" => %{"type" => "string"},
              "is_default" => %{"type" => "boolean"},
              "description" => %{"type" => ["string", "null"]}
            },
            "required" => ["id", "name", "slug", "is_default"]
          }
        },
        "required" => ["vault"]
      },
      handler: &Handlers.handle("set_vault", &1, &2, &3)
    }
  end

  defp search_notes_def do
    %{
      name: "search_notes",
      description:
        "Search your personal knowledge base. Finds relevant notes using semantic " <>
          "search. Searches across ALL your vaults by default; pass vault_id to limit " <>
          "to one. Use when the user asks about their notes, vault, knowledge, or memory.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Natural language search query"},
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of results (1-20, default 5)",
            "default" => 5
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Optional list of tags to filter by"
          },
          "folder" => %{
            "type" => "string",
            "description" => "Optional folder path to scope the search to (exact match)"
          },
          "type" => %{
            "type" => "string",
            "description" =>
              "Optional frontmatter type to filter by (e.g. 'Playbook', 'Reference'); case-insensitive"
          },
          "created_after" => %{
            "type" => "string",
            "description" =>
              "Only notes created at/after this ISO 8601 datetime (frontmatter created/date)"
          },
          "created_before" => %{
            "type" => "string",
            "description" => "Only notes created at/before this ISO 8601 datetime"
          },
          "updated_after" => %{
            "type" => "string",
            "description" =>
              "Only notes updated at/after this ISO 8601 datetime (frontmatter timestamp/modified)"
          },
          "updated_before" => %{
            "type" => "string",
            "description" => "Only notes updated at/before this ISO 8601 datetime"
          },
          "mode" => %{
            "type" => "string",
            "enum" => ["hybrid", "keyword", "vector"],
            "description" =>
              "Retrieval mode (default hybrid). Use 'keyword' for exact terms, " <>
                "identifiers, code, or error strings; 'vector' for purely " <>
                "conceptual/semantic queries; 'hybrid' (default) blends both.",
            "default" => "hybrid"
          },
          "diversity" => %{
            "type" => "number",
            "minimum" => 0,
            "maximum" => 1,
            "description" =>
              "Result diversity (0 = most relevant, default tuned per plan; 1 = most varied). " <>
                "Uses Maximal Marginal Relevance to reduce redundancy among results."
          }
        },
        "required" => ["query"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "results" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "score" => %{"type" => "number"},
                # Every field below comes off a search hit whose shape varies by
                # backend and index age, so each is nullable rather than
                # required. `format_search_result/3` already omits the missing
                # ones from the markdown; the schema says the same thing.
                "title" => %{"type" => ["string", "null"]},
                "heading_path" => %{"type" => ["string", "null"]},
                "source_path" => %{"type" => ["string", "null"]},
                "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
                "text" => %{"type" => "string", "description" => "Matched chunk"},
                # Present only in cross-vault mode, matching the rendered label.
                "vault_id" => %{"type" => ["string", "null"]},
                "vault" => %{"type" => ["string", "null"]}
              },
              "required" => ["score", "text"]
            }
          }
        },
        "required" => ["results"]
      },
      handler: &Handlers.handle("search_notes", &1, &2, &3)
    }
  end

  defp list_tags_def do
    %{
      name: "list_tags",
      description:
        "List all tags in the personal knowledge base with document counts. " <>
          "Use to explore what topics exist in the vault.",
      inputSchema: %{"type" => "object", "properties" => %{}},
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "tags" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "name" => %{"type" => "string"},
                "count" => %{"type" => "integer", "description" => "Notes carrying this tag"}
              },
              "required" => ["name", "count"]
            }
          }
        },
        "required" => ["tags"]
      },
      handler: &Handlers.handle("list_tags", &1, &2, &3)
    }
  end

  defp list_folders_def do
    %{
      name: "list_folders",
      description:
        "List all folders in the personal knowledge base with note counts. " <>
          "Use to understand the vault's organization.",
      inputSchema: %{"type" => "object", "properties" => %{}},
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "folders" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                # The RAW folder path, which is what list_folder takes back.
                # The markdown table shows "(root)" for the empty one; that is
                # a label, not a value, and is deliberately not emitted here.
                "folder" => %{
                  "type" => "string",
                  "description" => ~s(Folder path; "" is the vault root)
                },
                "count" => %{"type" => "integer", "description" => "Notes directly inside"}
              },
              "required" => ["folder", "count"]
            }
          }
        },
        "required" => ["folders"]
      },
      handler: &Handlers.handle("list_folders", &1, &2, &3)
    }
  end

  defp list_folder_def do
    %{
      name: "list_folder",
      description:
        "List all notes in a specific folder. Pass an empty string to list notes in the vault root.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "folder" => %{
            "type" => "string",
            "description" => "Folder path (e.g. \"Health\") or \"\" for root"
          }
        },
        "required" => ["folder"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "folder" => %{"type" => "string", "description" => ~s(Folder listed; "" is the root)},
          "notes" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                # Nullable as deliberate slack, NOT for list_vaults' reason:
                # `list_notes_in_folder` decrypts with `decrypt_or_raise!`, so
                # a row never arrives undecrypted the way a vault can. `title`
                # falls back to the filename stem and is in practice always
                # present. Declared nullable anyway because a required field
                # that turns up absent is a hard client failure, while an
                # unexpected null is not.
                "title" => %{"type" => ["string", "null"]},
                "path" => %{"type" => "string", "description" => "Vault-relative path"},
                "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
              },
              "required" => ["title", "path", "tags"]
            }
          },
          "attachments" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "name" => %{"type" => "string"},
                "path" => %{"type" => "string"}
              },
              "required" => ["name", "path"]
            }
          }
        },
        "required" => ["folder", "notes", "attachments"]
      },
      handler: &Handlers.handle("list_folder", &1, &2, &3)
    }
  end

  defp create_folder_def do
    %{
      name: "create_folder",
      description:
        "Create an explicit empty folder in the personal knowledge base. " <>
          "Use to scaffold folder structure before placing notes. Idempotent — " <>
          "calling with an existing folder name succeeds without creating duplicates.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "folder" => %{
            "type" => "string",
            "description" => "Folder path, e.g. \"Projects/Active\""
          }
        },
        "required" => ["folder"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{"folder" => %{"type" => "string"}},
        "required" => ["folder"]
      },
      handler: &Handlers.handle("create_folder", &1, &2, &3)
    }
  end

  defp suggest_folder_def do
    %{
      name: "suggest_folder",
      description:
        "Find the best existing folder for a new note based on a description of its content. " <>
          "Call before create_note when the right folder is unclear.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "description" => %{
            "type" => "string",
            "description" => "What the note is about"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Number of suggestions (1-10, default 5)",
            "default" => 5
          }
        },
        "required" => ["description"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "suggestions" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "rank" => %{"type" => "integer"},
                # Raw path; "" is the root. The table renders "(root)", which
                # is a label and not a value a client can pass back.
                "folder" => %{"type" => "string"},
                "count" => %{"type" => "integer"}
              },
              "required" => ["rank", "folder", "count"]
            }
          }
        },
        "required" => ["suggestions"]
      },
      handler: &Handlers.handle("suggest_folder", &1, &2, &3)
    }
  end

  defp get_note_def do
    %{
      name: "get_note",
      description:
        "Retrieve the full content of a specific note. " <>
          "Use after searching to read a complete note.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "source_path" => %{
            "type" => "string",
            "description" => "The path of the note (e.g. \"Health/Omega Oils.md\")"
          }
        },
        "required" => ["source_path"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Vault-relative path"},
          "title" => %{"type" => ["string", "null"]},
          "folder" => %{"type" => "string"},
          "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
          "content" => %{"type" => "string"}
        },
        "required" => ["path", "title", "folder", "tags", "content"]
      },
      handler: &Handlers.handle("get_note", &1, &2, &3)
    }
  end

  defp get_notes_def do
    %{
      name: "get_notes",
      description:
        "Retrieve the full content of multiple notes in one call (1-20 paths). " <>
          "Use to inventory a folder (list_folder then get_notes) or to read a batch " <>
          "of search results without N round-trips. Missing paths are reported inline.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Note paths to read (max 20), e.g. [\"Health/A.md\", \"Health/B.md\"]"
          }
        },
        "required" => ["paths"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "notes" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                # A batch that resolves SOME of its paths succeeded, so a miss
                # is data here rather than an error the way it is in get_note.
                # Only `path` and `found` are guaranteed on a miss.
                "found" => %{"type" => "boolean"},
                "path" => %{"type" => "string", "description" => "Vault-relative path"},
                "title" => %{"type" => ["string", "null"]},
                "folder" => %{"type" => "string"},
                "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
                "content" => %{"type" => "string"}
              },
              "required" => ["path", "found"]
            }
          }
        },
        "required" => ["notes"]
      },
      handler: &Handlers.handle("get_notes", &1, &2, &3)
    }
  end

  defp create_note_def do
    %{
      name: "create_note",
      description:
        "Create a new note with automatic folder placement. " <>
          "If suggested_folder is omitted, the note is placed automatically. " <>
          "Never overwrites: fails if a note already exists at the resulting path.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "Title for the new note"},
          "content" => %{"type" => "string", "description" => "Markdown content"},
          "suggested_folder" => %{
            "type" => "string",
            "description" => "Only set when user explicitly named a folder"
          }
        },
        "required" => ["title", "content"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Where the note landed — the server picks the folder"
          }
        },
        "required" => ["path"]
      },
      handler: &Handlers.handle("create_note", &1, &2, &3)
    }
  end

  defp write_note_def do
    %{
      name: "write_note",
      description:
        "Write or update a note. Saves to storage, indexes for search, and syncs to Obsidian.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Full path for the note (e.g. \"Health/New Note.md\")"
          },
          "content" => %{"type" => "string", "description" => "Full markdown content"}
        },
        "required" => ["path", "content"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}},
        "required" => ["path"]
      },
      handler: &Handlers.handle("write_note", &1, &2, &3)
    }
  end

  defp append_to_note_def do
    %{
      name: "append_to_note",
      description: "Append text to an existing note, or create it if it doesn't exist.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Full path for the note"},
          "text" => %{"type" => "string", "description" => "Text to append"}
        },
        "required" => ["path", "text"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "created" => %{
            "type" => "boolean",
            "description" => "true when the note did not exist and was created"
          }
        },
        "required" => ["path", "created"]
      },
      handler: &Handlers.handle("append_to_note", &1, &2, &3)
    }
  end

  defp patch_note_def do
    %{
      name: "patch_note",
      description:
        "Find and replace text in an existing note. " <>
          "By default replaces the first occurrence. Set occurrence to -1 to replace all.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Full path of the note"},
          "find" => %{"type" => "string", "description" => "Exact text to find"},
          "replace" => %{"type" => "string", "description" => "Text to replace it with"},
          "occurrence" => %{
            "type" => "integer",
            "description" => "Which occurrence (0=first, 1=second, -1=all)",
            "default" => 0
          }
        },
        "required" => ["path", "find", "replace"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "replacements" => %{"type" => "integer", "description" => "Occurrences replaced"}
        },
        "required" => ["path", "replacements"]
      },
      handler: &Handlers.handle("patch_note", &1, &2, &3)
    }
  end

  defp update_section_def do
    %{
      name: "update_section",
      description:
        "Replace content under a specific heading in an existing note. " <>
          "Everything from the matched heading to the next heading of same/higher level is replaced.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Full path of the note"},
          "heading" => %{
            "type" => "string",
            "description" => "Heading text without # prefix (e.g. \"Shopping List\")"
          },
          "content" => %{
            "type" => "string",
            "description" => "New content to place under the heading"
          },
          "level" => %{
            "type" => "integer",
            "description" => "Heading level 1-6 (default 2 for ##)",
            "default" => 2
          }
        },
        "required" => ["path", "heading", "content"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "heading" => %{"type" => "string"}
        },
        "required" => ["path", "heading"]
      },
      handler: &Handlers.handle("update_section", &1, &2, &3)
    }
  end

  defp rename_note_def do
    %{
      name: "rename_note",
      description:
        "Rename or move a note to a new path. Syncs to all connected Obsidian devices.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "old_path" => %{"type" => "string", "description" => "Current path of the note"},
          "new_path" => %{"type" => "string", "description" => "New path for the note"}
        },
        "required" => ["old_path", "new_path"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "old_path" => %{"type" => "string"},
          "new_path" => %{"type" => "string"}
        },
        "required" => ["old_path", "new_path"]
      },
      handler: &Handlers.handle("rename_note", &1, &2, &3)
    }
  end

  defp rename_folder_def do
    %{
      name: "rename_folder",
      description:
        "Rename a folder and all notes within it (including subfolders). " <>
          "All affected notes will be reindexed and synced.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "old_folder" => %{"type" => "string", "description" => "Current folder path"},
          "new_folder" => %{"type" => "string", "description" => "New folder path"}
        },
        "required" => ["old_folder", "new_folder"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "old_folder" => %{"type" => "string"},
          "new_folder" => %{"type" => "string"},
          "notes" => %{"type" => "integer", "description" => "Notes repathed"},
          "attachments" => %{"type" => "integer"}
        },
        "required" => ["old_folder", "new_folder", "notes", "attachments"]
      },
      handler: &Handlers.handle("rename_folder", &1, &2, &3)
    }
  end

  defp delete_note_def do
    %{
      name: "delete_note",
      description:
        "Delete a note from the knowledge base. The deletion will sync to all connected Obsidian devices.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path of the note to delete"
          }
        },
        "required" => ["path"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          # The delete is idempotent, so deleting an absent note still
          # succeeds. This says which of the two actually happened.
          "deleted" => %{
            "type" => "boolean",
            "description" => "false when no note existed at that path"
          }
        },
        "required" => ["path", "deleted"]
      },
      handler: &Handlers.handle("delete_note", &1, &2, &3)
    }
  end

  defp delete_folder_def do
    %{
      name: "delete_folder",
      description:
        "Delete a folder. Empty-only by default: if the folder contains notes or " <>
          "attachments, the call is refused and reports the counts. Pass recursive: true " <>
          "to delete the folder and everything under it. Syncs to all connected devices.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "folder" => %{
            "type" => "string",
            "description" => "Folder path to delete, e.g. \"Projects/Old\""
          },
          "recursive" => %{
            "type" => "boolean",
            "description" => "Delete all notes and attachments under the folder (default false)",
            "default" => false
          }
        },
        "required" => ["folder"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "folder" => %{"type" => "string"},
          "notes" => %{"type" => "integer", "description" => "Notes removed"},
          "attachments" => %{"type" => "integer"}
        },
        "required" => ["folder", "notes", "attachments"]
      },
      handler: &Handlers.handle("delete_folder", &1, &2, &3)
    }
  end

  defp get_attachment_upload_target_def do
    %{
      name: "get_attachment_upload_target",
      description:
        "Get the endpoint and this account's limits for uploading an attachment " <>
          "(image, PDF, audio, video). Returns a URL to POST the file to yourself " <>
          "using the credential already authorizing this connection; the bytes do " <>
          "not pass through this tool. Call before uploading to learn the size cap " <>
          "and which file types the plan allows.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "url" => %{"type" => "string"},
          "method" => %{"type" => "string"},
          "vault_id" => %{"type" => "string", "description" => "Send as the x-vault-id header"},
          # Null means uncapped. The prose renders that as "unlimited"; a
          # client comparing sizes should not have to parse an English word.
          "max_bytes" => %{"type" => ["integer", "null"]},
          "all_types" => %{
            "type" => "boolean",
            "description" => "false means text/* only on this plan"
          }
        },
        "required" => ["url", "method", "vault_id", "all_types"]
      },
      handler: &Handlers.handle("get_attachment_upload_target", &1, &2, &3)
    }
  end

  defp move_attachment_def do
    %{
      name: "move_attachment",
      description:
        "Move or rename a single attachment (image, PDF, or other binary file) to " <>
          "a new path. Syncs to all connected Obsidian devices. The file's content " <>
          "is unchanged; only its path moves.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "old_path" => %{"type" => "string", "description" => "Current path of the attachment"},
          "new_path" => %{"type" => "string", "description" => "New path for the attachment"}
        },
        "required" => ["old_path", "new_path"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "old_path" => %{"type" => "string"},
          "new_path" => %{"type" => "string"}
        },
        "required" => ["old_path", "new_path"]
      },
      handler: &Handlers.handle("move_attachment", &1, &2, &3)
    }
  end
end
