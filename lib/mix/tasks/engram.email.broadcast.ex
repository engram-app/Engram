defmodule Mix.Tasks.Engram.Email.Broadcast do
  @shortdoc "Send an OG-waitlist grandfather email to a CSV cohort"

  @moduledoc """
  Batch-send an OG-waitlist grandfather template (runbook §B.5) to recipients
  listed in a CSV. Defaults to a dry-run; pass `--send` to actually send.

      mix engram.email.broadcast --template og1 --csv audit.csv \\
          --checkout-url https://app.engram.page/checkout/og --send

      mix engram.email.broadcast --template og2 --csv audit.csv \\
          --expiry-date "June 1, 2027" --portal-url https://app.engram.page/portal

      mix engram.email.broadcast --template og3 --csv audit.csv

  CSV columns: `email,name` (header required). URLs and the expiry date are
  passed as flags, not per-row. Without `--send` the task renders nothing to
  the wire — it only reports the recipient count.

  Flags:
    --template     og1 | og2 | og3 (required)
    --csv          path to the cohort CSV (required)
    --send         actually send (default: dry-run)
    --checkout-url og1: founding-member checkout link
    --expiry-date  og2: human date the grandfather window closes
    --portal-url   og2: Paddle customer portal link
    --throttle-ms  delay between sends (default: 120ms ≈ 8/s)
  """
  use Mix.Task

  alias Engram.Email.Broadcast

  @switches [
    template: :string,
    csv: :string,
    send: :boolean,
    checkout_url: :string,
    expiry_date: :string,
    portal_url: :string,
    throttle_ms: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _invalid} = OptionParser.parse(argv, switches: @switches)

    template = parse_template!(opts[:template])
    csv_path = opts[:csv] || Mix.raise("--csv is required")
    rows = csv_path |> File.read!() |> parse_csv()
    send? = Keyword.get(opts, :send, false)

    Mix.Task.run("app.start")

    run_opts = [
      send?: send?,
      throttle_ms: opts[:throttle_ms] || 120,
      checkout_url: opts[:checkout_url],
      expiry_date: opts[:expiry_date],
      portal_url: opts[:portal_url]
    ]

    template
    |> Broadcast.run(rows, run_opts)
    |> print_summary(template, send?)
  end

  @doc "Parse `email,name` CSV text into recipient rows, skipping the header."
  @spec parse_csv(String.t()) :: [%{email: String.t(), name: String.t()}]
  def parse_csv(csv) do
    csv
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.drop(1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(fn line ->
      [email, name] =
        line
        |> String.split(",", parts: 2)
        |> Enum.map(&String.trim/1)

      %{email: email, name: name}
    end)
  end

  defp parse_template!("og1"), do: :og1
  defp parse_template!("og2"), do: :og2
  defp parse_template!("og3"), do: :og3

  defp parse_template!(other),
    do: Mix.raise("--template must be og1|og2|og3, got: #{inspect(other)}")

  defp print_summary(%{dry_run: true, recipients: n}, template, _send?) do
    Mix.shell().info("[dry-run] #{template}: would send to #{n} recipients. Pass --send to send.")
  end

  defp print_summary(%{sent: sent, failed: failed}, template, _send?) do
    Mix.shell().info("#{template}: sent #{sent}, failed #{length(failed)}.")

    Enum.each(failed, fn {email, reason} ->
      Mix.shell().error("  failed: #{email} — #{inspect(reason)}")
    end)
  end
end
