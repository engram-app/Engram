defmodule Engram.Email.Template do
  @moduledoc """
  Renders email bodies as MJML wrapped in a shared brand layout, compiled to
  responsive HTML via the `mjml` NIF. Templates live in code (version-controlled,
  testable) — Resend is a pure delivery layer and stores no templates.

  Any untrusted/user-supplied value interpolated into a body MUST be escaped
  with `esc/1` to prevent HTML/markup injection into the rendered email.

  Color literals come from `Engram.Email.Tokens` (regenerated from marketing's
  palette by `bun scripts/sync-theme.ts`). Do not inline hex values here.
  """

  alias Engram.Email.Tokens

  @doc """
  Wrap a body MJML fragment in the shared layout and compile to responsive HTML.
  Returns `{:error, reason}` on a compilation failure rather than raising, so a
  single bad render is a per-recipient failure (not an aborted broadcast).
  """
  @spec render(String.t()) :: {:ok, String.t()} | {:error, term()}
  def render(body_mjml) when is_binary(body_mjml) do
    Mjml.to_html(layout(body_mjml))
  end

  @doc "HTML-escape an untrusted value before interpolating it into MJML."
  @spec esc(term()) :: String.t()
  def esc(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp layout(body) do
    mark_url = EngramWeb.Endpoint.url() <> "/email/engram-mark.png"

    """
    <mjml>
      <mj-head>
        <mj-attributes>
          <mj-all font-family="Helvetica, Arial, sans-serif" />
          <mj-text font-size="15px" line-height="1.5" color="#{Tokens.text_primary()}" />
        </mj-attributes>
      </mj-head>
      <mj-body background-color="#{Tokens.surface_page()}">
        <mj-section padding="32px 0 8px">
          <mj-column>
            <mj-image src="#{mark_url}" width="56px" align="center" alt="Engram" padding="0" />
            <mj-text font-size="20px" font-weight="700" color="#{Tokens.brand_purple()}" align="center" padding="8px 0 0">Engram</mj-text>
          </mj-column>
        </mj-section>
        <mj-section background-color="#{Tokens.surface_card()}" border-radius="8px" padding="8px 24px">
          <mj-column>
            #{body}
          </mj-column>
        </mj-section>
        <mj-section padding="16px 0">
          <mj-column>
            <mj-text font-size="12px" color="#{Tokens.text_muted()}" align="center">Your notes are your AI's memory.</mj-text>
          </mj-column>
        </mj-section>
      </mj-body>
    </mjml>
    """
  end
end
