defmodule Engram.Workers.PostHogPersonSync do
  @moduledoc """
  Daily push of every live user's account facts to their PostHog person, so
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

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Analytics.enabled?() and PersonProperties.policy_in_effect?() do
      PersonProperties.all() |> Analytics.set_traits()
    else
      :ok
    end
  end
end
