defmodule Engram.Test.LogCapture do
  @moduledoc """
  Captures full `:logger` events (including metadata) emitted during a test.

  Unlike `ExUnit.CaptureLog`, which only captures formatter output, this helper
  preserves the structured event including its `meta` map. Use it when a test
  needs to assert on metadata that the default formatter doesn't render
  (e.g. fields the redact filter forwards as structured data instead of
  interpolating into the message body).

  One handler is installed for the whole suite (`install/0`, from
  `test_helper.exs`); each `with_events/1` call only subscribes in an ETS table.
  Adding and removing a handler per call lost events: OTP's `logger_server`
  snapshots the primary handler list when a `remove_handler` call arrives and
  writes that snapshot back once the removal finishes, so a handler added
  concurrently (another async test, or ExUnit's own capture handler) was
  silently dropped from the list while `add_handler` had already returned `:ok`.
  """

  @handler :engram_log_capture
  @table :engram_log_capture_subscribers

  @doc "Installs the suite-wide capture handler. Call once, before tests run."
  def install do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    :ok =
      :logger.add_handler(@handler, :logger_std_h, %{
        config: %{},
        formatter: {:logger_formatter, %{}},
        filters: [capture: {&__MODULE__.forward/2, []}]
      })
  end

  @doc false
  # Handler filter: hands the event to every subscriber, then stops it so the
  # handler never writes to stdio.
  def forward(event, _) do
    for {ref, pid} <- :ets.tab2list(@table), do: send(pid, {ref, event})
    :stop
  end

  @doc """
  Runs `fun`, captures every log event emitted during its execution, and
  returns `{result, events}` where `events` is a list of `:logger` event maps
  in emission order.
  """
  def with_events(fun) when is_function(fun, 0) do
    ref = make_ref()
    :ets.insert(@table, {ref, self()})

    try do
      result = fun.()
      {result, drain(ref)}
    after
      :ets.delete(@table, ref)
    end
  end

  defp drain(ref, acc \\ []) do
    receive do
      {^ref, event} -> drain(ref, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
