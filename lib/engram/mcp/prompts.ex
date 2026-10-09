defmodule Engram.MCP.Prompts do
  @moduledoc """
  MCP prompts: user-invoked templates. Clients surface them as slash commands
  (Claude Code shows `/mcp__engram__recall`). Each renders to one user message
  that steers the model through tools we already serve, so a prompt adds no
  data path and needs no per-user state.

  Tool names in the text are backticked; the test suite checks every one is a
  listed tool, so renaming a tool cannot silently strand a prompt.
  """

  @prompts [
    %{
      name: "recall",
      title: "Recall what I know",
      description:
        "Search the vault for a topic and summarize what your notes say, with sources.",
      arguments: [
        %{name: "topic", description: "What to look up", required: true}
      ],
      template: """
      Look up what my Engram vault says about: {topic}

      1. Call `list_vaults` if you do not know which vault to use.
      2. Call `search_notes` with that topic. Try one or two rephrasings if the first results are thin.
      3. Read the most relevant results in full with `get_notes`.
      4. Summarize what my notes say, citing each point with the note path it came from.
      5. Say plainly where my notes are silent or contradict each other. Do not fill gaps from general knowledge without marking it.
      """
    },
    %{
      name: "save_conversation",
      title: "Save this conversation as a note",
      description: "Write the key points of the current conversation into a new vault note.",
      arguments: [
        %{
          name: "title",
          description: "Note title (optional; one is proposed if omitted)",
          required: false
        },
        %{
          name: "folder",
          description: "Folder to save into (optional; one is suggested if omitted)",
          required: false
        }
      ],
      template: """
      Save the key points of this conversation to my Engram vault as a new note.

      - Title: {title}
      - Folder: {folder}

      1. Call `list_vaults` if you do not know which vault to use.
      2. If no folder was given, call `suggest_folder` with a short summary and use its top suggestion.
      3. Write the note in Markdown: a one-paragraph summary, then decisions, open questions and next steps as lists. Leave out small talk.
      4. Before saving, call `search_notes` for the topic. If a closely matching note exists, ask me whether to append to it with `append_to_note` instead.
      5. Save with `create_note` and tell me the path you used.
      """
    },
    %{
      name: "find_connections",
      title: "Find connections for a note",
      description:
        "Find related notes and suggest [[wikilinks]] to add, without editing anything.",
      arguments: [
        %{name: "path", description: "Path of the note, e.g. Projects/Engram.md", required: true}
      ],
      template: """
      Find notes in my Engram vault related to the note at: {path}

      1. Call `list_vaults` if you do not know which vault to use.
      2. Read the note with `get_notes`.
      3. Call `search_notes` for its two or three main ideas.
      4. List the related notes you found, each with one line on how it connects and the [[wikilink]] I could add.
      5. Do not edit any note. If I ask you to add the links afterwards, use `edit_note`.
      """
    }
  ]

  @by_name Map.new(@prompts, &{&1.name, &1})

  @doc "The exact `prompts/list` payload, also listed in the server card."
  @spec wire_list() :: [map()]
  def wire_list do
    Enum.map(@prompts, fn p ->
      %{
        "name" => p.name,
        "title" => p.title,
        "description" => p.description,
        "arguments" =>
          Enum.map(p.arguments, fn a ->
            %{"name" => a.name, "description" => a.description, "required" => a.required}
          end)
      }
    end)
  end

  @doc """
  Renders a prompt. Errors are `{:error, message}` for the caller to send as
  `-32602 Invalid params`: an unknown name, a missing required argument, or
  arguments that are not a map of strings.
  """
  @spec get(term(), term()) :: {:ok, map()} | {:error, String.t()}
  def get(name, args) when is_binary(name) and is_map(args) do
    with {:ok, prompt} <- fetch(name),
         :ok <- validate(prompt, args) do
      {:ok,
       %{
         "description" => prompt.description,
         "messages" => [
           %{"role" => "user", "content" => %{"type" => "text", "text" => render(prompt, args)}}
         ]
       }}
    end
  end

  def get(_name, _args),
    do: {:error, "Invalid params: name must be a string and arguments an object"}

  defp fetch(name) do
    case Map.fetch(@by_name, name) do
      {:ok, prompt} -> {:ok, prompt}
      :error -> {:error, "Unknown prompt: #{name}"}
    end
  end

  defp validate(prompt, args) do
    cond do
      not Enum.all?(args, fn {_k, v} -> is_binary(v) end) ->
        {:error, "Invalid params: prompt arguments must be strings"}

      missing = Enum.find(prompt.arguments, &(&1.required and blank?(args[&1.name]))) ->
        {:error, "Invalid params: missing required argument #{missing.name}"}

      true ->
        :ok
    end
  end

  defp render(prompt, args) do
    Enum.reduce(prompt.arguments, prompt.template, fn a, text ->
      value = if blank?(args[a.name]), do: "(not given)", else: String.trim(args[a.name])
      String.replace(text, "{#{a.name}}", value)
    end)
  end

  defp blank?(v), do: not is_binary(v) or String.trim(v) == ""
end
