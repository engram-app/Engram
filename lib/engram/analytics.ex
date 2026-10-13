defmodule Engram.Analytics do
  @moduledoc """
  Product analytics: the one module application code calls.

  Callers speak in users and events, never in vendor ids or `$`-prefixed
  fields. The vendor is `Engram.Observability.PostHog`, used only from here,
  so replacing it touches that adapter and nothing else.

  Owns every rule that is about our users rather than about the vendor:

    * **Opt-out.** A user who objected (`analytics_opt_out_at`) gets nothing
      sent, on every path. Users are re-read through the `:user` cache, which
      the `users_changed` trigger evicts on any UPDATE, so a struct held by a
      long-lived socket cannot outlive an opt-out or an email change.
    * **Throttling** of high-frequency events (`track_activity/3`).
    * **Erasure** of every id a person is known by (`forget/1`).

  Never send note content, titles, paths, vault names or search text
  (privacy policy 2026-10-12).
  """

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Observability.PostHog
  alias Engram.Workers.PostHogErasure

  @surfaces [:obsidian_sync, :mcp, :web]
  @type surface :: :obsidian_sync | :mcp | :web
  @activity_window_ms :timer.minutes(5)

  # Longer than PostHogPersonSync's 5-minute timeout, so a batch that read the
  # user before an erasure has finished before the second erasure runs.
  @reerase_after {10, :minutes}

  @doc "Whether analytics is configured (false on self-host, dev and test)."
  @spec enabled?() :: boolean()
  def enabled?, do: PostHog.enabled?()

  @doc "Record `event` for `user`. Fire-and-forget; never raises."
  @spec track(map(), String.t(), map()) :: :ok
  def track(user, event, props \\ %{}) do
    if enabled?(), do: PostHog.capture(id_for(user), event, props), else: :ok
  end

  @doc "Record an event attached to no person (e.g. a deleted account's exit reason)."
  @spec track_anonymous(String.t(), map()) :: :ok
  def track_anonymous(event, props), do: PostHog.capture_anonymous(event, props)

  @doc """
  Record that `user` was active on `surface`. Emits `surface_active` at most
  once per user and surface per 5-minute fixed window (cluster-shared limiter).
  `props` can never override `surface`.
  """
  @spec track_activity(map(), surface(), map()) :: :ok
  def track_activity(user, surface, props \\ %{}) when surface in @surfaces do
    props = props |> Map.drop([:surface, "surface"]) |> Map.put(:surface, Atom.to_string(surface))
    track_throttled(user, "surface_active", Atom.to_string(surface), @activity_window_ms, props)
  end

  @doc """
  `track/3`, but at most one `event` per user and `dedupe` value per
  `window_ms`. The user is re-read only after the limiter allows the event, so
  the throttled-away majority costs no lookup.
  """
  @spec track_throttled(map(), String.t(), String.t(), pos_integer(), map()) :: :ok
  def track_throttled(%{id: id} = user, event, dedupe, window_ms, props) do
    with true <- enabled?(),
         {:allow, _} <-
           EngramWeb.RateLimiter.hit(
             "ph:#{event}:#{id}:#{dedupe}",
             window_ms,
             1,
             :analytics_activity
           ) do
      PostHog.capture(id_for(user), event, props)
    else
      _ -> :ok
    end
  end

  def track_throttled(_user, _event, _dedupe, _window_ms, _props), do: :ok

  @doc """
  Set traits on many people at once. `people` is `[{user, traits}]`, where
  `user` carries at least `:email`. Returns the failure so an Oban caller retries.
  """
  @spec set_traits([{map(), map()}]) :: :ok | {:error, term()}
  def set_traits(people) do
    people
    |> Enum.flat_map(fn {user, traits} ->
      case PostHog.distinct_id(user) do
        nil -> []
        id -> [{id, traits}]
      end
    end)
    |> PostHog.set_people()
  end

  @doc """
  Erase every analytics record of `user` as they are NOW (current email plus
  the legacy Clerk-id person). Runs immediately and again after
  #{elem(@reerase_after, 0)} minutes, in case an in-flight batch re-creates the
  person. Pass the pre-change struct to erase an identity the user is leaving
  (an old email).
  """
  @spec forget(map()) :: :ok
  def forget(user) do
    case {PostHog.erasure_enabled?(), known_ids(user)} do
      {false, _} ->
        :ok

      {_, []} ->
        :ok

      {true, ids} ->
        _ = PostHogErasure.enqueue(ids)
        _ = PostHogErasure.enqueue(ids, schedule_in: @reerase_after)
        :ok
    end
  end

  @doc """
  Erase the person a user leaves behind when their email changes. A change
  that maps to the same analytics id (case or whitespace only) keeps the same
  person, so nothing is erased.
  """
  @spec forget_previous_email(String.t() | nil, String.t()) :: :ok
  def forget_previous_email(old, new) when is_binary(old) do
    if PostHog.analytics_id(old) == PostHog.analytics_id(new),
      do: :ok,
      else: forget(%{email: old})
  end

  def forget_previous_email(_old, _new), do: :ok

  @doc "The id the web client identifies with, or nil when it must send nothing."
  @spec client_id(map()) :: String.t() | nil
  def client_id(user), do: PostHog.distinct_id(user)

  @doc "Whether `user` objected to analytics."
  @spec opted_out?(map()) :: boolean()
  def opted_out?(user), do: not is_nil(Map.get(user, :analytics_opt_out_at))

  defp known_ids(user) do
    email_id = if is_binary(Map.get(user, :email)), do: PostHog.analytics_id(user.email)
    Enum.reject([email_id, Map.get(user, :external_id)], &is_nil/1)
  end

  # A persisted user is re-read, so opt-out and email changes made after the
  # caller loaded its struct still apply. A deleted user resolves to nil.
  defp id_for(%User{id: id}) do
    case Accounts.get_user(id) do
      %User{} = fresh -> PostHog.distinct_id(fresh)
      nil -> nil
    end
  end

  defp id_for(user), do: PostHog.distinct_id(user)
end
