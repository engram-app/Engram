defmodule Engram.Email.Broadcast do
  @moduledoc """
  Batch-send an OG-waitlist grandfather template (runbook §B.5) to a list of
  `Engram.Email.Recipient`s. Backs `mix engram.email.broadcast`.

  The template is a per-variant struct (`OG1`/`OG2`/`OG3`) carrying its required
  parameters, so "og1 needs a checkout URL" is a construction-time invariant —
  unrepresentable without it — rather than a mid-send `fetch!`.

  Defaults to a dry-run; pass `send?: true` to actually send. Resend has no
  bulk-HTML endpoint, so this sends one request per recipient — failures are
  collected and returned rather than raised, and an optional `:throttle_ms`
  paces sends under Resend's rate limit.
  """

  alias Engram.Email.Recipient
  alias Engram.Mailer

  defmodule OG1 do
    @moduledoc "OG email 1 (pricing-locked heads-up + checkout)."
    @enforce_keys [:checkout_url]
    defstruct [:checkout_url]
    @type t :: %__MODULE__{checkout_url: String.t()}
  end

  defmodule OG2 do
    @moduledoc "OG email 2 (30-day expiry reminder + portal link)."
    @enforce_keys [:expiry_date, :portal_url]
    defstruct [:expiry_date, :portal_url]
    @type t :: %__MODULE__{expiry_date: String.t(), portal_url: String.t()}
  end

  defmodule OG3 do
    @moduledoc "OG email 3 (post-expiry notice)."
    defstruct []
    @type t :: %__MODULE__{}
  end

  @type template :: OG1.t() | OG2.t() | OG3.t()
  @type result ::
          {:dry_run, %{recipients: non_neg_integer()}}
          | {:sent, %{sent: non_neg_integer(), failed: [{String.t(), term()}]}}

  @spec run(template(), [Recipient.t()], keyword()) :: result()
  def run(template, recipients, opts \\ []) do
    if Keyword.get(opts, :send?, false) do
      {:sent, send_all(template, recipients, opts)}
    else
      {:dry_run, %{recipients: length(recipients)}}
    end
  end

  defp send_all(template, recipients, opts) do
    throttle_ms = Keyword.get(opts, :throttle_ms, 0)

    Enum.reduce(recipients, %{sent: 0, failed: []}, fn %Recipient{} = recipient, acc ->
      acc =
        case send_one(template, recipient) do
          :ok -> %{acc | sent: acc.sent + 1}
          {:error, reason} -> %{acc | failed: acc.failed ++ [{recipient.email, reason}]}
        end

      if throttle_ms > 0, do: Process.sleep(throttle_ms)
      acc
    end)
  end

  defp send_one(%OG1{checkout_url: url}, recipient),
    do: Mailer.send_og_grandfather_1(recipient, url)

  defp send_one(%OG2{expiry_date: date, portal_url: url}, recipient),
    do: Mailer.send_og_grandfather_2(recipient, date, url)

  defp send_one(%OG3{}, recipient),
    do: Mailer.send_og_grandfather_3(recipient)
end
