defmodule EngramWeb.McpController do
  @moduledoc """
  MCP (Model Context Protocol) server — JSON-RPC 2.0 over HTTP POST.
  Dispatches initialize, tools/list, and tools/call to the tool registry.
  """
  use EngramWeb, :controller

  alias Engram.Abuse.OriginStats
  alias Engram.MCP.Tools

  @server_info %{"name" => "engram", "version" => "0.1.0"}
  @capabilities %{"tools" => %{"listChanged" => false}}
  @protocol_version "2025-03-26"

  # Handshake fields are free text from the far side of the connection, so they
  # are length-bounded before they reach the log — an unbounded `clientInfo` is
  # billed as log volume on every reconnect.
  @handshake_field_limit 64

  # engram-app/engram-infra#340 — closed-set map from tool name strings to
  # atoms, used as the cardinality-bounded `:tool` tag on MCP PromEx metrics.
  # Derived from the real roster at COMPILE time, so a new tool can no longer
  # silently degrade to the `:unknown` bucket by being forgotten here.
  #
  # `String.to_atom/1` is safe precisely because this runs at compile time over
  # a closed list: the atoms intern once while compiling and this module only
  # reads the finished map afterwards — nothing per-request touches the atom
  # table, which was the whole objection to `String.to_atom/1` here.
  @tool_atoms Map.new(Tools.list(), &{&1.name, String.to_atom(&1.name)})

  # The same exempt set the tool definitions use, read once at compile time
  # rather than restated here (see `dispatch_tool/4`).
  @vault_exempt Tools.vault_scoping_exempt()

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
  #
  # One action per verb, deliberately. A single shared action is the shape
  # `Config.CSRFRoute` flags: a GET route reaching the same controller action as
  # a state-changing verb is how a mutation gets triggerable by navigation. It
  # is not a real CSRF here (both answers are a bodyless 405 that changes
  # nothing), but the router should not carry the shape at all. Keep them split
  # even though the bodies are identical.
  def unsupported_transport_get(conn, _params), do: method_not_allowed(conn)

  def unsupported_transport_delete(conn, _params), do: method_not_allowed(conn)

  defp method_not_allowed(conn) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  @doc """
  Structured metadata for the `mcp_handshake` log line.

  Public only so it can be unit-tested without asserting on rendered log text.

  We answer `initialize` with a fixed `@protocol_version` and negotiate nothing,
  so the version the client ASKED for is not otherwise recorded anywhere. That
  is the fact needed to decide whether a newer protocol revision can drop the
  legacy path or has to dual-serve it, hence `mcp_protocol_requested` alongside
  `mcp_protocol_served`.
  """
  @spec handshake_metadata(term()) :: keyword()
  # `is_non_struct_map/1`, not `is_map/1`, in BOTH places. Two reasons a
  # non-plain-map reaches here:
  #
  #   * JSON-RPC 2.0 allows array-form `params`, and an empty list is truthy, so
  #     `params["params"] || %{}` passes a list straight through.
  #   * The endpoint parses `:multipart` with `pass: ["*/*"]`, so an
  #     authenticated multipart POST with a file field named `params[clientInfo]`
  #     puts a `%Plug.Upload{}` here. A struct matches `%{}` but does not
  #     implement `Access`, so `info["name"]` raises and the handshake 500s.
  def handshake_metadata(params) when not is_non_struct_map(params),
    do: handshake_metadata(%{})

  def handshake_metadata(params) do
    client =
      case params["clientInfo"] do
        info when is_non_struct_map(info) -> info
        _ -> %{}
      end

    Engram.Logger.Metadata.with_category(:info, :lifecycle,
      mcp_protocol_requested: bounded(params["protocolVersion"]),
      mcp_client_name: bounded(client["name"]),
      mcp_client_version: bounded(client["version"]),
      mcp_protocol_served: @protocol_version
    )
  end

  defp bounded(nil), do: "unknown"

  # Byte guard FIRST. `String.slice/3` counts graphemes, and a grapheme cluster
  # is unbounded in size — 64 clusters of "a" plus 5,000 combining marks is
  # ~640 KB that survives "bounded at 64" intact, turning one authenticated
  # handshake into megabytes of Loki ingest. That is the exact cost this bound
  # exists to prevent.
  #
  # Labelled, not truncated: `binary_slice/3` would cut mid-codepoint and hand
  # the JSON formatter invalid UTF-8, crashing the log call. An oversize value
  # has no diagnostic worth anyway — the fact worth keeping is that it was
  # oversize. 4 bytes per grapheme is the UTF-8 maximum, so anything under the
  # guard is genuinely bounded by the slice below.
  defp bounded(value) when is_binary(value) and byte_size(value) > @handshake_field_limit * 4,
    do: "<oversize>"

  defp bounded(value) when is_binary(value),
    do: String.slice(value, 0, @handshake_field_limit)

  # A non-string handshake field is labelled by TYPE, never rendered. Rendering
  # it would put an arbitrary client-supplied term into Loki, and the value
  # carries no diagnostic worth that: what matters is that the client sent the
  # wrong shape. Same treatment `tool_name_label/1` gives a bad tool name, and
  # the JSON types are the same closed set.
  defp bounded(value), do: tool_name_label(value)

  # -- Method dispatch --

  defp dispatch(_conn, "initialize", params) do
    require Logger

    Logger.info("mcp_handshake", handshake_metadata(params))

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
        base = %{
          "name" => t.name,
          "description" => t.description,
          "inputSchema" => t.inputSchema
        }

        # Only for converted tools (#1660). An `outputSchema` a tool cannot
        # honour is worse than none: a client generates types from it.
        case t[:outputSchema] do
          nil -> base
          schema -> Map.put(base, "outputSchema", schema)
        end
      end)

    {:ok, %{"tools" => tools}}
  end

  defp dispatch(conn, "tools/call", %{"name" => name, "arguments" => args}) do
    start_mono = System.monotonic_time()

    # OriginStats runs for every call against a KNOWN tool regardless of whether
    # its arguments turn out to be valid — a client that always sends malformed
    # args must not be invisible to abuse fingerprinting (#1491/#1492).
    #
    # There is no usage metering here any more. `ai_searches_per_day` is charged
    # inside `Engram.Search.search/4`, the funnel every retrieval passes through,
    # so this controller cannot forget to charge a new retrieval tool. Volume is
    # bounded by `EngramWeb.Plugs.PreAuthRateLimit` on the shared pipeline.
    with {:ok, tool} <- Tools.get(name),
         user = conn.assigns.current_user,
         # §E — record origin fingerprint for daily-rollup aggregation.
         _ = OriginStats.record(user.id, List.first(get_req_header(conn, "user-agent"))),
         :ok <- validate_tool_args(tool, args) do
      dispatch_tool(tool, user, normalize_args(tool, args), conn)
    else
      :error ->
        {:error, -32_602, "Unknown tool: #{tool_name_label(name)}"}

      {:error, tool_name, msg} ->
        # `with`/`else` doesn't carry earlier clauses' bindings into `else` —
        # validate_tool_args threads the tool name through its own error
        # value rather than relying on an outer `tool` binding here.
        emit_rejected_call_telemetry(tool_name, start_mono, msg)

        # A Tool Execution Error, not a Protocol Error. The spec reserves
        # protocol errors for an unknown tool or a malformed request, and
        # routes anything the model could fix by retrying with different
        # arguments through `isError: true` so it can self-correct — a
        # protocol error just aborts the call (SEP-1303). The rejection is
        # unchanged: the handler still never runs.
        error_result(msg)
    end
  end

  defp dispatch(_conn, "tools/call", _params) do
    {:error, -32_602, "Invalid params: name and arguments required"}
  end

  defp dispatch(_conn, _method, _params) do
    {:error, -32_601, "Method not found"}
  end

  defp tool_name_label(name) when is_binary(name), do: name
  defp tool_name_label(name) when is_map(name), do: "<object>"
  defp tool_name_label(name) when is_list(name), do: "<array>"
  defp tool_name_label(name) when is_boolean(name), do: to_string(name)
  defp tool_name_label(name) when is_number(name), do: to_string(name)
  defp tool_name_label(nil), do: "null"

  # Emits the same [:engram, :mcp, :tool, :stop] event `call_tool/4` emits on
  # a real dispatch, so a call rejected by argument validation is still
  # visible on the MCP PromEx dashboards instead of disappearing entirely
  # (found in adversarial review of #1491/#1492's fix).
  defp emit_rejected_call_telemetry(tool_name, start_mono, msg) do
    tool_atom = Map.get(@tool_atoms, tool_name, :unknown)

    :telemetry.execute(
      [:engram, :mcp, :tool, :stop],
      %{duration: System.monotonic_time() - start_mono, result_bytes: byte_size_safe(msg)},
      %{tool: tool_atom, status: :invalid_args}
    )
  end

  # #1491/#1492 — the JSON-RPC layer never checked a call's arguments against
  # the tool's own advertised inputSchema, so a caller using the wrong key
  # name (or an absent/null/wrong-typed arg) fell through each handler's
  # `args["key"] || default` fallback and silently ran against that default
  # (e.g. vault root) instead of erroring. Validates EVERY declared property
  # present in `args` (not just required ones — an optional arg like
  # `vault_id` sent as the wrong type is the same silent-wrong-target failure
  # class), plus presence for required ones. An explicit "" stays valid for
  # tools like list_folder that use it to mean "root". `arguments` itself may
  # not be a JSON object at all (client sent a string/array/null) — reject
  # that outright, independent of whether the tool has any required args, so
  # it can't reach a handler's map access.
  defp validate_tool_args(tool, args) when not is_map(args) do
    {:error, tool.name, "Arguments must be an object"}
  end

  defp validate_tool_args(tool, args) do
    properties = get_in(tool.inputSchema, ["properties"]) || %{}
    required = get_in(tool.inputSchema, ["required"]) || []

    invalid =
      Enum.filter(Map.keys(properties), fn key ->
        case Map.get(args, key) do
          nil -> key in required
          value -> not matches_schema_type?(value, Map.get(properties, key))
        end
      end)

    case invalid do
      [] -> :ok
      _ -> {:error, tool.name, "Invalid or missing argument(s): #{Enum.join(invalid, ", ")}"}
    end
  end

  # Coerces a whole-number float (e.g. `2.0`) into a real integer for any
  # property whose schema declares `"type" => "integer"`, so handlers that
  # pattern-match on integer literals (e.g. patch_note's `occurrence: -1`)
  # get an actual integer rather than a float that passed validation but
  # can't match those clauses (found in adversarial review of #1491/#1492's
  # fix — update_section's `level` and patch_note's `occurrence` are both
  # declared `"integer"` but were never coerced, so a JSON client that always
  # encodes numbers as floats could pass validation and still misbehave).
  defp normalize_args(tool, args) when is_map(args) do
    properties = get_in(tool.inputSchema, ["properties"]) || %{}

    Enum.reduce(properties, args, fn {key, schema}, acc ->
      case {schema["type"], Map.get(acc, key)} do
        {"integer", value} when is_float(value) -> Map.put(acc, key, trunc(value))
        _ -> acc
      end
    end)
  end

  defp normalize_args(_tool, args), do: args

  defp matches_schema_type?(value, %{"type" => "string"}), do: is_binary(value)
  defp matches_schema_type?(value, %{"type" => "boolean"}), do: is_boolean(value)
  defp matches_schema_type?(value, %{"type" => "number"}), do: is_number(value)

  defp matches_schema_type?(value, %{"type" => "integer"}),
    do: is_integer(value) or (is_float(value) and value == trunc(value))

  defp matches_schema_type?(value, %{"type" => "array"} = schema) do
    is_list(value) and
      (is_nil(schema["items"]) or Enum.all?(value, &matches_schema_type?(&1, schema["items"])))
  end

  defp matches_schema_type?(value, %{"type" => "object"}), do: is_map(value)
  # No declared type, or a type this validator doesn't model (e.g. a future
  # JSON-Schema union type) — fail open rather than crash the whole
  # validation gate on a schema shape we don't recognize.
  defp matches_schema_type?(_value, _schema), do: true

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
        {{:ok, text_result(text)}, :ok, byte_size_safe(text)}

      # A converted tool (#1660) answers with both renderings. `content` stays
      # mandatory — `structuredContent` is additive, and a client that ignores
      # it must still get a usable answer.
      {:ok, text, structured} when is_map(structured) ->
        result = Map.put(text_result(text), "structuredContent", structured)
        # `text` only, deliberately. A previous pass added a second Jason.encode
        # here so the size metric would count structuredContent too. That was
        # wrong three ways: prod relabels
        # `engram_prom_ex_mcp_tool_result_bytes_bucket` to drop (engram-infra
        # ecs.tf, "ZERO dashboard/alert consumers"), the extra encode costs
        # ~7.6ms on a 225KB payload for a metric nobody reads, and its error
        # fallback swallowed the one signal that catches a non-JSON-safe
        # payload. The metric also documents itself as LLM context cost, which
        # is `content` — structuredContent is for programmatic use.
        {{:ok, result}, :ok, byte_size_safe(text)}

      {:error, msg} ->
        {error_result(msg), :error, byte_size_safe(msg)}
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
          reason_label: Engram.Telemetry.error_kind(reason)
        )
      )

      message = safe_trapped_message(kind, reason, __STACKTRACE__)

      {error_result(message), :error, byte_size_safe(message)}
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

  # -- Tool dispatch (vault context) --

  # `list_vaults` and `set_vault` don't operate on a single vault's contents, so
  # they aren't blocked by the controller's own vault resolution — `list_vaults`
  # is the discovery call a client uses to pick a vault in a multi-vault account,
  # and to recover when there is no usable default (deleted default #951, or a
  # restricted key that excludes it). That recovery works because MCP is off the
  # VaultPlug pipeline (see router.ex) — no default-vault 404/403 gates it.
  # `list_vaults` is handed the credential-scoped vault set so it can't advertise
  # vaults this token/key cannot use (#729).
  #
  # set_vault only validates + echoes, but it MUST respect the credential's
  # scope — it sees the same accessible set as list_vaults, so a bound token
  # can't confirm the name/existence of a vault it was scoped away from (#729).
  defp dispatch_tool(%{name: name} = tool, user, args, conn) when name in @vault_exempt do
    call_tool(tool, user, accessible_vaults(user, conn), args)
  end

  # search_notes defaults to ALL the credential's vaults (product decision
  # 2026-07-10): a bare search spans everything the credential can reach; an
  # explicit vault_id narrows to one.
  defp dispatch_tool(%{name: "search_notes"} = tool, user, args, conn) do
    if is_binary(args["vault_id"]) do
      resolve_and_call(tool, user, args, conn)
    else
      search_across_accessible(tool, user, args, conn)
    end
  end

  defp dispatch_tool(tool, user, args, conn) do
    resolve_and_call(tool, user, args, conn)
  end

  defp resolve_and_call(tool, user, args, conn) do
    case resolve_mcp_vault(user, args, conn) do
      {:error, msg} -> error_result(msg)
      {:ok, vault} -> call_tool(tool, user, vault, args)
    end
  end

  # Picks the vault context for a bare (no vault_id) search. A credential that
  # reaches exactly one vault searches it directly; anything wider goes through
  # one Qdrant query carrying an any-match filter over the accessible set, so
  # the result set can never include a vault the credential was scoped away
  # from (#729).
  defp search_across_accessible(tool, user, args, conn) do
    case resolve_bare_vault(user, conn) do
      {:ok, only} -> call_tool(tool, user, only, args)
      {:many, many} -> call_tool(tool, user, {:cross_vault, many}, args)
      {:error, msg} -> error_result(msg)
    end
  end

  # The credential's vault set for a call that named no vault: exactly one
  # reachable vault, more than one, or none. Fetches the vault list ONCE and
  # derives both the accessible set and the empty-set message from it (no second
  # list_vaults query on the error path), and never widens past the scoped list.
  # Callers differ only in what they do with `{:many, _}`: a bare search spans
  # them, everything else fails loud (#985).
  defp resolve_bare_vault(user, conn) do
    all = Engram.Vaults.list_vaults(user)

    case scope_vaults(all, conn) do
      [only] -> {:ok, only}
      [] -> {:error, no_vault_message_for(all)}
      many -> {:many, many}
    end
  end

  defp text_result(text),
    do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}

  defp error_result(msg),
    do: {:ok, %{"content" => [%{"type" => "text", "text" => "Error: #{msg}"}], "isError" => true}}

  # -- Vault resolution --

  # "Which vaults can THIS credential reach" — answered by Engram.Permissions,
  # which intersects the OAuth grant's vault set with the API key's restricted
  # set (either may be unrestricted). Every vault-scope decision (resolve,
  # set_vault, list_vaults) routes through here, and here through Permissions,
  # so the privacy boundary is enforced in exactly one place.
  defp accessible_vaults(user, conn), do: scope_vaults(Engram.Vaults.list_vaults(user), conn)

  # Narrows an already-loaded vault list to what the credential may reach, so a
  # caller that already has the list (e.g. bare search) doesn't re-query it.
  defp scope_vaults(vaults, conn),
    do: Engram.Permissions.filter(Engram.Permissions.vault_scope(conn), vaults)

  # Resolves which vault a tool call targets. MCP is stateless — there is no
  # active-vault session — so the vault comes from either an explicit `vault_id`
  # arg or (only when unambiguous) the credential's single reachable vault. It
  # NEVER silently falls back to the default vault (#985). Both branches decide
  # against the ACCESSIBLE set, so OAuth binding + API-key scope are enforced
  # once, here.
  defp resolve_mcp_vault(user, args, conn) do
    case args["vault_id"] do
      # Named vault → single lookup + scope check. No need to load every vault.
      requested when is_binary(requested) ->
        resolve_requested_vault(user, requested, conn)

      # Bare call → resolve the credential's sole reachable vault, or fail loud.
      _ ->
        case resolve_bare_vault(user, conn) do
          {:many, _vaults} ->
            {:error,
             "This connection can reach more than one vault — specify which. Pass " <>
               "vault_id on this tool call, as either the vault's name or its UUID. " <>
               "Call list_vaults to see them."}

          ok_or_error ->
            ok_or_error
        end
    end
  end

  # A caller-named vault: enforce the credential's scope with a single get_vault
  # (not a full list). vault_denied_message/2 re-derives the specific reason on
  # the error path only.
  defp resolve_requested_vault(user, requested, conn) do
    # by_ref, not get_vault/2: a model naming the vault it wants ("Engram")
    # should not have to spend a list_vaults call first just to learn the UUID.
    # The scope check below is unchanged and still runs on the resolved vault,
    # so a name cannot reach anything a UUID could not.
    with {:ok, vault} <- Engram.Vaults.get_vault_by_ref(user, requested),
         :ok <- Engram.Permissions.check(Engram.Permissions.vault_scope(conn), vault) do
      {:ok, vault}
    else
      # Two vaults share this display name (#1665). Naming the candidates is
      # what makes the error actionable — but only for a credential that can
      # already see every vault. For a restricted one it would re-open the
      # enumeration oracle `vault_denied_message/2` exists to close, so that
      # path falls through to the same scope-shaped refusal as everything else.
      {:error, {:ambiguous_ref, ids}} ->
        if Engram.Permissions.vault_scope(conn) == :all do
          {:error,
           "#{length(ids)} vaults are named #{requested}. Pass a UUID or a slug " <>
             "instead — slugs are unique. Candidates: #{Enum.join(ids, ", ")}."}
        else
          {:error, vault_denied_message(requested, conn)}
        end

      _ ->
        {:error, vault_denied_message(requested, conn)}
    end
  end

  # Explains why a requested vault isn't reachable — an OAuth grant's vault set,
  # an API-key restriction, or a genuinely unknown vault — so the caller gets
  # actionable guidance instead of a flat "not found".
  defp vault_denied_message(requested, conn) do
    cond do
      is_list(conn.assigns[:oauth_scope_vault_ids]) ->
        "This connection is authorized for #{length(conn.assigns.oauth_scope_vault_ids)} " <>
          "vault(s) and cannot access vault #{requested}. Call list_vaults to see which " <>
          "ones it can reach, or reconnect with a grant that includes this vault."

      # Keyed on the credential's SCOPE, never on whether `requested` exists.
      #
      # This branch used to probe with a lookup, which was tolerable while
      # vault_id took only a UUID — you had to guess a v4 to learn anything.
      # Once a NAME resolves, the same probe turns into a dictionary oracle: a
      # third party holding a vault-restricted API key could walk a wordlist
      # ("Work", "Journal", "Taxes") and read a clean yes/no per guess off the
      # differing message. Vault names are encrypted at rest precisely because
      # they are sensitive, and `set_vault` already refuses to distinguish the
      # two cases — these two paths must not disagree about that rule.
      #
      # A restricted credential therefore gets one answer for every ref, real
      # or invented. It loses nothing: the guidance is identical either way.
      Engram.Permissions.vault_scope(conn) != :all ->
        "This connection is restricted to a subset of your vaults and cannot " <>
          "access vault #{requested}. Call list_vaults to see the ones it can use."

      true ->
        "Vault not found: #{requested}. vault_id takes a vault's name or its UUID; " <>
          "call list_vaults to see the ones this connection can use."
    end
  end

  # Empty accessible set: distinguish "user has no vaults at all" (sync to make
  # one) from "the credential can reach none of the user's vaults" (a scope /
  # deleted-vault problem that syncing won't fix).
  defp no_vault_message_for([]), do: "No vault found. Sync from Obsidian to create one."

  defp no_vault_message_for(_vaults),
    do:
      "This connection can't reach any of your vaults — its credential is scoped to a " <>
        "vault that no longer exists or that it isn't permitted to use."

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
