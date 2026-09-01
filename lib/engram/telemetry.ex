defmodule Engram.Telemetry do
  @moduledoc """
  Shared helpers for emitting telemetry safely.
  """

  @doc """
  Map an arbitrary failure reason to a bounded, log-safe atom for use as
  telemetry metadata.

  **Security invariant — never forward the raw reason.** A connection error term
  can carry secrets (passwords, API keys), and a request error can carry a
  Voyage Bearer token; telemetry metadata does **not** pass through
  `Engram.Logger.RedactFilter`. Every caller that puts a failure reason into
  telemetry metadata must route it through here so only a bounded atom (an error
  class or exception module) escapes. The `is_atom/1` guard on the tuple clause
  is load-bearing: a tuple whose leading element is not an atom (e.g.
  `{"secret", _}`) falls through to `:other` rather than leaking the inner term.
  Only the leading tag escapes — every other element (a status body, bound
  params, a token) is dropped, whatever the tuple's size.

  ## Exit reasons

  A process that dies exits with `{reason, stacktrace}`, where `reason` is
  either an exception STRUCT (`raise`) or an erlang error tuple
  (`{:nocatch, term}` from a throw, `{:badmatch, value}`, `{:case_clause, _}`,
  `{:badkey, _, _}`). Neither satisfies the leading-atom guard above, so every
  such reason used to classify as `:other` — the arm whose whole promise is that
  the diagnostic detail rides the log line instead. Callers worked around it
  privately (`Metadata.safe_exit_reason/1`, `BackfillContentHashHmac`, and a
  third copy in `CrdtChannel`), which is the signal that the defect belonged
  here. The two clauses below unwrap exactly ONE level and still let only an
  atom escape, so the security invariant is unchanged.
  """
  @spec error_kind(term()) :: atom()
  def error_kind(reason) when is_atom(reason), do: reason

  def error_kind({e, stack}) when is_exception(e) and is_list(stack), do: e.__struct__

  def error_kind({inner, stack})
      when is_list(stack) and is_tuple(inner) and tuple_size(inner) > 0 and
             is_atom(elem(inner, 0)),
      do: elem(inner, 0)

  def error_kind(reason)
      when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
      do: elem(reason, 0)

  # `is_exception/1` rather than a bare `%{__exception__: true}` map pattern: a
  # struct-less map matches the latter and then raises KeyError on `__struct__`,
  # inside the classifier whose job is to make failures loggable.
  def error_kind(e) when is_exception(e), do: e.__struct__
  def error_kind(_), do: :other
end
