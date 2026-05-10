defmodule Engram.Test.LogCapture do
  @moduledoc """
  Captures full `:logger` events (including metadata) emitted during a test.

  Unlike `ExUnit.CaptureLog`, which only captures formatter output, this helper
  preserves the structured event including its `meta` map. Use it when a test
  needs to assert on metadata that the default formatter doesn't render
  (e.g. fields the redact filter forwards as structured data instead of
  interpolating into the message body).
  """

  @doc """
  Runs `fun`, captures every log event emitted during its execution, and
  returns `{result, events}` where `events` is a list of `:logger` event maps
  in emission order.

  Each handler instance is uniquely named so concurrent invocations from
  async tests do not collide.
  """
  def with_events(fun) when is_function(fun, 0) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    handler_id = String.to_atom("log_capture_#{System.unique_integer([:positive])}")
    test_pid = self()

    :ok =
      :logger.add_handler(handler_id, :logger_std_h, %{
        config: %{},
        formatter: {:logger_formatter, %{}}
      })

    :ok =
      :logger.add_handler_filter(
        handler_id,
        :capture,
        {fn event, _ ->
           send(test_pid, {handler_id, event})
           :stop
         end, []}
      )

    try do
      result = fun.()
      events = drain(handler_id)
      {result, events}
    after
      :logger.remove_handler(handler_id)
    end
  end

  defp drain(handler_id, acc \\ []) do
    receive do
      {^handler_id, event} -> drain(handler_id, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
