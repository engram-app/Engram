defmodule Mix.Tasks.Engram.Abuse.AccountOrigin do
  @shortdoc "Per-account daily user-agent breakdown (pricing v2 §E)"
  @moduledoc """
  Prints a daily breakdown of MCP request origins for a single user over
  the last N days. Backs the §E ops review workflow when an account fires
  the OriginAbuseSweep alert.

      mix engram.abuse.account_origin --user=42 --days=7

  Output format: one row per (day, fingerprint_class) tuple, sorted by
  day desc then count desc. Pipe through `column -t` for tabular display.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [user: :integer, days: :integer])

    user_id = opts[:user] || raise "--user=<id> required"
    days = opts[:days] || 7

    Mix.Task.run("app.start")

    rows = Engram.Abuse.OriginStats.summary(user_id, days)

    if rows == [] do
      Mix.shell().info("no data for user_id=#{user_id} over last #{days} day(s)")
    else
      Mix.shell().info("day\tclass\tcount")

      Enum.each(rows, fn r ->
        Mix.shell().info("#{r.day}\t#{r.class}\t#{r.count}")
      end)
    end
  end
end
