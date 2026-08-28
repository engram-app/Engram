defmodule Engram.Telemetry.ObanDiscardHandler do
  @moduledoc """
  Telemetry handler that surfaces Oban job discards as warning-level log lines
  and re-emits a `[:engram, :oban, :discarded]` counter event.

  Oban emits `[:oban, :job, :exception]` for every job that ends in failure,
  cancellation, snooze, or discard. We act on two of them:

    * `state: :discarded` — the terminal state where Oban has burned
      `max_attempts` and dropped the work. Transient `:failure` retries are
      expected and noisy, so they are otherwise ignored.

    * any attempt whose reason is an `Oban.TimeoutError` — a wedged job, which
      must be visible on the FIRST attempt rather than hours later when the
      retries run out. See #1496.

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

    # The raw `reason` (typically an exception struct or connection-error term)
    # is NEVER forwarded — not into the message body and not as metadata.
    # `:reason` is NOT in `Engram.Logger.RedactFilter`'s sensitive-keys set
    # (it carries safe atoms at most call sites), and the filter never touches
    # message strings anyway, so a raw `inspect(reason)` here would leak any
    # Voyage Bearer token in a `Req.TransportError` or Postgrex bound params in
    # a `Postgrex.Error`. Instead we surface a bounded `error_kind` atom via
    # `Engram.Telemetry.error_kind/1` — the exception module or leading error
    # atom — so operators get the root-cause class without the secret payload.
    error_kind = Engram.Telemetry.error_kind(metadata[:reason])

    Logger.warning(
      "Oban job discarded after max_attempts: worker=#{worker} queue=#{inspect(queue)} job_id=#{inspect(Map.get(job, :id))} attempt=#{inspect(Map.get(job, :attempt))}/#{inspect(Map.get(job, :max_attempts))} error_kind=#{error_kind}",
      Engram.Logger.Metadata.with_category(:warning, :oban,
        worker: worker,
        queue: queue,
        job_id: Map.get(job, :id),
        attempt: Map.get(job, :attempt),
        max_attempts: Map.get(job, :max_attempts),
        error_kind: error_kind,
        reason_label: :oban_discarded
      )
    )

    :telemetry.execute(
      [:engram, :oban, :discarded],
      %{count: 1},
      %{worker: worker, queue: queue, job_id: Map.get(job, :id), error_kind: error_kind}
    )
  end

  @doc false
  # A TIMEOUT on any attempt, not just the last one.
  #
  # This clause exists because of the 2026-08-28 prod stall (#1496): the
  # `embed` and `indexing` queues were fully occupied by jobs that would never
  # finish, and nothing anywhere emitted a single line. Timeouts were only
  # visible once a job burned all `max_attempts` and reached `:discarded` —
  # five attempts of exponential backoff later, i.e. hours after the queue had
  # already stopped. The whole point of giving workers a finite `timeout/1` is
  # to make a wedged job observable, so the FIRST timeout has to say so.
  #
  # Not noisy by construction: a timeout means a job ran past 5-60 minutes.
  # If these ever become frequent, that is the signal, not the noise.
  #
  # `:discarded` is matched above, so a timeout on the final attempt logs the
  # discard line rather than this one — the terminal state is the louder fact.
  def handle_event(@event, measurements, %{reason: %Oban.TimeoutError{}} = metadata, _config) do
    worker = metadata[:worker]
    queue = metadata[:queue]
    job = metadata[:job] || %{}

    # `duration` is native time units, and is how long the job actually ran —
    # which is the configured timeout, so it tells an operator which ceiling
    # was hit without reading the exception message.
    ran_ms = System.convert_time_unit(measurements[:duration] || 0, :native, :millisecond)

    Logger.warning(
      "Oban job timed out: worker=#{worker} queue=#{inspect(queue)} job_id=#{inspect(Map.get(job, :id))} attempt=#{inspect(Map.get(job, :attempt))}/#{inspect(Map.get(job, :max_attempts))} ran_ms=#{ran_ms}",
      Engram.Logger.Metadata.with_category(:warning, :oban,
        worker: worker,
        queue: queue,
        job_id: Map.get(job, :id),
        attempt: Map.get(job, :attempt),
        max_attempts: Map.get(job, :max_attempts),
        ran_ms: ran_ms,
        reason_label: :oban_timeout
      )
    )

    :telemetry.execute(
      [:engram, :oban, :timeout],
      %{count: 1, ran_ms: ran_ms},
      %{worker: worker, queue: queue, job_id: Map.get(job, :id)}
    )
  end

  def handle_event(@event, _measurements, _metadata, _config), do: :ok
end
