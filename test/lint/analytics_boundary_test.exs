defmodule Engram.Lint.AnalyticsBoundaryTest do
  # Analytics is centralised: application code calls `Engram.Analytics`, and
  # only these files may touch the vendor adapter. Swapping PostHog out must
  # stay a change to the adapter alone.
  use ExUnit.Case, async: true

  @allowed MapSet.new([
             "lib/engram/analytics.ex",
             "lib/engram/observability/posthog.ex",
             "lib/engram/workers/posthog_erasure.ex"
           ])

  test "only Engram.Analytics and its erasure worker reference the PostHog adapter" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(&MapSet.member?(@allowed, &1))
      |> Enum.filter(&(File.read!(&1) =~ "Observability.PostHog"))

    assert offenders == [],
           "Call Engram.Analytics instead of Engram.Observability.PostHog in:\n" <>
             Enum.join(offenders, "\n")
  end
end
