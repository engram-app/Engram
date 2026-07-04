defmodule Engram.Sync.Broadcast do
  @moduledoc """
  Transaction-aware sync broadcast emitter.

  PubSub broadcasts are NOT transactional: a `note_changed` event sent from
  inside an open `Repo.transaction` reaches subscribers immediately, even if the
  transaction later rolls back. For single-leg writes that is fine (the broadcast
  only fires once the call returns). But the `Engram.Folders` coordinator wraps
  the notes AND attachments legs in ONE outer transaction (`atomic/1`); each
  leg's per-item broadcast otherwise fires as its inner savepoint releases —
  BEFORE the outer commit. A later attachment conflict then rolls the data back
  while clients have already seen phantom delete/upsert events → divergence until
  the next pull.

  This module brackets such a cascade with a process-scoped deferral buffer:

    * `emit/3` — the single broadcast entry point. If a defer buffer is active in
      THIS process, it appends `{topic, event, payload}` instead of broadcasting;
      otherwise it broadcasts immediately (the default for all single-item
      callers, whose behavior is unchanged).
    * `deferred/1` — installs the buffer, runs `fun`, then flushes the buffered
      events iff `fun` returned `{:ok, _}` (committed) or discards them on
      `{:error, _}` (rolled back). The buffer key is always cleared in `after`.

  The buffer lives in the process dictionary, so it only affects the process that
  opened it — concurrent requests are isolated and the OFF-by-default invariant
  holds for every caller that does not opt in via `deferred/1`.
  """

  alias Engram.Logger.Metadata
  alias Engram.Observability.Otel

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @buffer_key :__engram_sync_broadcast_buffer__

  @doc """
  Broadcasts `event` on `topic` with `payload`, or buffers it when a deferral is
  active in the calling process.

  When `payload` is a map, the calling span's `traceparent` (nil when there is
  no span, or OTEL is off) is stamped onto it here, at call time, so it
  reflects the request/job that produced the change rather than whatever
  happens to be active later when a deferred buffer flushes. The browser uses
  it to parent its render span onto the `sync.fanout` span below.
  """
  @spec emit(String.t(), String.t(), map()) :: :ok
  def emit(topic, event, payload) do
    payload = stamp_traceparent(payload)

    case Process.get(@buffer_key) do
      nil ->
        broadcast_now(topic, event, payload)
        :ok

      buffered when is_list(buffered) ->
        Process.put(@buffer_key, [{topic, event, payload} | buffered])
        :ok
    end
  end

  @doc """
  Runs `fun` with a deferral buffer installed in the current process.

  Buffered events are flushed (broadcast in emission order) only if `fun` returns
  `{:ok, _}`; they are discarded if it returns `{:error, _}`. The buffer key is
  always cleared afterward, and nested calls reuse the outermost buffer (the
  inner call neither installs a new buffer nor flushes early).

  Returns whatever `fun` returns.
  """
  @spec deferred((-> result)) :: result when result: term()
  def deferred(fun) when is_function(fun, 0) do
    case Process.get(@buffer_key) do
      # Already deferring (nested): reuse the outer buffer, don't flush here.
      buffered when is_list(buffered) ->
        fun.()

      nil ->
        Process.put(@buffer_key, [])

        try do
          result = fun.()
          flush_or_discard(result)
          result
        after
          Process.delete(@buffer_key)
        end
    end
  end

  # Flush on commit ({:ok, _}); discard on rollback (anything else, incl
  # {:error, _}). Events were prepended, so reverse to restore emission order.
  defp flush_or_discard(result) do
    case result do
      {:ok, _} ->
        @buffer_key
        |> Process.get([])
        |> Enum.reverse()
        |> Enum.each(fn {topic, event, payload} ->
          broadcast_now(topic, event, payload)
        end)

      _ ->
        :ok
    end
  end

  @doc """
  Broadcasts `event` on `topic` to every subscriber EXCEPT `pid` (the pushing
  socket), via `Endpoint.broadcast_from/4`.

  This is the socket-origin delivery leg (a REST/CRDT push echoing to a note's
  other live peers). It is never subject to the deferral buffer — `broadcast_from`
  is only ever called with a live socket pid, outside the folder cascade — so it
  logs and broadcasts directly, mirroring `broadcast_now/3`'s breadcrumb with
  `mode=from`.
  """
  @spec emit_from(pid(), String.t(), String.t(), map()) :: :ok
  def emit_from(pid, topic, event, payload) when is_pid(pid) do
    payload = stamp_traceparent(payload)
    log_emit(topic, event, payload, "from")

    Tracer.with_span "sync.fanout", %{attributes: %{"engram.event_type" => event}} do
      _ = EngramWeb.Endpoint.broadcast_from(pid, topic, event, payload)
    end

    :ok
  end

  # Single point where a fanout sync event actually hits PubSub. Emits a
  # breadcrumb FIRST so the log lines up with the receiver's traced
  # `sync join`/`sync leave` — the broadcast is fastlaned PubSub → socket (the
  # sync channel has no `handle_out`), so this log is the only server-side proof
  # a broadcast fired. The `sync.fanout` span wraps only the actual dispatch
  # (not the breadcrumb log, not a deferred buffer's wait), giving the
  # browser's render span (leg B) a parent distinct from the request/job span
  # that produced the change (leg A).
  defp broadcast_now(topic, event, payload) do
    log_emit(topic, event, payload, "fanout")

    Tracer.with_span "sync.fanout", %{attributes: %{"engram.event_type" => event}} do
      _ = EngramWeb.Endpoint.broadcast(topic, event, payload)
    end

    :ok
  end

  # Stamps the active span's traceparent onto a map payload; non-map payloads
  # (none of the current callers pass one, but this keeps emit/3's contract
  # honest) pass through unchanged.
  defp stamp_traceparent(payload) when is_map(payload) do
    Map.put(payload, :traceparent, Otel.current_traceparent())
  end

  defp stamp_traceparent(payload), do: payload

  # Shared delivery breadcrumb for both legs (`fanout` = broadcast to all,
  # `from` = broadcast_from excluding the pusher).
  # Privacy: log ONLY UUIDs (topic + note_id). Never the note path or content.
  defp log_emit(topic, event, payload, mode) do
    note_id = Map.get(payload, "id") || Map.get(payload, "note_id")
    op = Map.get(payload, "event_type")

    Logger.info(
      "sync broadcast emit topic=#{topic} event=#{event} note_id=#{note_id} op=#{op} mode=#{mode}",
      Metadata.with_category(:info, :sync, note_id: note_id)
    )
  end
end
