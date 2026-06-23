defmodule Engram.Workers.OriginAbuseSweep do
  @moduledoc """
  Pricing v2 §E — daily sweep that flags accounts whose MCP traffic has
  exceeded Pro fair-use (10k/day) for 3 consecutive days. Telemetry-only
  per work-order decision: no auto-suspend, no throttle. Ops sees the
  alert, reviews, contacts the customer about converting to a future
  Developer/API tier.

  Runs at 04:00 UTC daily (after §C InactivityCleanup at 03:30 UTC).
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Engram.Abuse.OriginStats
  alias Engram.Logger.Metadata

  require Logger

  @cap 10_000
  @consecutive 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case OriginStats.users_exceeding_cap(@cap, @consecutive) do
      [] ->
        :ok

      user_ids ->
        for user_id <- user_ids do
          :telemetry.execute(
            [:engram, :abuse, :pro_origin_exceeded],
            %{count: 1},
            %{user_id: user_id, cap: @cap, days: @consecutive}
          )

          Logger.warning(
            "OriginAbuseSweep — user exceeded Pro fair-use for #{@consecutive} consecutive days",
            Metadata.with_category(:warning, :oban,
              user_id: user_id,
              cap: @cap,
              reason_label: :pro_origin_exceeded
            )
          )
        end

        :ok
    end
  end
end
