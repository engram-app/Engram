defmodule EngramWeb.Webhooks.PostHogForwarder do
  @moduledoc """
  Maps verified inbound Clerk + Paddle webhook events to PostHog product
  events. Lives next to the controller (not in the contexts) because the
  mapping is an integration concern — what Clerk/Paddle call an event vs.
  what the funnel calls a step. The contexts shouldn't know about either
  vendor's payload shape.

  All forwarders run AFTER the underlying handler completes, so a PostHog
  failure can never roll back business state. `PostHog.capture/3` is itself
  fire-and-forget (Task.start) — these helpers never block on network I/O
  and always return `:ok`.

  distinct_id MUST equal the frontend's `posthog.identify(clerk.user.id)`
  value (see frontend/src/auth/clerk-auth-provider.tsx) or the funnel
  silently fails to join across the client/server boundary:

  - Clerk events carry the Clerk user id in the payload (`data.id` for
    user.created, `data.user_id` for session.created — they're not the
    same key, Clerk's session row references the user it belongs to).
  - Paddle events carry an *internal* `custom_data.user_id`; we resolve
    through the Subscription row to the user's `external_id`.
  """

  alias Engram.Observability.PostHog

  @doc """
  Forward a verified Clerk webhook event. Returns `:ok` for every input
  shape — unhandled event types are a no-op so adding a new Clerk webhook
  destination doesn't accidentally break this handler.
  """
  @spec forward_clerk_event(map()) :: :ok
  def forward_clerk_event(%{"type" => "user.created", "data" => %{"id" => clerk_id}})
      when is_binary(clerk_id) do
    _ = PostHog.capture(clerk_id, "user_signed_up", %{})
    :ok
  end

  def forward_clerk_event(%{"type" => "session.created", "data" => %{"user_id" => clerk_id}})
      when is_binary(clerk_id) do
    _ = PostHog.capture(clerk_id, "user_signed_in", %{})
    :ok
  end

  def forward_clerk_event(_event), do: :ok

  @doc """
  Forward a verified Paddle webhook event paired with the result of
  `Engram.Billing.upsert_from_paddle_event/1`. Only `subscription.activated`
  with a freshly-upserted Subscription row produces a PostHog event today —
  other event types either map to a different funnel step (handled
  elsewhere) or are pure state-sync we don't expose to product analytics.
  """
  @spec forward_paddle_event(map(), Engram.Billing.Subscription.t() | atom() | term()) :: :ok
  def forward_paddle_event(
        %{"event_type" => "subscription.activated", "data" => data},
        %Engram.Billing.Subscription{} = sub
      ) do
    case Engram.Accounts.get_user(sub.user_id) do
      %{external_id: ext_id} when is_binary(ext_id) and byte_size(ext_id) > 0 ->
        price_id = data |> Map.get("items", []) |> List.first(%{}) |> get_in(["price", "id"])

        _ =
          PostHog.capture(ext_id, "subscription_started", %{
            tier: sub.tier,
            price_id: price_id,
            paddle_subscription_id: sub.paddle_subscription_id
          })

        :ok

      _ ->
        # Self-host installs and pre-Clerk legacy rows have no external_id.
        # Without a Clerk identify call on the frontend there's nothing to
        # join against — drop silently rather than emit an :anon event that
        # would land in PostHog as un-funnelable noise.
        :ok
    end
  end

  def forward_paddle_event(_event, _result), do: :ok
end
