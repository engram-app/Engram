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
    "delete_note" => :delete_note,
    "move_attachment" => :move_attachment
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
            dispatch_tool(tool, user, args, conn)
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

  @doc false
  def run_tool_handler(tool, user, vault, args) do
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
          tool: tool.name,
          kind: kind,
          reason_label: classify_throw_reason(reason)
        )
      )

      message = safe_trapped_message(kind, reason, __STACKTRACE__)

      result =
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "Error: #{message}"}],
           "isError" => true
         }}

      {result, :error, byte_size_safe(message)}
  end

  # Builds a client-safe message for a trapped tool-handler failure.
  #
  # For `:error`, the raw `reason` may be a bare term (e.g. the atom
  # `:function_clause`) rather than an exception struct, so we cannot call
  # `Exception.message/1` on it directly — that itself raises and would escape
  # the trap into a 500. `Exception.normalize/3` coerces any reason into an
  # exception struct. We surface only its struct name (low-cardinality, no user
  # data) and never its message, which can embed the offending term — including
  # decrypted %Note{} fields. Full detail is logged server-side above.
  @doc false
  def safe_trapped_message(:error, reason, stacktrace) do
    exception = Exception.normalize(:error, reason, stacktrace)
    # Module name only (e.g. "KeyError") — never inspect/Exception.message the
    # struct, whose contents can embed decrypted %Note{} fields (T3.0.6).
    type = exception.__struct__ |> Module.split() |> List.last()
    "Tool execution failed (#{type})"
  end

  def safe_trapped_message(:exit, _reason, _stacktrace), do: "Process exited"
  def safe_trapped_message(:throw, _reason, _stacktrace), do: "Unexpected throw"

  defp byte_size_safe(s) when is_binary(s), do: byte_size(s)
  defp byte_size_safe(_), do: 0

  defp classify_throw_reason(reason) when is_atom(reason), do: reason
  defp classify_throw_reason(%{__exception__: true} = e), do: e.__struct__
  defp classify_throw_reason({tag, _}) when is_atom(tag), do: {tag, :_}
  defp classify_throw_reason(_), do: :unknown

  # -- Tool dispatch (vault context) --

  # `list_vaults` and `set_vault` don't operate on a single vault's contents, so
  # they must never be blocked by vault resolution — `list_vaults` in particular
  # is the discovery call a client needs to escape a multi-vault or
  # dangling-default state (#951). `list_vaults` is handed the credential-scoped
  # vault set so it can't advertise vaults this token/key cannot use (#729).
  defp dispatch_tool(%{name: "list_vaults"} = tool, user, args, conn) do
    call_tool(tool, user, accessible_vaults(user, conn), args)
  end

  defp dispatch_tool(%{name: "set_vault"} = tool, user, args, _conn) do
    call_tool(tool, user, nil, args)
  end

  defp dispatch_tool(tool, user, args, conn) do
    case resolve_mcp_vault(user, args, conn) do
      {:error, msg} ->
        {:ok, %{"content" => [%{"type" => "text", "text" => "Error: #{msg}"}], "isError" => true}}

      {:ok, vault} ->
        call_tool(tool, user, vault, args)
    end
  end

  # The vaults this credential can actually use: an OAuth-bound token sees only
  # its bound vault; a restricted API key sees only its permitted vaults; an
  # unrestricted credential sees all of the user's vaults.
  defp accessible_vaults(user, conn) do
    oauth_bound = conn.assigns[:oauth_scope_vault_id]
    api_key = conn.assigns[:current_api_key]

    Engram.Vaults.list_vaults(user)
    |> maybe_filter_oauth(oauth_bound)
    |> Enum.filter(&(Engram.Vaults.check_api_key_access(api_key, &1) == :ok))
  end

  defp maybe_filter_oauth(vaults, nil), do: vaults

  defp maybe_filter_oauth(vaults, bound) when is_binary(bound),
    do: Enum.filter(vaults, &(to_string(&1.id) == to_string(bound)))

  # -- Vault resolution --

  # Resolves which vault a tool call targets. MCP is stateless — there is no
  # active-vault session — so the vault comes from exactly one of: the OAuth
  # token's bound vault, an explicit `vault_id` arg, or (only when unambiguous)
  # the user's single vault. It NEVER silently falls back to the default vault:
  # doing so is #985, where an AI was fed the wrong vault's data with no error.
  defp resolve_mcp_vault(user, args, conn) do
    oauth_bound = conn.assigns[:oauth_scope_vault_id]
    requested = args["vault_id"]

    cond do
      # OAuth token bound to a specific vault: it is authoritative. A matching
      # (or absent) request is honored; a mismatch is a loud error, not a
      # silent override.
      is_binary(oauth_bound) ->
        if is_nil(requested) or to_string(requested) == to_string(oauth_bound) do
          Engram.Vaults.get_vault(user, oauth_bound)
        else
          {:error,
           "This connection is bound to vault #{oauth_bound} and cannot access vault " <>
             "#{requested}. Reconnect with an all-vaults grant (or that vault) to switch."}
        end

      # Unbound (all-vaults OAuth grant or API key): the caller selects per call.
      is_binary(requested) ->
        resolve_requested_vault(user, requested, conn)

      # Nothing specified and nothing bound: unambiguous only when the credential
      # can reach exactly one vault. Consider the ACCESSIBLE set (not every vault
      # the user owns) so a restricted key with one permitted vault just works.
      true ->
        case accessible_vaults(user, conn) do
          [only] ->
            {:ok, only}

          [] ->
            {:error, "No vault found. Sync from Obsidian to create one."}

          _many ->
            {:error,
             "You own multiple vaults — specify which one. Call list_vaults to see the IDs, " <>
               "then pass vault_id on this tool call."}
        end
    end
  end

  defp resolve_requested_vault(user, requested, conn) do
    case Engram.Vaults.get_vault(user, requested) do
      {:ok, vault} ->
        api_key = conn.assigns[:current_api_key]

        case Engram.Vaults.check_api_key_access(api_key, vault) do
          :ok -> {:ok, vault}
          :forbidden -> {:error, "API key does not have access to vault #{requested}"}
        end

      _ ->
        {:error,
         "Vault not found: #{requested}. Call list_vaults to see the vault IDs you can use."}
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
