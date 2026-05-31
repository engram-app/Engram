defmodule Mix.Tasks.Engram.Billing.Reconcile do
  @shortdoc "Reconcile local subscriptions against Paddle"

  @moduledoc """
  Reconcile the local `subscriptions` table against Paddle.

      mix engram.billing.reconcile          # 7 days
      mix engram.billing.reconcile --days 30

  Prints a summary map. Drift entries are also written to the structured
  log at `:error` level so Sentry captures them.

  In a release shell (`bin/engram rpc`), do NOT call this task — Mix
  isn't available. Inline the body:

      Engram.Billing.Reconciliation.run(7)
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [days: :integer])
    days = Keyword.get(opts, :days, 7)

    Mix.Task.run("app.start")

    result = Engram.Billing.Reconciliation.run(days)
    Mix.shell().info("reconciliation result: " <> inspect(result, pretty: true))
  end
end
