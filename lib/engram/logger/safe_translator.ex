defmodule Engram.Logger.SafeTranslator do
  @moduledoc """
  Logger translator that sanitizes crash reasons before Elixir renders them.

  The default `Logger.Translator` turns a crash report into text with
  `Exception.format/3`, so a channel that crashes matching on a client payload
  prints the payload (Loki), and puts the raw exception in `crash_reason`
  metadata (Sentry's LoggerHandler). Registered first in `:logger,
  :translators` (config.exs), this rewrites the report's reason through
  `Engram.Logger.SafeException` and delegates the formatting back to
  `Logger.Translator`, so output shape is unchanged.

  Covers every report the default translator renders WITH a reason while SASL
  reports are off: gen_server/gen_statem/gen_event terminate, Task terminating,
  application exit, and the legacy "Generic server" / "Error in process"
  formats. Anything else returns `:none` and falls through untouched.
  """

  alias Engram.Logger.SafeException

  @redacted :"[redacted]"

  @terminate [{:gen_server, :terminate}, {:gen_statem, :terminate}, {:gen_event, :terminate}]

  @spec translate(Logger.level(), Logger.level(), atom(), term()) ::
          {:ok, iodata(), keyword()} | {:ok, iodata()} | :skip | :none
  def translate(min_level, level, kind, message) do
    case sanitize(kind, message) do
      {:ok, safe} -> Logger.Translator.translate(min_level, level, kind, safe)
      :unchanged -> :none
    end
  end

  defp sanitize(:report, {:logger, %{label: label} = report}) when label in @terminate do
    safe =
      report
      |> update(:reason, &SafeException.sanitize_reason/1)
      |> update(:last_message, &summarize/1)
      |> update(:state, fn _ -> @redacted end)

    {:ok, {:logger, safe}}
  end

  defp sanitize(:report, {{Task.Supervisor, :terminating} = label, %{} = report}) do
    safe =
      report
      |> update(:reason, &SafeException.sanitize_reason/1)
      |> update(:args, fn
        args when is_list(args) -> Enum.map(args, &summarize/1)
        _ -> @redacted
      end)

    {:ok, {label, safe}}
  end

  defp sanitize(:report, {{:application_controller, :exit} = label, report}) when is_list(report),
    do: {:ok, {label, Keyword.update(report, :exited, nil, &SafeException.sanitize_reason/1)}}

  defp sanitize(
         :format,
         {~c"** Generic server " ++ _ = format, [name, last, _state, reason | client]}
       ),
       do:
         {:ok,
          {format,
           [name, summarize(last), @redacted, SafeException.sanitize_reason(reason) | client]}}

  defp sanitize(:format, {~c"Error in process " ++ _ = format, args}) when is_list(args) do
    {reason, stack} = List.last(args)
    {safe, safe_stack} = SafeException.sanitize_reason({reason, stack})
    {:ok, {format, List.replace_at(args, -1, {safe, safe_stack})}}
  end

  defp sanitize(_kind, _message), do: :unchanged

  defp update(map, key, fun) when is_map_key(map, key), do: Map.update!(map, key, fun)
  defp update(map, _key, _fun), do: map

  # The last message a process got (a channel's is the client frame) keeps only
  # what names it: a Phoenix event, or an atom tag. Payloads never render.
  defp summarize(%{__struct__: struct, event: event})
       when struct in [Phoenix.Socket.Message, Phoenix.Socket.Broadcast] and is_binary(event),
       do: {inspect(struct), event, @redacted}

  defp summarize(message)
       when is_atom(message) or is_number(message) or is_pid(message) or is_reference(message),
       do: message

  defp summarize(message) when is_tuple(message) and tuple_size(message) > 0 do
    case elem(message, 0) do
      tag when is_atom(tag) -> {tag, @redacted}
      _ -> @redacted
    end
  end

  defp summarize(_message), do: @redacted
end
