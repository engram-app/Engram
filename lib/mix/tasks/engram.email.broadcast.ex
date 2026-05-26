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

  CSV columns: `email,name` (header required). A malformed row or an invalid
  email aborts before any send, naming the offending line — recipients are
  never silently dropped. Required flags are validated up front too.

  Flags:
    --template     og1 | og2 | og3 (required)
    --csv          path to the cohort CSV (required)
    --send         actually send (default: dry-run)
    --checkout-url og1: founding-member checkout link (required for og1)
    --expiry-date  og2: human date the grandfather window closes (required for og2)
    --portal-url   og2: Paddle customer portal link (required for og2)
    --throttle-ms  delay between sends (default: 120ms ≈ 8/s)
  """
  use Mix.Task

  alias Engram.Email.Broadcast
  alias Engram.Email.Broadcast.{OG1, OG2, OG3}
  alias Engram.Email.Recipient

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

    csv_path = opts[:csv] || Mix.raise("--csv is required")
    template = build_template(opts)
    recipients = csv_path |> File.read!() |> parse_csv()
    send? = Keyword.get(opts, :send, false)

    Mix.Task.run("app.start")

    template
    |> Broadcast.run(recipients, send?: send?, throttle_ms: opts[:throttle_ms] || 120)
    |> print_summary(template)
  end

  @doc """
  Parse `email,name` CSV text into validated recipients, skipping the header and
  blank lines. Raises `Mix.Error` naming the line on a malformed row or invalid
  email — never silently drops a recipient.
  """
  @spec parse_csv(String.t()) :: [Recipient.t()]
  def parse_csv(csv) do
    csv
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.drop(1)
    |> Enum.reject(fn {line, _} -> String.trim(line) == "" end)
    |> Enum.map(&parse_row/1)
  end

  defp parse_row({line, lineno}) do
    case String.split(line, ",", parts: 2) do
      [email, name] ->
        case Recipient.new(email, name) do
          {:ok, recipient} ->
            recipient

          {:error, :invalid_email} ->
            Mix.raise("invalid email on CSV line #{lineno}: #{inspect(String.trim(email))}")
        end

      _ ->
        Mix.raise("malformed CSV line #{lineno} (expected `email,name`): #{inspect(line)}")
    end
  end

  defp build_template(opts) do
    case opts[:template] do
      "og1" -> %OG1{checkout_url: require_opt!(opts, :checkout_url, "--checkout-url")}
      "og2" -> %OG2{
                 expiry_date: require_opt!(opts, :expiry_date, "--expiry-date"),
                 portal_url: require_opt!(opts, :portal_url, "--portal-url")
               }
      "og3" -> %OG3{}
      other -> Mix.raise("--template must be og1|og2|og3, got: #{inspect(other)}")
    end
  end

  defp require_opt!(opts, key, flag) do
    case opts[key] do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("#{flag} is required for this template")
    end
  end

  defp print_summary({:dry_run, %{recipients: n}}, template) do
    Mix.shell().info(
      "[dry-run] #{label(template)}: would send to #{n} recipients. Pass --send to send."
    )
  end

  defp print_summary({:sent, %{sent: sent, failed: failed}}, template) do
    Mix.shell().info("#{label(template)}: sent #{sent}, failed #{length(failed)}.")

    Enum.each(failed, fn {email, reason} ->
      Mix.shell().error("  failed: #{email} — #{inspect(reason)}")
    end)
  end

  defp label(%OG1{}), do: "og1"
  defp label(%OG2{}), do: "og2"
  defp label(%OG3{}), do: "og3"
end
