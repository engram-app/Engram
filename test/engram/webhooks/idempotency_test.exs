defmodule Engram.Webhooks.IdempotencyTest do
  # PG-backed (#862): processed_webhook_events rows make dedup cross-node —
  # a provider retry routed to the other node previously re-ran side effects.
  use Engram.DataCase, async: true

  alias Engram.Webhooks.Idempotency

  test "first sighting proceeds, second is a duplicate after mark_processed" do
    id = "evt_#{System.unique_integer([:positive])}"

    assert Idempotency.check(:paddle, id) == :proceed
    assert Idempotency.mark_processed(:paddle, id) == :ok
    assert Idempotency.check(:paddle, id) == :duplicate
  end

  test "source namespaces are independent (same id, different source)" do
    id = "evt_#{System.unique_integer([:positive])}"

    Idempotency.mark_processed(:paddle, id)
    assert Idempotency.check(:paddle, id) == :duplicate
    assert Idempotency.check(:clerk, id) == :proceed
  end

  test "a missing/blank id always proceeds and never raises" do
    assert Idempotency.check(:paddle, nil) == :proceed
    assert Idempotency.check(:paddle, "") == :proceed
    assert Idempotency.mark_processed(:paddle, nil) == :ok
    assert Idempotency.mark_processed(:paddle, "") == :ok
  end
end
