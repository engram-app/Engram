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

  # A rescue always binds a struct, but this is called from a shared logging
  # module and its @spec invites `catch :exit, reason`. `hmac_ref/1` in
  # notes.ex got a fallback in the same commit for exactly this reason — "a log
  # helper must not be the thing that breaks it" — and the reasoning was not
  # carried one function over. A FunctionClauseError raised from inside an
  # isolation rescue defeats the isolation.
  def safe_reason(_other), do: "unknown"

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
