defmodule Engram.MCP.ToolError do
  @moduledoc """
  The one shape of an MCP tool execution error (`isError: true`), with a
  stable machine-readable code.

  A handler returns `{:error, message}` or, when the cause is known,
  `error(code, message)`. Either way the client gets the same result:
  `content` text the model reads, ending in `(Engram error code: <code>)`,
  and the code again under `_meta["engram.page/error_code"]` for programs.
  A bare message carries `tool_error`, so EVERY failure Engram returns is
  tagged, which is how a client tells ours from its own safety refusals
  (user feedback 2026-10-24, ChatGPT).

  Not `structuredContent`: a client validates that against the tool's
  `outputSchema` even on an error result, and an error object would fail it.

  Codes are a public contract. Add one here; never rename one.
  """

  @codes ~w(
    vault_not_found vault_required vault_ambiguous vault_read_only
    path_conflict version_conflict invalid_path invalid_arguments
    note_not_found note_too_large notes_cap_exceeded rate_limited tool_error
  )a

  @meta_key "engram.page/error_code"

  @type code ::
          :vault_not_found
          | :vault_required
          | :vault_ambiguous
          | :vault_read_only
          | :path_conflict
          | :version_conflict
          | :invalid_path
          | :invalid_arguments
          | :note_not_found
          | :note_too_large
          | :notes_cap_exceeded
          | :rate_limited
          | :tool_error
  @type t :: String.t() | {code(), String.t()}
  @type result :: %{
          required(String.t()) => boolean() | [map(), ...] | %{String.t() => String.t()}
        }

  @spec codes() :: [code(), ...]
  def codes, do: @codes

  @spec error(code(), String.t()) :: {:error, {code(), String.t()}}
  def error(code, message) when code in @codes and is_binary(message),
    do: {:error, {code, message}}

  @doc "The `CallToolResult` map for an error."
  @spec result(t()) :: result()
  def result({code, message}) when code in @codes and is_binary(message) do
    %{
      "content" => [
        %{"type" => "text", "text" => "Error: #{message}\n(Engram error code: #{code})"}
      ],
      "isError" => true,
      "_meta" => %{@meta_key => Atom.to_string(code)}
    }
  end

  def result(message) when is_binary(message), do: result({:tool_error, message})

  @doc "The human-readable message, without the code."
  @spec message(t()) :: String.t()
  def message({_code, message}), do: message
  def message(message) when is_binary(message), do: message
end
