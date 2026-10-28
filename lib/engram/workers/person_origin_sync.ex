defmodule Engram.Workers.PersonOriginSync do
  @moduledoc """
  Fills the canonical `country`, `language` and `device_type` PostHog person
  properties (resolved by `Engram.Analytics.PersonProperties.resolve/2`) from
  Clerk's newest session, the user's app locale and PostHog's own first-event
  properties.

  Two entry points, both idempotent (a re-run `$set`s the same values and never
  lowers a field's source priority):

    * `%{"user_id" => id}`: one user, enqueued shortly after signup.
    * `backfill/0`: every live Clerk user, in chained batches of 100 users.
      Reads are paced (PostHog's personal-API limit on persons is the tight one,
      ~240/min burst, so ~2.5 users/s); the writes of a batch go out as ONE
      `set_traits` call. A user whose read failed is re-enqueued on
      their own (Oban retries and backs off) while the batch writes the rest and
      the chain advances, so one bad user never stalls the backfill or forces a
      re-read of the others.

  A user whose PostHog read failed is skipped, never resolved against an empty
  map: the stored `<field>_source` is what stops a lower source overwriting a
  higher one.

  Country level only: the Clerk client never returns IP or city. Sends nothing
  for an opted-out or deleted user, or before the privacy policy that announces
  identified analytics is in effect. Args are ids only, never emails.
  """
  use Oban.Worker, queue: :events, max_attempts: 3

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Analytics
  alias Engram.Analytics.PersonProperties
  alias Engram.Repo

  require Logger

  @batch 100
  # ~2.5 users/s: one PostHog persons read plus one Clerk read per user.
  @default_pause_ms 400
  @next_batch_in 5

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @doc "Start the one-time backfill."
  @spec backfill() :: {:ok, Oban.Job.t()} | {:error, term()}
  def backfill, do: Oban.insert(new(%{"backfill" => true}))

  @doc "Enqueue one user's sync. Delayed: Clerk has no session yet at `user.created`."
  @spec enqueue_user(Ecto.UUID.t(), non_neg_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_user(user_id, delay \\ 60) do
    Oban.insert(
      new(%{"user_id" => user_id},
        schedule_in: delay,
        unique: [period: 300, fields: [:worker, :args]]
      )
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    cond do
      not Analytics.enabled?() or not PersonProperties.policy_in_effect?() ->
        :ok

      # The stored `<field>_source` is read from PostHog's persons API, which
      # needs the personal API key. Without it nothing can be resolved safely.
      not Analytics.person_reads_enabled?() ->
        Logger.info("PersonOriginSync skipped: PostHog person reads not configured")
        :ok

      true ->
        run(args)
    end
  end

  defp run(%{"user_id" => id}) do
    # Fresh read, not the cached `Accounts.get_user/1`: an opt-out or deletion
    # inside the cache TTL or the enqueue delay must win.
    case Accounts.get_user_uncached(id) do
      %User{} = user -> single(user)
      nil -> :ok
    end
  end

  defp run(%{"backfill" => true} = args) do
    users = batch(args["after"])

    {written, failed} =
      sync(users, Application.get_env(:engram, :person_origin_pause_ms, @default_pause_ms))

    # A user that failed is retried on their own (ids only, Oban backs off), so
    # the chain always advances and resolved users are never re-read.
    if failed != [] do
      Logger.warning(
        "PersonOriginSync backfill: #{length(failed)} user(s) deferred to single retries " <>
          "(batch after=#{inspect(args["after"])})"
      )

      Enum.each(failed, fn {user, _reason} -> enqueue_user(user.id, 0) end)
    end

    with :ok <- written do
      if length(users) == @batch do
        next = %{"backfill" => true, "after" => List.last(users).id}
        Oban.insert(new(next, schedule_in: @next_batch_in))
      end

      :ok
    end
  end

  # Returns the error so Oban retries this one user.
  defp single(user) do
    case sync([user]) do
      {:ok, []} -> :ok
      {:ok, [{_user, reason}]} -> {:error, reason}
      {error, _failed} -> error
    end
  end

  # Cross-tenant on purpose, as `PersonProperties.by_user/0`. Clerk users only:
  # self-host accounts have no external_id.
  defp batch(after_id) do
    repo = Repo.maintenance()

    query =
      from(u in PersonProperties.trackable_users(),
        where: not is_nil(u.external_id),
        order_by: u.id,
        limit: ^@batch
      )

    query = if after_id, do: where(query, [u], u.id > ^after_id), else: query
    Repo.cross_tenant(fn -> repo.all(query) end)
  end

  # `{write_result, [{user, reason}]}`: the one `set_traits` write for every user
  # that resolved, and the users that could not be read.
  defp sync(users, pause_ms \\ 0) do
    results =
      Enum.map(users, fn user ->
        result = resolve(user)
        if pause_ms > 0, do: Process.sleep(pause_ms)
        {user, result}
      end)

    people = for {_user, {:ok, person}} <- results, do: person
    failed = for {user, {:error, reason}} <- results, do: {user, reason}
    write = if people == [], do: :ok, else: Analytics.set_traits(people)
    {write, failed}
  end

  # `{:ok, {user, traits}}` to write, `:skip` for nothing to write, or `{:error, _}`.
  defp resolve(%User{deleted_at: nil, external_id: external_id} = user)
       when is_binary(external_id) do
    with false <- Analytics.opted_out?(user),
         {:ok, existing} <- Analytics.person_properties(user),
         {:ok, clerk} <- clerk_activity(external_id) do
      traits =
        PersonProperties.resolve(
          %{
            country: %{clerk: clerk[:country]},
            language: %{
              app_locale: user.locale,
              browser_language: existing["$browser_language"]
            },
            device_type: %{
              clerk: clerk[:device_type],
              posthog_initial: downcase(existing["$initial_device_type"])
            }
          },
          existing
        )

      if traits == %{}, do: :skip, else: {:ok, {user, traits}}
    else
      true -> :skip
      :none -> :skip
      {:error, _} = error -> error
    end
  end

  defp resolve(_user), do: :skip

  defp clerk_activity(external_id) do
    case clerk_api().latest_activity(external_id) do
      {:ok, %{} = activity} -> {:ok, activity}
      {:ok, nil} -> {:ok, %{}}
      {:error, _} = error -> error
    end
  end

  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(_), do: nil

  defp clerk_api, do: Application.get_env(:engram, :clerk_api, Engram.Auth.Clerk.HttpApi)
end
