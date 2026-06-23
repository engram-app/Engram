defmodule Engram.Email.NoOp do
  @moduledoc """
  Fallback email provider for self-host instances without a transactional
  email service configured. Logs the would-have-been-sent message and
  returns :ok so callers don't gate behavior on email delivery.
  """

  @behaviour Engram.Email.Provider

  require Logger

  @impl true
  def send(to, subject, html, _opts \\ []) do
    Logger.debug(
      "Email NoOp: dropping send (set RESEND_API_KEY to enable)",
      Engram.Logger.Metadata.with_category(:debug, :lifecycle,
        body_size: byte_size(html),
        reason_label: :no_provider_configured,
        kind: subject,
        method: to
      )
    )

    :ok
  end
end
