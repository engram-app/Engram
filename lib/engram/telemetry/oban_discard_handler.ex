defmodule Engram.Telemetry.ObanDiscardHandler do
  @moduledoc """
  Telemetry handler that surfaces Oban job discards as warning-level log lines
  and re-emits a `[:engram, :oban, :discarded]` counter event.

  Oban emits `[:oban, :job, :exception]` for every job that ends in failure,
  cancellation, snooze, or discard. We only act on `state: :discarded` — the
  terminal state where Oban has burned `max_attempts` and dropped the work.
  These are the cases that need attention; transient `:failure` retries are
  expected and noisy.

  Wires from `Engram.Application.start/2` so the handler is live for the
  lifetime of the VM. The `@handler_id` atom is global; any test attaching
  this handler must run `async: false` to avoid races with concurrent tests
  that detach/re-attach the same id mid-execute.

  Future PromEx/Sentry can attach to `[:engram, :oban, :discarded]` for
  alerting; the source event already carries `worker` and `queue` metadata.
  """

  require Logger

  @handler_id :engram_oban_discard
  # Oban contract (>= v2.0): `worker` arrives in metadata as a binary
  # (module name as string), `queue` as an atom, `job` as the struct.
  @event [:oban, :job, :exception]

  @doc """
  Attach (or re-attach) the telemetry handler. Idempotent — detaches first so
  repeated boots (and ExUnit's per-suite restart) don't accumulate handlers.
  """
  def attach do
    _ = :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach(
        @handler_id,
        @event,
        &__MODULE__.handle_event/4,
        nil
      )
  end

  @doc false
  def handle_event(@event, _measurements, %{state: :discarded} = metadata, _config) do
    worker = metadata[:worker]
    queue = metadata[:queue]
    job = metadata[:job] || %{}

    # The `reason` value (typically an exception struct) is intentionally
    # NOT interpolated into the message body. `Engram.Logger.RedactFilter`
    # scrubs metadata but not message strings, so a raw `inspect(reason)`
    # here would leak any Voyage Bearer token carried in a `Req.TransportError`
    # or any Postgrex bound params carried in a `Postgrex.Error`. `:reason`
    # IS in the filter's sensitive-keys set, so passing it as metadata would
    # still be redacted at render time, but the safest pattern is to not
    # forward it at all from a warning-level emit. Operators who need the
    # full reason should attach a debug-level handler to the same Oban event.
    Logger.warning(
      "Oban job discarded after max_attempts: worker=#{worker} queue=#{inspect(queue)} job_id=#{inspect(Map.get(job, :id))} attempt=#{inspect(Map.get(job, :attempt))}/#{inspect(Map.get(job, :max_attempts))}",
      worker: worker,
      queue: queue,
      job_id: Map.get(job, :id),
      attempt: Map.get(job, :attempt),
      max_attempts: Map.get(job, :max_attempts),
      reason_label: :oban_discarded
    )

    :telemetry.execute(
      [:engram, :oban, :discarded],
      %{count: 1},
      %{worker: worker, queue: queue, job_id: Map.get(job, :id)}
    )
  end

  def handle_event(@event, _measurements, _metadata, _config), do: :ok
end
