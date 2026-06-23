defmodule EngramWeb.McpController do
  @moduledoc """
  MCP (Model Context Protocol) server — JSON-RPC 2.0 over HTTP POST.
  Dispatches initialize, tools/list, and tools/call to the tool registry.
  """
  use EngramWeb, :controller

  alias Engram.Abuse.OriginStats
  alias Engram.ConversationMeter
  alias Engram.MCP.Tools

  @server_info %{"name" => "engram", "version" => "0.1.0"}
  @capabilities %{"tools" => %{"listChanged" => false}}
  @protocol_version "2025-03-26"

  # engram-app/engram-infra#340 — closed-set map from tool name strings to
  # atoms, used as the cardinality-bounded `:tool` tag on MCP PromEx
  # metrics. Keeps `String.to_atom/1` (atom-table pollution) out of the
  # hot path while keeping the tag stable.
  @tool_atoms %{
    "list_vaults" => :list_vaults,
    "set_vault" => :set_vault,
    "search_notes" => :search_notes,
    "list_tags" => :list_tags,
    "list_folders" => :list_folders,
    "list_folder" => :list_folder,
    "create_folder" => :create_folder,
    "suggest_folder" => :suggest_folder,
    "get_note" => :get_note,
    "create_note" => :create_note,
    "write_note" => :write_note,
    "append_to_note" => :append_to_note,
    "patch_note" => :patch_note,
    "update_section" => :update_section,
    "rename_note" => :rename_note,
    "rename_folder" => :rename_folder,
    "delete_note" => :delete_note
  }

  def handle(conn, %{"jsonrpc" => "2.0", "id" => id, "method" => method} = params) do
    result = dispatch(conn, method, params["params"] || %{})
    send_jsonrpc(conn, id, result)
  end

  # Notification (no id) — acknowledge
  def handle(conn, %{"jsonrpc" => "2.0", "method" => _method}) do
    send_resp(conn, 202, "")
  end

  def handle(conn, _params) do
    send_jsonrpc_error(conn, nil, -32_600, "Invalid Request")
  end

  # Streamable-HTTP clients may open a GET for a server-initiated SSE stream,
  # or DELETE to terminate a session. This server is POST-only JSON-RPC and
  # offers neither, so respond 405 with Allow per the MCP spec — not 404,
  # which clients treat as a missing endpoint and abort the connection.
  def unsupported_transport(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  # -- Method dispatch --

  defp dispatch(_conn, "initialize", _params) do
    {:ok,
     %{
       "protocolVersion" => @protocol_version,
       "serverInfo" => @server_info,
       "capabilities" => @capabilities
     }}
  end

  defp dispatch(_conn, "tools/list", _params) do
    tools =
      Enum.map(Tools.list(), fn t ->
        %{"name" => t.name, "description" => t.description, "inputSchema" => t.inputSchema}
      end)

    {:ok, %{"tools" => tools}}
  end

  defp dispatch(conn, "tools/call", %{"name" => name, "arguments" => args}) do
    case Tools.get(name) do
      {:ok, tool} ->
        user = conn.assigns.current_user
        # §E — record origin fingerprint for daily-rollup aggregation.
        _ = OriginStats.record(user.id, get_req_header_first(conn, "user-agent"))

        case ConversationMeter.tick(user.id) do
          {:rate_limited, reason} ->
            {:error, -32_005, "rate_limited: #{reason}"}

          :ok ->
            case resolve_mcp_vault(user, args, conn) do
              {:error, msg} ->
                {:ok,
                 %{
                   "content" => [%{"type" => "text", "text" => "Error: #{msg}"}],
                   "isError" => true
                 }}

              {:ok, vault} ->
                call_tool(tool, user, vault, args)
            end
        end

      :error ->
        {:error, -32_602, "Unknown tool: #{name}"}
    end
  end

  defp dispatch(_conn, "tools/call", _params) do
    {:error, -32_602, "Invalid params: name and arguments required"}
  end

  defp dispatch(_conn, _method, _params) do
    {:error, -32_601, "Method not found"}
  end

  defp call_tool(tool, user, vault, args) do
    # engram-app/engram-infra#340 — span emits
    # [:engram, :mcp, :tool, :stop] for the PromEx Mcp plugin.
    # Cardinality contract: only `:tool` (bounded enum from
    # `Engram.MCP.Tools.list/0`, ~16 tools) + `:status`.
    tool_atom = Map.get(@tool_atoms, tool.name, :unknown)
    start_mono = System.monotonic_time()

    :telemetry.execute(
      [:engram, :mcp, :tool, :start],
      %{system_time: System.system_time(), monotonic_time: start_mono},
      %{tool: tool_atom}
    )

    {result, status, result_bytes} = run_tool_handler(tool, user, vault, args)

    :telemetry.execute(
      [:engram, :mcp, :tool, :stop],
      %{duration: System.monotonic_time() - start_mono, result_bytes: result_bytes},
      %{tool: tool_atom, status: status}
    )

    result
  end

  defp run_tool_handler(tool, user, vault, args) do
    case tool.handler.(user, vault, args) do
      {:ok, text} ->
        result = {:ok, %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}}
        {result, :ok, byte_size_safe(text)}

      {:error, msg} ->
        result =
          {:ok,
           %{"content" => [%{"type" => "text", "text" => "Error: #{msg}"}], "isError" => true}}

        {result, :error, byte_size_safe(msg)}
    end
  catch
    kind, reason ->
      # T3.0.1 follow-up — never `inspect/1` an exit/throw reason into a
      # response body. The reason can be an arbitrary term originating
      # deep in the call stack (including %Note{} virtual decrypted fields
      # if the throw came out of a crypto path). Log structured details
      # server-side; surface a low-cardinality label to the client.
      require Logger

      Logger.error(
        "mcp tool dispatch trapped",
        Engram.Logger.Metadata.with_category(:error, :http,
          kind: kind,
          reason_label: classify_throw_reason(reason)
        )
      )

      message =
        case kind do
          :error -> Exception.message(reason)
          :exit -> "Process exited"
          :throw -> "Unexpected throw"
        end

      result =
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "Error: #{message}"}],
           "isError" => true
         }}

      {result, :error, byte_size_safe(message)}
  end

  defp byte_size_safe(s) when is_binary(s), do: byte_size(s)
  defp byte_size_safe(_), do: 0

  defp classify_throw_reason(reason) when is_atom(reason), do: reason
  defp classify_throw_reason(%{__exception__: true} = e), do: e.__struct__
  defp classify_throw_reason({tag, _}) when is_atom(tag), do: {tag, :_}
  defp classify_throw_reason(_), do: :unknown

  # -- Vault resolution --

  defp resolve_mcp_vault(user, args, conn) do
    oauth_bound = conn.assigns[:oauth_scope_vault_id]
    requested = args["vault_id"]

    cond do
      is_binary(oauth_bound) and is_nil(requested) ->
        Engram.Vaults.get_vault(user, oauth_bound)

      is_binary(oauth_bound) and to_string(requested) != to_string(oauth_bound) ->
        {:error,
         "OAuth token is bound to vault #{oauth_bound}; tool call requested vault #{requested}"}

      is_binary(oauth_bound) ->
        Engram.Vaults.get_vault(user, oauth_bound)

      is_nil(requested) ->
        {:ok, conn.assigns.current_vault}

      true ->
        case Engram.Vaults.get_vault(user, requested) do
          {:ok, vault} ->
            api_key = conn.assigns[:current_api_key]

            case Engram.Vaults.check_api_key_access(api_key, vault) do
              :ok -> {:ok, vault}
              :forbidden -> {:error, "API key does not have access to vault #{requested}"}
            end

          _ ->
            {:ok, conn.assigns.current_vault}
        end
    end
  end

  # -- Response helpers --

  defp send_jsonrpc(conn, id, {:ok, result}) do
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp send_jsonrpc(conn, id, {:error, code, message}) do
    send_jsonrpc_error(conn, id, code, message)
  end

  defp send_jsonrpc_error(conn, id, code, message) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp get_req_header_first(conn, key) do
    case Plug.Conn.get_req_header(conn, key) do
      [v | _] -> v
      [] -> nil
    end
  end
end
