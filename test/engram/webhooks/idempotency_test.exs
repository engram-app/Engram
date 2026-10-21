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

  describe "claim/2" do
    test "true once per id, then false" do
      id = "adj_#{System.unique_integer([:positive])}"
      assert Idempotency.claim(:paddle_adjustment, id)
      refute Idempotency.claim(:paddle_adjustment, id)
      assert Idempotency.claim(:paddle_adjustment, id <> "_other")
    end

    test "a missing id is always true" do
      assert Idempotency.claim(:paddle_adjustment, nil)
      assert Idempotency.claim(:paddle_adjustment, nil)
    end

    # An adjustment can be updated weeks later (a chargeback's evidence), so
    # its claim outlives the 7-day replay window.
    test "the 7-day prune keeps adjustment claims" do
      id = "adj_#{System.unique_integer([:positive])}"
      assert Idempotency.claim(:paddle_adjustment, id)
      Idempotency.mark_processed(:paddle, id)
      old = DateTime.add(DateTime.utc_now(), -30, :day)

      Repo.update_all(from(e in "processed_webhook_events", where: e.event_id == ^id),
        set: [inserted_at: old]
      )

      {:ok, _} = Idempotency.prune()
      refute Idempotency.claim(:paddle_adjustment, id)
      assert Idempotency.check(:paddle, id) == :proceed
    end
  end
end
