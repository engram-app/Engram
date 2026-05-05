defmodule EngramWeb.McpController do
  @moduledoc """
  MCP (Model Context Protocol) server — JSON-RPC 2.0 over HTTP POST.
  Dispatches initialize, tools/list, and tools/call to the tool registry.
  """
  use EngramWeb, :controller

  alias Engram.MCP.Tools

  @server_info %{"name" => "engram", "version" => "0.1.0"}
  @capabilities %{"tools" => %{"listChanged" => false}}
  @protocol_version "2025-03-26"

  def handle(conn, %{"jsonrpc" => "2.0", "id" => id, "method" => method} = params) do
    result = dispatch(conn, method, params["params"] || %{})
    send_jsonrpc(conn, id, result)
  end

  # Notification (no id) — acknowledge
  def handle(conn, %{"jsonrpc" => "2.0", "method" => _method}) do
    send_resp(conn, 202, "")
  end

  def handle(conn, _params) do
    send_jsonrpc_error(conn, nil, -32600, "Invalid Request")
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

        case resolve_mcp_vault(user, args, conn) do
          {:error, msg} ->
            {:ok,
             %{"content" => [%{"type" => "text", "text" => "Error: #{msg}"}], "isError" => true}}

          {:ok, vault} ->
            call_tool(tool, user, vault, args)
        end

      :error ->
        {:error, -32602, "Unknown tool: #{name}"}
    end
  end

  defp dispatch(_conn, "tools/call", _params) do
    {:error, -32602, "Invalid params: name and arguments required"}
  end

  defp dispatch(_conn, _method, _params) do
    {:error, -32601, "Method not found"}
  end

  defp call_tool(tool, user, vault, args) do
    case tool.handler.(user, vault, args) do
      {:ok, text} ->
        {:ok, %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}}

      {:error, msg} ->
        {:ok, %{"content" => [%{"type" => "text", "text" => "Error: #{msg}"}], "isError" => true}}
    end
  catch
    kind, reason ->
      message =
        case kind do
          :error -> Exception.message(reason)
          :exit -> "Process exited: #{inspect(reason)}"
          :throw -> "Unexpected throw: #{inspect(reason)}"
        end

      {:ok,
       %{
         "content" => [%{"type" => "text", "text" => "Error: #{message}"}],
         "isError" => true
       }}
  end

  # -- Vault resolution --

  defp resolve_mcp_vault(user, args, conn) do
    case args["vault_id"] do
      nil ->
        {:ok, conn.assigns.current_vault}

      vault_id ->
        case Engram.Vaults.get_vault(user, vault_id) do
          {:ok, vault} ->
            api_key = conn.assigns[:current_api_key]

            case Engram.Vaults.check_api_key_access(api_key, vault) do
              :ok -> {:ok, vault}
              :forbidden -> {:error, "API key does not have access to vault #{vault_id}"}
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
end
