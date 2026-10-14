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
  alias Engram.I18n
  alias Engram.Legal

  require Logger

  @install_url "https://community.obsidian.md/plugins/engram-vault-sync"

  # Every email is written in the recipient's language (`Engram.I18n`, keyed
  # on `users.locale`). Each sentence is one `t(l, "...")` call on one line:
  # the translate script finds keys by scanning for that shape. Keys hold no
  # HTML; markup stays here.

  def send_welcome(%User{email: email} = user) do
    l = I18n.locale_for(user)

    heading =
      case display_name(user) do
        nil -> t(l, "Welcome to Engram.")
        name -> t(l, "Welcome to Engram, {name}.", name: name)
      end

    body = """
    <mj-text font-size="18px" font-weight="600">#{heading}</mj-text>
    <mj-text>#{t(l, "Your account is ready. Engram keeps your Obsidian vault synced across every device, and turns those notes into searchable, structured memory you can hand to any AI tool you use.")}</mj-text>
    <mj-text>#{t(l, "To get started, install the Engram plugin in Obsidian and connect it to your account. Your notes start syncing immediately.")}</mj-text>
    #{button(@install_url, t(l, "Install the Engram plugin"))}
    <mj-text>#{t(l, "The Engram team")}</mj-text>
    """

    render_and_deliver(email, I18n.t(l, "Welcome to Engram"), body, l)
  end

  defp display_name(%User{display_name: name}) when is_binary(name) and name != "", do: name
  defp display_name(_), do: nil

  defp greeting(l, user) do
    case display_name(user) do
      nil -> t(l, "Hi,")
      name -> t(l, "Hi {name},", name: name)
    end
  end

  def send_inactivity_warning_60(%User{email: email} = user) do
    l = I18n.locale_for(user)

    deliver(
      email,
      I18n.t(l, "Engram: you haven't synced in 60 days"),
      """
      <p>#{t(l, "Hi,")}</p>
      <p>#{t(l, "You haven't synced any notes to Engram in 60 days. To keep free accounts sustainable, we auto-delete vaults that have been inactive for 90 days. You have about 30 days to come back before anything is removed.")}</p>
      <p>#{t(l, "Just open Obsidian with the Engram plugin enabled and we'll reset the clock.")}</p>
      <p>Engram</p>
      """,
      []
    )
  end

  def send_inactivity_warning_80(%User{email: email} = user) do
    l = I18n.locale_for(user)

    deliver(
      email,
      I18n.t(l, "Engram: final notice, 10 days until auto-delete"),
      """
      <p>#{t(l, "Hi,")}</p>
      <p>#{t(l, "This is your final notice. Your Engram vault will be auto-deleted in about 10 days unless you sync at least once before then.")}</p>
      <p>#{t(l, "Open Obsidian with the Engram plugin enabled to keep your vault. Already moved on? No action needed, your data will be removed automatically.")}</p>
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
  def send_account_deleted_notice(%User{email: email} = user, reason)
      when reason in [:inactivity, :user, :clerk] do
    l = I18n.locale_for(user)
    {subject, text} = account_deleted_copy(l, reason)
    deliver(email, subject, "<p>#{t(l, "Hi,")}</p>\n<p>#{text}</p>\n<p>Engram</p>\n", [])
  end

  defp account_deleted_copy(l, :inactivity) do
    {I18n.t(l, "Engram: your vault was auto-deleted"),
     t(
       l,
       "Your Engram vault has been auto-deleted after 90 days of inactivity. Your Clerk login is still active, you can sign back in and start fresh whenever you want."
     )}
  end

  defp account_deleted_copy(l, :user) do
    {I18n.t(l, "Your Engram account has been deleted"),
     t(l, "You requested account deletion. Your data is being removed.")}
  end

  defp account_deleted_copy(l, :clerk) do
    {I18n.t(l, "Your Engram account has been deleted"),
     t(
       l,
       "Your account was deleted via your authentication provider. Your data is being removed."
     )}
  end

  @doc """
  Notifies a user that a vault was soft-deleted and will be purged on
  `purge_date`. `manage_url` deep-links to the vault settings page where they
  can restore or purge immediately.
  """
  def send_vault_deletion_notice(
        %User{email: email} = user,
        vault_name,
        %Date{} = purge_date,
        manage_url
      ) do
    l = I18n.locale_for(user)

    body = """
    <mj-text>#{t(l, "Your Engram vault \"{vault}\" has been deleted.", vault: vault_name)}</mj-text>
    <mj-text>#{t(l, "It will be permanently removed on {date}. Until then you can restore it, or if you meant to delete it, remove it permanently now, from your vault settings.", date: I18n.date(l, purge_date))}</mj-text>
    #{button(manage_url, t(l, "Manage vault"))}
    <mj-text>#{t(l, "No action is needed if you want it gone; it will be cleaned up automatically.")}</mj-text>
    """

    render_and_deliver(email, I18n.t(l, "Your Engram vault was deleted"), body, l)
  end

  @doc """
  Tells a user about a legal change (`kind` "notice" when it is published,
  "reminder" before a material change takes effect). `version` is the
  `Engram.Legal.TermsVersion` row; its changelog is the "what changed" line,
  translated like every other string (the seeder's changelogs are scanned).
  Voice per the workspace `docs/context/customer-email-voice.md`: first person,
  plain branded subject. Points at privacy@ because hello@ is not routed. The
  linked documents themselves are English only.
  """
  def send_legal_notice(%User{email: email} = user, version, kind)
      when kind in ["notice", "reminder"] do
    l = I18n.locale_for(user)
    doc = document_name(l, version.document)
    date = I18n.date(l, version.effective_date)
    page = Legal.url(version.document)

    subject =
      if kind == "reminder",
        do: I18n.t(l, "Engram {document} Reminder", document: doc),
        else: I18n.t(l, "Engram {document} Update", document: doc)

    opening =
      if kind == "reminder",
        do:
          t(l, "A quick reminder that Engram's updated {document} takes effect on {date}.",
            document: doc,
            date: date
          ),
        else:
          t(
            l,
            "Thank you for using Engram. I wanted to let you know that I updated Engram's {document}. The new version takes effect on {date}.",
            document: doc,
            date: date
          )

    action =
      if version.material,
        do: """
        <mj-text>#{t(l, "To keep using Engram from {date}, please review and accept the new version in the app before then.", date: date)}</mj-text>
        #{button(Legal.accept_url(), t(l, "Review and accept"))}
        <mj-text><a href="#{page}">#{t(l, "Read the full {document}", document: doc)}</a></mj-text>
        """,
        else: """
        <mj-text>#{t(l, "You do not need to do anything.")}</mj-text>
        #{button(page, t(l, "Read the {document}", document: doc))}
        """

    body = """
    <mj-text>#{greeting(l, user)}</mj-text>
    <mj-text>#{opening}</mj-text>
    <mj-text>#{t(l, "What changed: {changelog}", changelog: I18n.t(l, version.changelog || ""))}</mj-text>
    #{action}
    <mj-text>#{t(l, "If you have any questions or concerns, write to me at {email}.", email: "privacy@engram.page")}</mj-text>
    <mj-text>Todd</mj-text>
    """

    render_and_deliver(email, subject, body, l)
  end

  # Plain-text values (names, dates) go into `vars`; the result is escaped
  # once, here, so translated text and user input both reach HTML safely.
  defp t(l, key, vars \\ []), do: Template.esc(I18n.t(l, key, vars))

  defp document_name(l, "terms_of_service"), do: I18n.t(l, "Terms of Service")
  defp document_name(l, "privacy_policy"), do: I18n.t(l, "Privacy Policy")

  defp button(href, label),
    do:
      ~s(<mj-button href="#{href}" background-color="#{Tokens.brand_purple()}" color="#{Tokens.brand_purple_fg()}">#{label}</mj-button>)

  # Render an MJML body to HTML, then deliver. A render failure becomes a
  # {:error, {:render_failed, reason}} return rather than a raise.
  defp render_and_deliver(email, subject, body, locale) do
    case Template.render(body, locale) do
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
