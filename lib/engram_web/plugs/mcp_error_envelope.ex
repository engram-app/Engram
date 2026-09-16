defmodule EngramWeb.Plugs.McpErrorEnvelope do
  @moduledoc """
  Reshapes pipeline-level refusals on the MCP endpoint into JSON-RPC errors.

  `McpController` answers its own failures as JSON-RPC error objects. Every
  refusal that happens in the *pipeline* never reaches it: the halting plugs on
  `:authed_api` (suspended, write-disabled, onboarding, deleted, plugin floor,
  the two rate limiters, rotating) each halt with the flat REST body every
  other API route gets. That body is not a JSON-RPC response, so MCP clients
  surface a bare "HTTP 403" and drop it, which is how a user can spend hours
  stuck with the remedy sitting in a field they never see.

  Deliberately keyed on STATUS, not on plug identity, so a plug added to the
  pipeline later is covered without touching this file. Do not re-introduce an
  enumerated count here: the list above is orientation, and an exact tally
  rots the moment the pipeline changes.

  The status is preserved. Only the body is rewritten, so every existing
  assertion, every log line, and every client that keys off the status is
  unaffected; clients that read the body now get a sentence.

  ## Why a separate plug rather than a branch in `Plugs.Halt`

  `Halt.json/3` is the shared halt idiom for ~20 call sites across six
  pipelines, and its moduledoc is explicit that anything beyond the idiom stays
  at the call site. Teaching it about MCP would put transport-specific
  formatting in the one function every REST refusal also routes through. This
  is a property of *this resource*, so it installs on the MCP scope only —
  the same reasoning, and the same mechanism, as `McpAuthChallenge`.

  ## Why `register_before_send`

  The plugs this wraps halt, so nothing downstream of them runs. A before_send
  callback still fires on a halted conn and sees the status actually sent, so
  one registration upstream covers all seven without any of them knowing.
  """

  @behaviour Plug

  # JSON-RPC 2.0 §5.1 reserves -32000..-32099 for implementation-defined server
  # errors. One code covers every gate deliberately: the machine-readable reason
  # already travels verbatim in `data`, and minting a code per plug would invent
  # a second vocabulary for something `data.error` already names exactly.
  @server_error -32_001

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # The id is read HERE, not in the callback: it comes from the parsed
    # request body, and reading it up front keeps the callback a pure function
    # of the response.
    Plug.Conn.register_before_send(conn, &envelope(&1, request_id(conn)))
  end

  # 401 is excluded on purpose. It is the entry point to OAuth discovery
  # (RFC 9728 §5.1) — `McpAuthChallenge` pairs it with a `WWW-Authenticate`
  # pointer, and a spec-following client acts on that header plus the status,
  # not on the body. Reshaping it would be churn at best and would break
  # discovery at worst.
  defp envelope(%Plug.Conn{status: status} = conn, id)
       when is_integer(status) and status >= 400 and status != 401 do
    with ["application/json" <> _] <- Plug.Conn.get_resp_header(conn, "content-type"),
         {:ok, %{} = body} <- decode(conn.resp_body),
         false <- Map.has_key?(body, "jsonrpc") do
      Plug.Conn.resp(conn, status, encode(body, id, status))
    else
      # Not our JSON, or already a JSON-RPC payload. Leave it exactly as it is:
      # a body this plug does not understand is a body it must not mangle.
      _ -> conn
    end
  end

  defp envelope(conn, _id), do: conn

  defp encode(body, id, status) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => @server_error,
        "message" => message_for(body, status),
        # The original body, unaltered. Anything a REST caller could read off
        # the top level is still here, one level down — `resume_url` included.
        "data" => body
      }
    })
  end

  # A JSON-RPC error may carry a null id when the request's own id could not be
  # determined (§5). That is the honest answer for a malformed or bodyless
  # request, and it is better than inventing one.
  defp request_id(%Plug.Conn{body_params: %{"id" => id}})
       when is_binary(id) or is_integer(id),
       do: id

  defp request_id(_), do: nil

  # Prefer a sentence the refusing plug wrote itself, INCLUDING on 5xx: the
  # `503 rotating` halt is a deliberate, well-described refusal, not a crash,
  # and status alone cannot tell the two apart. Falling back to the error slug
  # is mechanical rather than a hand-maintained map on purpose: a lookup table
  # would silently answer with a stale sentence the first time someone adds a
  # plug.
  #
  # The fallback is only as good as the slug. `LimitResponse.halt/5` answers
  # `error: "limit_exceeded"` with the real cause in a separate `reason` field,
  # so a suspended account reads "Limit exceeded.", which is imprecise rather
  # than wrong, and the precise reason still travels in `data`. Give a plug a
  # `message` if its slug does not stand on its own.
  defp message_for(%{"message" => message}, _status) when is_binary(message) and message != "",
    do: message

  defp message_for(%{"error" => slug}, _status) when is_binary(slug), do: humanize(slug)

  # Nothing self-describing in the body, and the status says this one is OURS.
  # Phoenix renders an unhandled 500 through `ErrorJSON` as
  # `%{"errors" => %{"detail" => ...}}`, matching neither clause above, so this
  # used to fall through to "The request was refused." Telling users Engram
  # refused them when Engram actually fell over is the exact misreading #1666
  # was about: that user spent five hours retrying a rule that did not exist.
  defp message_for(_body, status) when status >= 500,
    do: "Engram hit an internal error. This is not a problem with your request; retry shortly."

  defp message_for(_body, _status), do: "The request was refused."

  defp humanize(slug) do
    slug
    |> String.replace("_", " ")
    |> String.capitalize()
    |> Kernel.<>(".")
  end

  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(_), do: :error
end
