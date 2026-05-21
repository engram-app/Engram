defmodule Engram.Mailer do
  @moduledoc """
  Engram-specific email templates. Wraps the configured `Engram.Email.Provider`.

  Three §C inactivity-cleanup templates today:
  - `send_inactivity_warning_60/1`
  - `send_inactivity_warning_80/1`
  - `send_account_deleted_notice/1`
  """

  alias Engram.Accounts.User

  def send_inactivity_warning_60(%User{email: email}) do
    provider().send(
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
    provider().send(
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
    provider().send(
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

  defp provider do
    Application.get_env(:engram, :email_provider, Engram.Email.NoOp)
  end
end
