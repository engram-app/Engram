defmodule Engram.Logger.Metadata do
  @moduledoc """
  Builds Logger metadata with a validated `category` and the computed
  `loki_ship` routing flag. Use at log call sites:

      Logger.info("subscription created",
        Engram.Logger.Metadata.with_category(:info, :billing,
          paddle_subscription_id: id))
  """
  alias Engram.Logger.Category

  @spec with_category(Logger.level(), atom(), keyword()) :: keyword()
  @doc """
  A log-safe rendering of a rescued exception.

  `Exception.message/1` is not "our own text". `CaseClauseError`, `MatchError`,
  `KeyError`, `Protocol.UndefinedError` and `Jason.EncodeError` all render
  `inspect(term)` of the value that blew up — and in this codebase the terms
  flowing through a rescue are frequently note content, a path, or a search
  query.

  Moving such a message into metadata does NOT make it safe:
  `Engram.Logger.RedactFilter` scrubs by KEY, and neither `:error`, `:reason`
  nor `:message` is in its set, so Loki and CloudWatch print it verbatim. (The
  Sentry metadata allowlist in `Engram.Application` is separate and narrower.)

  So the filter is on the exception TYPE. An allowlist, not a denylist: a new
  exception type in Elixir or a dependency defaults to safe-and-useless rather
  than to leaking.

  ## What is NOT allowlisted, and why

  The first version of this list said allowlisted messages were "our own text
  or the database's". Three of its five entries were traced to their
  `message/1` and shown to render user data:

    * `Ecto.StaleEntryError` → `inspect(changeset.data)`, i.e. the WHOLE
      `%Note{}` including `:content`. `Engram.Notes.Note` has no
      `@derive Inspect`, and `utf8_backfill_test.exs` asserts exactly that the
      struct inspects its plaintext. This is the round-3 defect —
      `Exception.message/1` renders `inspect(term)` — reintroduced by name in
      the fix for it.
    * `Ecto.QueryError` → renders the query with PINNED PARAMS verbatim.
    * `Postgrex.Error` → `message` (which quotes an offending value), plus
      `build_query/1` (the SQL) and `build_detail/1` (Postgres `DETAIL`, i.e.
      "Failing row contains (…)").

  Postgres is still the most useful signal on this path, so it is rendered
  STRUCTURALLY from fields that are codes rather than values. Never
  `Exception.message/1`.
  """
  # Only types whose message/1 was read in deps/ and confirmed to contain no
  # value from the row, the query, or the changeset.
  @safe_message_exceptions [
    # Constraint NAMES only.
    Ecto.ConstraintError,
    # Operator text ("tcp recv: closed"). One latent path renders
    # `inspect(other)` on a bad pool return, which cannot hold note content.
    DBConnection.ConnectionError
  ]

  @spec safe_reason(Exception.t() | struct() | any()) :: String.t()
  def safe_reason(%mod{} = e) when mod in @safe_message_exceptions, do: Exception.message(e)

  # Severity + SQLSTATE + the atom name. Everything a responder actually greps
  # for, and no field that can hold a row value.
  def safe_reason(%Postgrex.Error{postgres: %{} = pg}) do
    [Map.get(pg, :severity), Map.get(pg, :pg_code), Map.get(pg, :code)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
    |> case do
      "" -> "Postgrex.Error"
      rendered -> rendered
    end
  end

  def safe_reason(%mod{}), do: inspect(mod)

  # Atoms are the single most common reason shape in this codebase
  # (`:not_found`, `:timeout`, `:version_conflict`) and cannot carry note
  # content — nothing on these paths interns user text as an atom. Without this
  # they all collapsed to "unknown", which is the failure mode that makes
  # on-call route around a filter instead of trusting it.
  def safe_reason(reason) when is_atom(reason), do: inspect(reason)

  # Storage errors. The status and the S3 error code are exactly what an
  # operator needs (a misconfigured MinIO secret is otherwise invisible), and
  # neither can hold user data — an S3 code is a bare alphabetic identifier,
  # while a storage key is "user/vault/<path>" and contains separators.
  #
  # ExAws hands the third element over in TWO shapes, and the first version of
  # this clause only handled one of them:
  #
  #   4xx  `client_error/2` → the whole response MAP, `%{status_code:, body:, ...}`
  #   5xx  `Map.get(resp, :body)` → a bare binary
  #
  # A 403 SignatureDoesNotMatch — the case named in the original comment as the
  # motivation — therefore took the map branch and extracted nothing, so the
  # comment described behaviour the code did not have. Review caught it; both
  # shapes are handled now and both are covered by tests built from the real
  # `ExAws.Request` construction rather than a hand-written tuple.
  def safe_reason({:http_error, status, body}) when is_integer(status) do
    ["http_error", to_string(status), storage_code(body)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  # `{:error, :not_found}` / `{:notes_cap_reached, used, cap}` — the tag names
  # what went wrong and cannot hold note content. The payload is dropped: it is
  # where a %Note{}, a changeset or a Yjs frame would ride. Without this every
  # tuple reason collapsed to "unknown", which is how a filter earns being
  # routed around.
  # `{:error, :aad_mismatch}` and friends: BOTH elements are atoms, so neither
  # can hold user data and dropping the payload costs the entire signal. The
  # general tuple clause below renders this ":error", which tells an operator
  # nothing at all — the failure mode that gets a filter routed around rather
  # than fixed.
  def safe_reason({tag, payload}) when is_atom(tag) and is_atom(payload),
    do: "#{inspect(tag)} #{inspect(payload)}"

  def safe_reason(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> inspect(tag)
      _ -> "unknown"
    end
  end

  # A rescue always binds a struct, but this is called from a shared logging
  # module and its @spec invites `catch :exit, reason`. `hmac_ref/1` in
  # notes.ex got a fallback in the same commit for exactly this reason — "a log
  # helper must not be the thing that breaks it" — and the reasoning was not
  # carried one function over. A FunctionClauseError raised from inside an
  # isolation rescue defeats the isolation.
  def safe_reason(_other), do: "unknown"

  @doc """
  Where a raise happened, with no argument values.

  `Exception.format_stacktrace/1` is NOT safe to log. BEAM puts the failing
  call's actual ARGUMENT LIST in the top frame for `FunctionClauseError`,
  `UndefinedFunctionError` and any BIF/NIF `badarg`, and the formatter inspects
  each one at `:printable_limit` (4096 bytes) — so a `FunctionClauseError` in
  `Crypto.hmac_content_hash(key, text)` prints ~4 KB of the note body.

  This renders `Module.function/arity` per frame and nothing else. Locations
  answer "where"; the values were never the part that helped.
  """
  @spec format_location(Exception.stacktrace()) :: String.t()
  def format_location(stacktrace) when is_list(stacktrace) do
    stacktrace
    |> Enum.take(5)
    |> Enum.map_join(" <- ", fn
      {mod, fun, arity, _loc} when is_integer(arity) -> "#{inspect(mod)}.#{fun}/#{arity}"
      {mod, fun, args, _loc} when is_list(args) -> "#{inspect(mod)}.#{fun}/#{length(args)}"
      _other -> "?"
    end)
  end

  def format_location(_other), do: "?"

  # An S3/XML error code, or nil. Accepts ONLY a bare alphabetic identifier, so
  # a message, a URL or a storage key (all of which carry `/`, `.` or spaces)
  # can never qualify.
  # The 4xx shape: dig the body out and re-enter. Only `:body`, and only when it
  # is a binary — a response map also carries headers, and a blanket
  # `inspect(map)` here would reintroduce exactly what this module exists to
  # prevent.
  defp storage_code(%{body: body}), do: storage_code(body)

  defp storage_code(body) when is_binary(body) do
    candidate =
      case Regex.run(~r|<Code>([A-Za-z]{3,40})</Code>|, body) do
        [_, code] -> code
        _ -> body
      end

    if Regex.match?(~r/^[A-Za-z]{3,40}$/, candidate), do: candidate
  end

  defp storage_code(_other), do: nil

  @doc """
  A log-safe rendering of a `catch :exit, reason` value.

  `inspect(reason)` is not safe here for the same reason a raw stacktrace is
  not: an exit from a crashed GenServer is `{exception, stacktrace}`, and a
  `GenServer.call` timeout is `{:timeout, {GenServer, :call, [pid, request, _]}}`
  — where `request` on these paths is a Yjs frame or note content, rendered at
  `:printable_limit`.

  Keeps the shape and the location, drops every value.
  """
  @spec safe_exit_reason(any()) :: String.t()
  def safe_exit_reason({%{__exception__: true} = e, stacktrace}) when is_list(stacktrace),
    do: "#{safe_reason(e)} at #{format_location(stacktrace)}"

  def safe_exit_reason({:timeout, {mod, fun, args}}) when is_list(args),
    do: "timeout in #{inspect(mod)}.#{fun}/#{length(args)}"

  def safe_exit_reason({tag, _payload}) when is_atom(tag), do: inspect(tag)
  def safe_exit_reason(reason) when is_atom(reason), do: inspect(reason)
  def safe_exit_reason(_other), do: "unknown"

  def with_category(level, category, metadata \\ []) do
    unless Category.valid?(category) do
      raise ArgumentError, "unknown log category: #{inspect(category)}"
    end

    metadata
    |> Keyword.put(:category, category)
    |> Keyword.put(:loki_ship, Category.loki_ship?(level, category))
    |> put_trace_context()
  end

  defp put_trace_context(metadata) do
    case Engram.Observability.Otel.span_context() do
      {trace_id, span_id} ->
        metadata
        |> Keyword.put(:trace_id, trace_id)
        |> Keyword.put(:span_id, span_id)

      nil ->
        metadata
    end
  end
end
