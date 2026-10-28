defmodule Engram.Workers.PostHogPersonSync do
  @moduledoc """
  Daily push of the account facts of every live user who may be identified to their PostHog person, so
  PostHog can segment by plan, size and signup date.

  Self-healing by construction: each run re-sends the full current state, so a
  new property fills in on the next run and a missed run costs one day of
  staleness. No-op when PostHog is not configured (self-host, dev, test).

  Only account-level facts leave: never note content, titles, paths, vault
  names or search text (privacy policy 2026-10-12).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Engram.Analytics
  alias Engram.Analytics.PersonProperties

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Analytics.enabled?() do
      # Per user: everyone once the policy is in effect, before that only users
      # who accepted it (`PersonProperties.identifiable_users/0`).
      people = PersonProperties.all()

      Logger.info(
        "PostHogPersonSync: sent=#{length(people)} gated=#{PersonProperties.gated_count()}"
      )

      Analytics.set_traits(people)
    else
      :ok
    end
  end
end
