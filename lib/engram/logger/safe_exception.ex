defmodule Engram.Logger.SafeException do
  @moduledoc """
  The one allowlist every exception sink applies before rendering text.

  `MatchError`, `CaseClauseError`, `KeyError`, `Protocol.UndefinedError`,
  `Oban.PerformError` and friends build their message from `inspect(term)`,
  and in this codebase that term is often a client payload, a note or a path.
  `redact: true` covers structs only; a plain map crosses every sink intact.

  Sinks that render exceptions (the crash-report translator, the HTTP request
  exception log, the Oban `errors` column) call this at the point the text is
  produced. Only `Engram.Logger.Metadata.safe_message?/1` types keep their
  message; everything else becomes an `Engram.Logger.RedactedError` that keeps
  the type name. Stack frames keep module, function, arity, file and line, and
  lose their argument lists.
  """

  alias Engram.Logger.Metadata
  alias Engram.Logger.RedactedError

  # Oban wraps a worker's return in an exception that inspects it. The wrapped
  # reason goes through safe_reason, so `{:error, :timeout}` stays readable.
  @wrapped_reason [Oban.PerformError, Oban.CrashError, Oban.TimeoutError]

  @redacted :"[redacted]"

  @spec sanitize(Exception.t()) :: Exception.t()
  def sanitize(%RedactedError{} = e), do: e

  def sanitize(%mod{} = e) when is_exception(e) do
    cond do
      Metadata.safe_message?(e) -> e
      mod in @wrapped_reason -> redacted(mod, Metadata.safe_reason(Map.get(e, :reason)))
      true -> redacted(mod, Metadata.safe_reason(e))
    end
  end

  defp redacted(mod, detail) do
    message =
      if detail in ["", inspect(mod), "unknown"],
        do: "#{inspect(mod)} (details redacted)",
        else: "#{inspect(mod)}: #{detail}"

    %RedactedError{type: mod, message: message}
  end

  @doc """
  Sanitize an exit or crash reason as it appears in a logger report or an
  Oban `unsaved_error`. Atoms and all-atom tuples survive; exceptions (and
  Erlang error terms, normalized first) go through `sanitize/1`; anything else
  keeps at most its atom tag.
  """
  @spec sanitize_reason(term()) :: atom() | tuple() | Exception.t()
  # gen_statem: `{class, reason, stack}`. Logger.Translator matches this exact
  # shape; breaking it makes Logger print the whole report inspected.
  def sanitize_reason({class, reason, stack})
      when class in [:error, :exit, :throw] and is_list(stack) do
    if stack == [] or stacktrace?(stack) do
      inner =
        if class == :error,
          do: reason |> to_exception(stack) |> sanitize(),
          else: sanitize_term(reason)

      {class, inner, strip_args(stack)}
    else
      sanitize_term({class, reason, stack})
    end
  end

  # gen_event wraps a handler crash as `{:EXIT, why}`.
  def sanitize_reason({:EXIT, why}), do: {:EXIT, sanitize_reason(why)}

  def sanitize_reason({reason, stack}) when is_list(stack) and stack != [] do
    if stacktrace?(stack) do
      {reason |> to_exception(stack) |> sanitize(), strip_args(stack)}
    else
      sanitize_term({reason, stack})
    end
  end

  def sanitize_reason(reason) when is_exception(reason), do: sanitize(reason)
  def sanitize_reason(reason), do: sanitize_term(reason)

  @doc """
  Sanitize a caught `{kind, reason, stacktrace}` into an exception plus
  argument-free frames, whatever the kind. `:exit` and `:throw` values become a
  `RedactedError` naming the kind and the value's safe tag.
  """
  #
  # Total over `kind`, because callers do not agree on it: Bandit reports a
  # raise as `:exit` (Bandit.Telemetry.span_exception/4), and Oban records a
  # job process that died as `{:EXIT, pid}`. An exception is sanitized as an
  # exception whatever kind it arrived under.
  @spec to_safe_exception(term(), term(), term()) :: {Exception.t(), list()}
  def to_safe_exception(kind, reason, stack) do
    stack = if is_list(stack), do: stack, else: []

    if is_exception(reason) or kind == :error do
      {reason |> to_exception(stack) |> sanitize(), strip_args(stack)}
    else
      label = kind_label(kind)
      tag = reason |> sanitize_reason() |> Metadata.safe_reason()
      {%RedactedError{type: label, message: "#{label}: #{tag}"}, strip_args(stack)}
    end
  end

  defp kind_label(kind) when kind in [:exit, :throw], do: kind
  defp kind_label(_), do: :exit

  @doc """
  `Exception.format/3` of the sanitized exception: type, allowlisted message,
  and `file:line` frames with no argument values. The one way a sink renders a
  caught exception as text.
  """
  @spec safe_format(:error | :exit | :throw, term(), list()) :: String.t()
  def safe_format(kind, reason, stack) do
    {safe, safe_stack} = to_safe_exception(kind, reason, stack)
    Exception.format(:error, safe, safe_stack)
  end

  @doc "Replace every frame's argument list with its arity."
  @spec strip_args(list()) :: list()
  def strip_args(stack) when is_list(stack) do
    Enum.map(stack, fn
      {m, f, args, loc} when is_list(args) -> {m, f, length(args), loc}
      frame -> frame
    end)
  end

  defp to_exception(reason, _stack) when is_exception(reason), do: reason
  defp to_exception(reason, stack), do: Exception.normalize(:error, reason, stack)

  defp stacktrace?([{m, f, a, loc} | _]) when is_atom(m) and is_atom(f) and is_list(loc),
    do: is_integer(a) or is_list(a)

  defp stacktrace?(_), do: false

  defp sanitize_term(reason) when is_atom(reason), do: reason
  defp sanitize_term({tag, payload}) when is_atom(tag) and is_atom(payload), do: {tag, payload}

  defp sanitize_term(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: {elem(reason, 0), @redacted}

  defp sanitize_term(_reason), do: @redacted
end
