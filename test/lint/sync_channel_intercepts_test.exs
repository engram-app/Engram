defmodule Engram.Lint.SyncChannelInterceptsTest do
  # A vault-data event on `sync:` that `SyncChannel` does not intercept is
  # fastlaned straight to the socket, past the per-push access check. Every
  # event the fan-out helpers send must be intercepted.
  use ExUnit.Case, async: true

  # The helpers every `sync:` broadcast goes through, and the literal event
  # each call site passes (first lowercase string literal in its arguments).
  @senders ~r/(?:Broadcast\.emit(?:_from)?|FanoutPacer\.emit|broadcast_batch)\(([^)]*)/s
  @event ~r/"([a-z_]+(?:\.[a-z_]+)?)"/

  test "every event sent to sync: topics is intercepted by SyncChannel" do
    sent =
      for file <- Path.wildcard("lib/**/*.ex"),
          [_, args] <- Regex.scan(@senders, File.read!(file)),
          [_, event] <- Enum.take(Regex.scan(@event, args), 1),
          uniq: true,
          do: event

    # The scan must find the known senders, or it has silently stopped working.
    assert "note_changed" in sent and "note_yjs_update" in sent and "notes.batch" in sent,
           "scan found only #{inspect(sent)}"

    missing = sent -- EngramWeb.SyncChannel.__intercepts__()
    assert missing == [], "add to SyncChannel's intercept list: #{inspect(missing)}"
  end
end
