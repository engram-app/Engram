defmodule Engram.Mailer do
  @moduledoc """
  Engram-specific email templates. Wraps the configured `Engram.Email.Provider`.

  Bodies are authored as MJML via `Engram.Email.Template` and compiled to
  responsive HTML before sending.

  Templates today:
  - `send_welcome/1`
  - `send_og_grandfather_1/2`, `send_og_grandfather_2/3`, `send_og_grandfather_3/1` (take a `Recipient`)
  - `send_inactivity_warning_60/1`
  - `send_inactivity_warning_80/1`
  - `send_account_deleted_notice/1`
  - `send_vault_deletion_notice/4`
  """

  alias Engram.Accounts.User
  alias Engram.Email.Recipient
  alias Engram.Email.Suppression
  alias Engram.Email.Template

  require Logger

  @install_url "https://engram.page/install"

  def send_welcome(%User{email: email} = user) do
    name = Template.esc(greeting_name(user))

    body = """
    <mj-text font-size="18px" font-weight="600">Welcome to Engram, #{name}.</mj-text>
    <mj-text>Your account is ready. Engram keeps your Obsidian vault synced
    across every device — and turns those notes into searchable, structured
    memory you can hand to any AI tool you use.</mj-text>
    <mj-text>To get started, install the Engram plugin in Obsidian and connect
    it to your account. Your notes start syncing immediately.</mj-text>
    <mj-button href="#{@install_url}" background-color="#{Engram.Email.Tokens.brand_purple()}" color="#{Engram.Email.Tokens.brand_purple_fg()}">Install the Engram plugin</mj-button>
    <mj-text>— The Engram team</mj-text>
    """

    render_and_deliver(email, "Welcome to Engram", body)
  end

  defp greeting_name(%User{display_name: name}) when is_binary(name) and name != "", do: name
  defp greeting_name(_), do: "there"

  @doc """
  OG-waitlist email 1 (runbook §B.5.1): pricing updated, grandfather locked.
  `checkout_url` is the founding-member checkout link.
  """
  def send_og_grandfather_1(%Recipient{email: email, name: name}, checkout_url) do
    name = Template.esc(name)

    body = """
    <mj-text>Hi #{name},</mj-text>
    <mj-text>You joined the Engram waitlist back when our pricing was $5 for
    Starter and $10 for Pro. As of today, we've updated our published pricing to
    $10 Starter and $20 Pro to reflect the work we're putting into the product.</mj-text>
    <mj-text>Because you're an early supporter, we're honoring the prices you
    signed up for. For the next 12 months, you can subscribe at $5 Starter or
    $10 Pro — no code required, applied automatically when you check out.</mj-text>
    <mj-text>If you're already subscribed, no action needed. If you're ready to
    subscribe, here's the link:</mj-text>
    <mj-button href="#{checkout_url}" background-color="#5b5bd6">Subscribe at founding-member pricing</mj-button>
    <mj-text>After 12 months, your subscription will renew at our standard
    $10 / $20 pricing.</mj-text>
    <mj-text>Thanks for being part of the founding cohort.<br />— Todd</mj-text>
    """

    render_and_deliver(
      email,
      "Engram pricing update — your founding-member pricing is locked",
      body
    )
  end

  @doc """
  OG-waitlist email 2 (runbook §B.5.2): grandfather expires in 30 days.
  `expiry_date` is a human-formatted date string; `portal_url` is the Paddle
  customer portal link.
  """
  def send_og_grandfather_2(%Recipient{email: email, name: name}, expiry_date, portal_url) do
    name = Template.esc(name)
    expiry_date = Template.esc(expiry_date)

    body = """
    <mj-text>Hi #{name},</mj-text>
    <mj-text>A year ago we honored the original $5/$10 Engram pricing you signed
    up for as a founding waitlist member. That grandfather window expires in 30 days.</mj-text>
    <mj-text>Starting #{expiry_date}, your subscription will renew at our standard
    rate: $10 Starter / $20 Pro.</mj-text>
    <mj-text>If you'd like to cancel before the change, you can manage your
    subscription here:</mj-text>
    <mj-button href="#{portal_url}" background-color="#5b5bd6">Manage subscription</mj-button>
    <mj-text>If you want to keep going at the new rate, no action needed.</mj-text>
    <mj-text>Thanks again for being part of the early Engram crew.</mj-text>
    """

    render_and_deliver(
      email,
      "Your Engram founding-member pricing expires in 30 days",
      body
    )
  end

  @doc """
  OG-waitlist email 3 (runbook §B.5.3): post-expiry notice, no action needed.
  """
  def send_og_grandfather_3(%Recipient{email: email, name: name}) do
    name = Template.esc(name)

    body = """
    <mj-text>Hi #{name}, your founding-member grandfather window has ended. Your
    subscription is now at our standard rate ($10 Starter / $20 Pro). No action
    needed; you can manage your subscription anytime in your dashboard.</mj-text>
    """

    render_and_deliver(email, "Your Engram pricing has updated", body)
  end

  def send_inactivity_warning_60(%User{email: email}) do
    deliver(
      email,
      "Engram: you haven't synced in 60 days",
      """
      <p>Hi,</p>
      <p>You haven't synced any notes to Engram in 60 days. To keep
      free accounts sustainable, we auto-delete vaults that have been
      inactive for 90 days. You have ~30 days to come back before
      anything is removed.</p>
      <p>Just open Obsidian with the Engram plugin enabled and we'll
      reset the clock.</p>
      <p>— Engram</p>
      """,
      []
    )
  end

  def send_inactivity_warning_80(%User{email: email}) do
    deliver(
      email,
      "Engram: final notice — 10 days until auto-delete",
      """
      <p>Hi,</p>
      <p>This is your final notice. Your Engram vault will be auto-deleted
      in ~10 days unless you sync at least once before then.</p>
      <p>Open Obsidian with the Engram plugin enabled to keep your vault.
      Already moved on? No action needed — your data will be removed
      automatically.</p>
      <p>— Engram</p>
      """,
      []
    )
  end

  def send_account_deleted_notice(%User{email: email}) do
    deliver(
      email,
      "Engram: your vault was auto-deleted",
      """
      <p>Hi,</p>
      <p>Your Engram vault has been auto-deleted after 90 days of inactivity.
      Your Clerk login is still active — you can sign back in and start
      fresh whenever you want.</p>
      <p>— Engram</p>
      """,
      []
    )
  end

  @doc """
  Notifies a user that a vault was soft-deleted and will be purged on
  `purge_date` (a preformatted string). `manage_url` deep-links to the vault
  settings page where they can restore or purge immediately.
  """
  def send_vault_deletion_notice(%User{email: email}, vault_name, purge_date, manage_url) do
    vault_name = Template.esc(vault_name)
    purge_date = Template.esc(purge_date)

    body = """
    <mj-text>Your Engram vault "#{vault_name}" has been deleted.</mj-text>
    <mj-text>It will be permanently removed on #{purge_date}. Until then you can
    restore it — or, if you meant to delete it, remove it permanently now — from
    your vault settings.</mj-text>
    <mj-button href="#{manage_url}" background-color="#5b5bd6">Manage vault</mj-button>
    <mj-text>No action is needed if you want it gone; it will be cleaned up
    automatically.</mj-text>
    """

    render_and_deliver(email, "Your Engram vault was deleted", body)
  end

  # Render an MJML body to HTML, then deliver. A render failure becomes a
  # {:error, {:render_failed, reason}} return (not a raise) so one bad render is
  # a per-recipient failure the broadcast can collect, not an aborted cohort.
  defp render_and_deliver(email, subject, body) do
    case Template.render(body) do
      {:ok, html} -> deliver(email, subject, html, [])
      {:error, reason} -> {:error, {:render_failed, reason}}
    end
  end

  # Single send funnel: skip addresses on the suppression list (bounced /
  # complained) before handing off to the provider. Returns {:error, :suppressed}
  # so callers (e.g. the broadcast task) can surface skips without sending.
  defp deliver(email, subject, html, opts) do
    if Suppression.suppressed?(email) do
      Logger.info("Email skipped: address on suppression list", category: :email)
      {:error, :suppressed}
    else
      provider().send(email, subject, html, opts)
    end
  end

  defp provider do
    Application.get_env(:engram, :email_provider, Engram.Email.NoOp)
  end
end
