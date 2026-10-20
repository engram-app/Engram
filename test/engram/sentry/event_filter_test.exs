defmodule Engram.Sentry.EventFilterTest do
  use ExUnit.Case, async: true

  alias Engram.Sentry.EventFilter

  defp request_event(exception),
    do: Sentry.Event.create_event(exception: exception, event_source: :plug)

  # 2026-10-20: a stalled Obsidian upload hit the 15s body read_timeout. The
  # request raised Bandit.HTTPError (400/408) before routing, and rendering
  # that 4xx to a socket the client had closed raised Bandit.TransportError.
  # Both paged Sentry as server errors (ENGRAM-BACKEND-Q, ENGRAM-BACKEND-X).
  describe "before_send/1 drops what is not a server error" do
    test "a request that failed with a 4xx exception" do
      for status <- [:bad_request, :request_timeout] do
        e = %Bandit.HTTPError{message: "Body read timeout", plug_status: status}
        assert EventFilter.before_send(request_event(e)) == nil
      end
    end

    test "a client that went away" do
      e = %Bandit.TransportError{message: "Unrecoverable error: closed", error: :closed}
      assert EventFilter.before_send(request_event(e)) == nil
      assert EventFilter.before_send(Sentry.Event.create_event(exception: e)) == nil
    end
  end

  describe "before_send/1 keeps server errors, scrubbed" do
    test "a crash in a request" do
      assert %Sentry.Event{request: nil} =
               EventFilter.before_send(request_event(%RuntimeError{message: "boom"}))
    end

    test "an exception whose status is 5xx" do
      e = %DBConnection.ConnectionError{message: "tcp recv: closed"}
      assert %Sentry.Event{} = EventFilter.before_send(request_event(e))
    end

    # A 404-mapped exception raised by a worker is a bug, not a client's
    # mistake: phoenix_ecto maps Ecto.NoResultsError to 404 for every caller.
    test "a 4xx-mapped exception raised outside a request" do
      e = %Ecto.NoResultsError{message: "expected at least one result"}
      assert %Sentry.Event{} = EventFilter.before_send(Sentry.Event.create_event(exception: e))
    end

    test "a message event" do
      assert %Sentry.Event{} = EventFilter.before_send(Sentry.Event.create_event(message: "hi"))
    end
  end

  test "is the configured before_send" do
    assert Application.fetch_env!(:sentry, :before_send) == {EventFilter, :before_send}
  end
end
