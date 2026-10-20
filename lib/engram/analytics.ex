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
    * **Our own copy** of every event (`Engram.Analytics.EventLog`), under
      the same opt-out, whether or not PostHog is configured.

  Never send note content, titles, paths, vault names or search text
  (privacy policy 2026-10-12).
  """

  import Ecto.Query, only: [where: 2, where: 3]

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Analytics.EventLog
  alias Engram.Analytics.Folds
  alias Engram.Observability.PostHog
  alias Engram.Workers.PostHogErasure

  require Logger

  @surfaces [:obsidian_sync, :mcp, :web]
  @type surface :: :obsidian_sync | :mcp | :web
  @activity_window_ms :timer.minutes(5)
  @limit_window_ms :timer.hours(1)

  # Longer than PostHogPersonSync's 5-minute timeout, so a batch that read the
  # user before an erasure has finished before the second erasure runs.
  @reerase_after {10, :minutes}

  @doc "Whether analytics is configured (false on self-host, dev and test)."
  @spec enabled?() :: boolean()
  def enabled?, do: PostHog.enabled?()

  # Whether an event goes anywhere: PostHog, our event log, or both.
  defp recording?, do: enabled?() or EventLog.enabled?()

  @doc "Record `event` for `user`. Fire-and-forget; never raises."
  @spec track(map(), String.t(), map()) :: :ok
  def track(user, event, props \\ %{}) do
    if recording?(), do: emit(user, event, props), else: :ok
  end

  @doc """
  Record a web-app event (`Engram.Analytics.ClientEvents`) in our event log
  ONLY. The browser sends the same event to PostHog itself, so forwarding it
  would count it twice. Same opt-out as every other path.
  """
  @spec record_client_event(User.t(), String.t(), map()) :: :ok
  def record_client_event(%User{} = user, event, props) do
    case person(user) do
      {nil, _user_id} -> :ok
      {_distinct_id, user_id} -> EventLog.record(user_id, event, props)
    end
  end

  @doc "Record an event attached to no person (e.g. a deleted account's exit reason)."
  @spec track_anonymous(String.t(), map()) :: :ok
  def track_anonymous(event, props) do
    :ok = EventLog.record(nil, event, props)
    PostHog.capture_anonymous(event, props)
  end

  @doc """
  Record that `user` was active on `surface`. Emits `surface_active` at most
  once per user and surface per 5-minute fixed window (cluster-shared limiter).
  `props` can never override `surface`. `:dedupe` gives an activity its own
  window within a surface, so a frequent one (browsing) cannot mask a rarer
  one (editing) that shares the surface.
  """
  @spec track_activity(map(), surface(), map(), keyword()) :: :ok
  def track_activity(user, surface, props \\ %{}, opts \\ []) when surface in @surfaces do
    surface = Atom.to_string(surface)
    props = props |> Map.drop([:surface, "surface"]) |> Map.put(:surface, surface)
    dedupe = Keyword.get(opts, :dedupe, surface)
    track_folded(user, "surface_active", dedupe, @activity_window_ms, props, %{events: 1})
  end

  @doc """
  `track_throttled/5` that also counts. `counts` (`%{name => n}`) is added on
  every call, and the event that is sent carries, and resets, the totals since
  the previous one, so `calls` (say) stays exact while the event is throttled.
  Counts no later event picks up are sent as `<event>_rollup` within 5
  minutes. See `Engram.Analytics.Folds`.
  """
  @spec track_folded(map(), String.t(), String.t(), pos_integer(), map(), map()) :: :ok
  def track_folded(%{id: id} = user, event, dedupe, window_ms, props, counts) do
    if recording?() do
      key = {event, id, dedupe}
      :ok = Folds.add(key, counts, props)

      track_throttled(user, event, dedupe, window_ms, fn ->
        Map.merge(props, Folds.take(key, Map.keys(counts)))
      end)
    else
      :ok
    end
  end

  def track_folded(_user, _event, _dedupe, _window_ms, _props, _counts), do: :ok

  @doc """
  Record that `user` was refused by plan limit `limit_key` (a 402, a refused
  create, a spent budget). At most one `limit_hit` per user and key per hour,
  so a bulk import past a cap costs one event. `props` (`surface`, `silent`)
  can never override `limit_key` or `tier`. A limit hit on every job, rather
  than on a user action, passes a longer `window_ms`.
  """
  @spec track_limit_hit(map(), atom() | String.t(), map(), pos_integer()) :: :ok
  def track_limit_hit(user, limit_key, props \\ %{}, window_ms \\ @limit_window_ms) do
    key = to_string(limit_key)

    track_throttled(user, "limit_hit", key, window_ms, fn ->
      Map.merge(props, %{limit_key: key, tier: tier(user)})
    end)
  end

  @doc """
  Record that a sync request from `user` was refused as `kind` (a 409, 413,
  426, or a CRDT refusal). At most one `sync_error` per user and kind per hour,
  so a retry loop costs one event.
  """
  @spec track_sync_error(map(), atom() | String.t(), map()) :: :ok
  def track_sync_error(user, kind, props \\ %{}) do
    kind = to_string(kind)
    track_throttled(user, "sync_error", kind, @limit_window_ms, Map.put(props, :kind, kind))
  end

  defp tier(%User{} = user), do: user |> Engram.Billing.tier() |> Atom.to_string()
  defp tier(_user), do: nil

  @doc """
  `track/3`, but at most one `event` per user and `dedupe` value per
  `window_ms`. The user is re-read only after the limiter allows the event, so
  the throttled-away majority costs no lookup. `props` may be a 0-arity
  function, built only when the event is allowed.
  """
  @spec track_throttled(map(), String.t(), String.t(), pos_integer(), map() | (-> map())) ::
          :ok
  def track_throttled(%{id: id} = user, event, dedupe, window_ms, props) do
    with true <- recording?(),
         {:allow, _} <-
           EngramWeb.RateLimiter.hit(
             "ph:#{event}:#{id}:#{dedupe}",
             window_ms,
             1,
             :analytics_activity
           ) do
      props = if is_function(props, 0), do: props.(), else: props
      emit(user, event, props)
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
  (an old email). Best-effort: a failure is logged, never raised. Use
  `erase/1` where the caller must know.
  """
  @spec forget(map()) :: :ok
  def forget(user) do
    case erase(user) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "PostHog erasure could not be queued",
          reason: Engram.Logger.Metadata.safe_reason(reason)
        )

        :ok
    end
  end

  @doc """
  Queue the erasure `forget/1` describes, returning any insert failure so a
  caller can roll back with it. Joins the caller's transaction.
  """
  @spec erase(map()) :: :ok | {:error, term()}
  def erase(user) do
    case {PostHog.erasure_enabled?(), known_ids(user)} do
      {false, _} ->
        # Self-host and dev have no key on purpose. With capture on, erasure
        # is owed: a missing key means opt-outs and deletions erase nothing.
        if PostHog.enabled?(),
          do: Logger.error("PostHog capture is on but erasure is not configured")

        :ok

      {_, []} ->
        :ok

      {true, ids} ->
        with {:ok, _} <- PostHogErasure.enqueue(ids),
             {:ok, _} <- PostHogErasure.enqueue(ids, schedule_in: @reerase_after) do
          :ok
        end
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

  @doc """
  Cancel every erasure of `user` still waiting to run (scheduled re-erase,
  queued, or retrying through a PostHog outage), for a user who withdrew their
  objection. Any of them would delete the whole person, including what the
  user sends after consenting again. Joins the caller's transaction.
  """
  @spec cancel_pending_erasure(map()) :: :ok
  def cancel_pending_erasure(user) do
    ids = known_ids(user)

    {:ok, _} =
      Oban.Job
      |> where(worker: ^inspect(PostHogErasure))
      |> where([j], j.state in ["scheduled", "available", "retryable"])
      |> where([j], fragment("? @> ?", j.args, ^%{"distinct_ids" => ids}))
      |> Oban.cancel_all_jobs()

    :ok
  end

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

  # Both sinks get the event, or neither: a nil distinct id (opted out, no
  # email, deleted) means nothing is recorded anywhere.
  defp emit(user, event, props) do
    case person(user) do
      {nil, _user_id} ->
        :ok

      {distinct_id, user_id} ->
        if user_id, do: :ok = EventLog.record(user_id, event, props)
        PostHog.capture(distinct_id, event, props)
    end
  end

  # A persisted user is re-read, so opt-out and email changes made after the
  # caller loaded its struct still apply. A deleted user resolves to nil. Only
  # a persisted user has an id to store; any other map reaches PostHog only.
  defp person(%User{id: id}) do
    case Accounts.get_user(id) do
      %User{} = fresh -> {PostHog.distinct_id(fresh), fresh.id}
      nil -> {nil, nil}
    end
  end

  defp person(user), do: {PostHog.distinct_id(user), nil}
end
