defmodule Engram.Mailer do
  @moduledoc """
  Engram-specific email templates. Wraps the configured `Engram.Email.Provider`.

  Bodies are authored as MJML via `Engram.Email.Template` and compiled to
  responsive HTML before sending.

  Templates today:
  - `send_welcome/1`
  - `send_inactivity_warning_60/1`
  - `send_inactivity_warning_80/1`
  - `send_account_deleted_notice/2`
  - `send_vault_deletion_notice/4`
  - `send_legal_notice/3`
  """

  alias Engram.Accounts.User
  alias Engram.Email.Suppression
  alias Engram.Email.Template
  alias Engram.Email.Tokens

  require Logger

  @install_url "https://community.obsidian.md/plugins/engram-vault-sync"

  def send_welcome(%User{email: email} = user) do
    name = Template.esc(greeting_name(user))

    body = """
    <mj-text font-size="18px" font-weight="600">Welcome to Engram, #{name}.</mj-text>
    <mj-text>Your account is ready. Engram keeps your Obsidian vault synced
    across every device, and turns those notes into searchable, structured
    memory you can hand to any AI tool you use.</mj-text>
    <mj-text>To get started, install the Engram plugin in Obsidian and connect
    it to your account. Your notes start syncing immediately.</mj-text>
    <mj-button href="#{@install_url}" background-color="#{Tokens.brand_purple()}" color="#{Tokens.brand_purple_fg()}">Install the Engram plugin</mj-button>
    <mj-text>The Engram team</mj-text>
    """

    render_and_deliver(email, "Welcome to Engram", body)
  end

  defp greeting_name(%User{display_name: name}) when is_binary(name) and name != "", do: name
  defp greeting_name(_), do: "there"

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
      <p>Engram</p>
      """,
      []
    )
  end

  def send_inactivity_warning_80(%User{email: email}) do
    deliver(
      email,
      "Engram: final notice, 10 days until auto-delete",
      """
      <p>Hi,</p>
      <p>This is your final notice. Your Engram vault will be auto-deleted
      in ~10 days unless you sync at least once before then.</p>
      <p>Open Obsidian with the Engram plugin enabled to keep your vault.
      Already moved on? No action needed, your data will be removed
      automatically.</p>
      <p>Engram</p>
      """,
      []
    )
  end

  @doc """
  Sends the account-deleted notice. Copy branches on `reason` so the wording
  matches what actually happened:

    * `:inactivity` — 90-day auto-sweep wording
    * `:user`       — user-initiated delete
    * `:clerk`      — Clerk-side delete (auth provider)
  """
  def send_account_deleted_notice(%User{email: email}, reason)
      when reason in [:inactivity, :user, :clerk] do
    {subject, body} = account_deleted_copy(reason)
    deliver(email, subject, body, [])
  end

  defp account_deleted_copy(:inactivity) do
    {
      "Engram: your vault was auto-deleted",
      """
      <p>Hi,</p>
      <p>Your Engram vault has been auto-deleted after 90 days of inactivity.
      Your Clerk login is still active, you can sign back in and start
      fresh whenever you want.</p>
      <p>Engram</p>
      """
    }
  end

  defp account_deleted_copy(:user) do
    {
      "Your Engram account has been deleted",
      """
      <p>Hi,</p>
      <p>You requested account deletion. Your data is being removed.</p>
      <p>Engram</p>
      """
    }
  end

  defp account_deleted_copy(:clerk) do
    {
      "Your Engram account has been deleted",
      """
      <p>Hi,</p>
      <p>Your account was deleted via your authentication provider.
      Your data is being removed.</p>
      <p>Engram</p>
      """
    }
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
    restore it, or if you meant to delete it, remove it permanently now, from
    your vault settings.</mj-text>
    <mj-button href="#{manage_url}" background-color="#{Tokens.brand_purple()}" color="#{Tokens.brand_purple_fg()}">Manage vault</mj-button>
    <mj-text>No action is needed if you want it gone; it will be cleaned up
    automatically.</mj-text>
    """

    render_and_deliver(email, "Your Engram vault was deleted", body)
  end

  @doc """
  Tells a user about a legal change (`kind` "notice" when it is published,
  "reminder" before a material change takes effect). `version` is the
  `Engram.Legal.TermsVersion` row; its changelog is the "what changed" line.
  Voice per the workspace `docs/context/customer-email-voice.md`: first person,
  plain branded subject. Points at privacy@ because hello@ is not routed.
  """
  def send_legal_notice(%User{email: email} = user, version, kind)
      when kind in ["notice", "reminder"] do
    doc = Engram.Legal.name(version.document)
    date = Calendar.strftime(version.effective_date, "%B %-d, %Y")

    subject =
      if kind == "reminder", do: "Engram #{doc} Reminder", else: "Engram #{doc} Update"

    opening =
      if kind == "reminder",
        do: "A quick reminder that Engram's updated #{doc} takes effect on #{date}.",
        else:
          "Thank you for using Engram. I wanted to let you know that I updated Engram's #{doc}. The new version takes effect on #{date}."

    action =
      if version.material,
        do: """
        <mj-text>To keep using Engram from #{date}, please review and accept the new
        version in the app before then.</mj-text>
        #{legal_button(Engram.Legal.accept_url(), "Review and accept")}
        <mj-text><a href="#{Engram.Legal.url(version.document)}">Read the full #{doc}</a></mj-text>
        """,
        else: """
        <mj-text>You do not need to do anything.</mj-text>
        #{legal_button(Engram.Legal.url(version.document), "Read the #{doc}")}
        """

    body = """
    <mj-text>Hi #{Template.esc(greeting_name(user))},</mj-text>
    <mj-text>#{opening}</mj-text>
    <mj-text>What changed: #{Template.esc(version.changelog || "")}</mj-text>
    #{action}
    <mj-text>If you have any questions or concerns, write to me at privacy@engram.page.</mj-text>
    <mj-text>Todd</mj-text>
    """

    render_and_deliver(email, subject, body)
  end

  defp legal_button(href, label),
    do:
      ~s(<mj-button href="#{href}" background-color="#{Tokens.brand_purple()}" color="#{Tokens.brand_purple_fg()}">#{label}</mj-button>)

  # Render an MJML body to HTML, then deliver. A render failure becomes a
  # {:error, {:render_failed, reason}} return rather than a raise.
  defp render_and_deliver(email, subject, body) do
    case Template.render(body) do
      {:ok, html} -> deliver(email, subject, html, [])
      {:error, reason} -> {:error, {:render_failed, reason}}
    end
  end

  # Single send funnel: skip addresses on the suppression list (bounced /
  # complained) before handing off to the provider. Returns {:error, :suppressed}
  # so callers can surface skips without sending.
  defp deliver(email, subject, html, opts) do
    if Suppression.suppressed?(email) do
      Logger.warning(
        "Email skipped: address on suppression list",
        Engram.Logger.Metadata.with_category(:warning, :lifecycle, reason_label: :suppressed)
      )

      {:error, :suppressed}
    else
      provider().send(email, subject, html, opts)
    end
  end

  defp provider do
    Application.get_env(:engram, :email_provider, Engram.Email.NoOp)
  end
end
