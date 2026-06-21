defmodule Engram.MCP.Tools do
  @moduledoc """
  MCP tool definitions — name, description, inputSchema, handler.
  Each tool maps to a handler function in Engram.MCP.Handlers.
  """

  alias Engram.MCP.Handlers

  @type tool_def :: %{
          name: String.t(),
          description: String.t(),
          inputSchema: map(),
          handler: (map(), map(), map() -> {:ok, String.t()} | {:error, String.t()})
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
      create_note_def(),
      write_note_def(),
      append_to_note_def(),
      patch_note_def(),
      update_section_def(),
      rename_note_def(),
      rename_folder_def(),
      delete_note_def()
    ]
  end

  @spec get(String.t()) :: {:ok, tool_def()} | :error
  def get(name) do
    case Enum.find(list(), &(&1.name == name)) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end

  # -- Tool definitions --

  defp list_vaults_def do
    %{
      name: "list_vaults",
      description: "List all vaults owned by the current user with IDs, names, and descriptions.",
      inputSchema: %{"type" => "object", "properties" => %{}},
      handler: &Handlers.handle("list_vaults", &1, &2, &3)
    }
  end

  defp set_vault_def do
    %{
      name: "set_vault",
      description:
        "Set the active vault context. Without vault_id, resets to default. " <>
          "Call list_vaults first to see available vaults.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "vault_id" => %{"type" => "integer", "description" => "Vault ID to set as active"}
        }
      },
      handler: &Handlers.handle("set_vault", &1, &2, &3)
    }
  end

  defp search_notes_def do
    %{
      name: "search_notes",
      description:
        "Search your personal knowledge base. Finds relevant notes from your " <>
          "Obsidian vault using semantic search. Use when the user asks about their " <>
          "notes, vault, knowledge, or memory.",
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
      handler: &Handlers.handle("get_note", &1, &2, &3)
    }
  end

  defp create_note_def do
    %{
      name: "create_note",
      description:
        "Create a new note with automatic folder placement. " <>
          "If suggested_folder is omitted, the note is placed automatically.",
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
      handler: &Handlers.handle("delete_note", &1, &2, &3)
    }
  end
end
