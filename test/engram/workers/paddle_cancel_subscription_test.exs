defmodule Engram.Workers.PaddleCancelSubscriptionTest do
  @moduledoc """
  The retry backstop for `Lifecycle.cancel_paddle_subscription/2`'s
  best-effort call: hard-delete's inline cancel is fire-and-forget, so a
  transient Paddle failure there used to mean the local `subscriptions` row
  was gone forever while Paddle kept billing. This worker is what makes that
  eventually consistent instead of silently stuck.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Workers.PaddleCancelSubscription

  setup :verify_on_exit!

  describe "enqueue/2" do
    test "inserts a job carrying the paddle subscription id and user id" do
      user_id = Ecto.UUID.generate()

      assert {:ok, _job} = PaddleCancelSubscription.enqueue(user_id, "sub_abc123")

      assert_enqueued(
        worker: PaddleCancelSubscription,
        args: %{"user_id" => user_id, "paddle_subscription_id" => "sub_abc123"}
      )
    end
  end

  describe "perform/1" do
    test "cancels the subscription with the same idempotency key hard-delete used" do
      user_id = Ecto.UUID.generate()

      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn sub_id, effective_from, opts ->
        assert sub_id == "sub_abc123"
        assert effective_from == :immediately
        assert Keyword.get(opts, :idempotency_key) == "hard-delete-#{user_id}"
        {:ok, %{}}
      end)

      assert :ok =
               perform_job(PaddleCancelSubscription, %{
                 "user_id" => user_id,
                 "paddle_subscription_id" => "sub_abc123"
               })
    end

    test "returns an error tuple on Paddle failure so Oban retries" do
      user_id = Ecto.UUID.generate()

      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn _, _, _ ->
        {:error, :paddle_unavailable}
      end)

      assert {:error, :paddle_unavailable} =
               perform_job(PaddleCancelSubscription, %{
                 "user_id" => user_id,
                 "paddle_subscription_id" => "sub_abc123"
               })
    end
  end
end
