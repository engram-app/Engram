defmodule Engram.Workers.PersonOriginSync do
  @moduledoc """
  Fills the canonical `country`, `language` and `device_type` PostHog person
  properties (resolved by `Engram.Analytics.PersonProperties.resolve/2`) from
  Clerk's newest session, the user's app locale and PostHog's own first-event
  properties.

  Two entry points, both idempotent (a re-run `$set`s the same values and never
  lowers a field's source priority):

    * `%{"user_id" => id}`: one user, enqueued shortly after signup.
    * `backfill/0`: every live Clerk user, in chained batches of 100 users,
      ~20 Clerk requests/s (Clerk allows ~1000 per 10 s), each batch scheduling
      the next. Run once from a release rpc.

  Country level only: the Clerk client never returns IP or city. Sends nothing
  for an opted-out user or before the privacy policy that announces identified
  analytics is in effect. Args are ids only, never emails.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Analytics
  alias Engram.Analytics.PersonProperties
  alias Engram.Observability.PostHog
  alias Engram.Repo

  @batch 100
  @pause_ms 50
  @next_batch_in 5

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @doc "Start the one-time backfill."
  @spec backfill() :: {:ok, Oban.Job.t()} | {:error, term()}
  def backfill, do: Oban.insert(new(%{"backfill" => true}))

  @doc "Enqueue one user's sync. Delayed: Clerk has no session yet at `user.created`."
  @spec enqueue_user(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_user(user_id), do: Oban.insert(new(%{"user_id" => user_id}, schedule_in: 60))

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if Analytics.enabled?() and PersonProperties.policy_in_effect?() do
      run(args)
    else
      :ok
    end
  end

  defp run(%{"user_id" => id}) do
    with %User{} = user <- Accounts.get_user(id), do: sync(user)
    :ok
  end

  defp run(%{"backfill" => true} = args) do
    users = batch(args["after"])
    Enum.each(users, fn user -> sync(user) && Process.sleep(@pause_ms) end)

    if length(users) == @batch do
      next = %{"backfill" => true, "after" => List.last(users).id}
      Oban.insert(new(next, schedule_in: @next_batch_in))
    end

    :ok
  end

  # Cross-tenant on purpose, as `PersonProperties.by_user/0`. Clerk users only:
  # self-host accounts have no external_id.
  defp batch(after_id) do
    repo = Repo.maintenance()

    query =
      from(u in User,
        where: is_nil(u.deleted_at) and is_nil(u.analytics_opt_out_at),
        where: not is_nil(u.external_id) and not is_nil(u.email),
        order_by: u.id,
        limit: ^@batch
      )

    query = if after_id, do: where(query, [u], u.id > ^after_id), else: query
    Repo.cross_tenant(fn -> repo.all(query) end)
  end

  # Never raises: one bad user must not stop a batch. A failed Clerk read just
  # leaves that source out; the field fills on a later run.
  defp sync(%User{} = user) do
    case PostHog.distinct_id(user) do
      nil -> false
      distinct_id -> sync(user, distinct_id)
    end
  end

  defp sync(user, distinct_id) do
    existing =
      case PostHog.person_properties(distinct_id) do
        {:ok, props} -> props
        {:error, _} -> %{}
      end

    clerk =
      case clerk_api().latest_activity(user.external_id) do
        {:ok, %{} = activity} -> activity
        _ -> %{}
      end

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

    if traits != %{}, do: Analytics.set_traits([{user, traits}])
    true
  end

  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(_), do: nil

  defp clerk_api, do: Application.get_env(:engram, :clerk_api, Engram.Auth.Clerk.HttpApi)
end
