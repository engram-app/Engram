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

  `footer:` is optional small print (already-escaped HTML) set below the card,
  above the tagline: muted, centered, 12px.
  """
  @spec render(String.t(), Engram.I18n.locale(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def render(body_mjml, locale \\ "en", opts \\ []) when is_binary(body_mjml) do
    Mjml.to_html(layout(body_mjml, locale, Keyword.get(opts, :footer)))
  end

  @doc "HTML-escape an untrusted value before interpolating it into MJML."
  @spec esc(term()) :: String.t()
  def esc(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  # Marketing-hosted absolute URL. The backend's own /email/engram-mark.png is
  # unreachable in prod: app.engram.page is Cloudflare Pages (serves the SPA
  # index.html for unknown paths) and api.engram.page rewrites /email ->
  # /api/email -> 404. engram.page serves the asset reliably from public/.
  @mark_url "https://engram.page/engram-mark.png"

  defp layout(body, locale, footer) do
    mark_url = @mark_url
    tagline = esc(Engram.I18n.t(locale, "Your notes are your AI's memory."))

    """
    <mjml lang="#{locale}">
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
        #{footer_section(footer)}
        <mj-section padding="#{if footer, do: "4px 0 16px", else: "16px 0"}">
          <mj-column>
            <mj-text font-size="12px" color="#{Tokens.text_muted()}" align="center">#{tagline}</mj-text>
          </mj-column>
        </mj-section>
      </mj-body>
    </mjml>
    """
  end

  defp footer_section(nil), do: ""

  defp footer_section(footer) do
    """
    <mj-section padding="16px 24px 0">
      <mj-column>
        <mj-text font-size="12px" line-height="1.5" color="#{Tokens.text_muted()}" align="center">#{footer}</mj-text>
      </mj-column>
    </mj-section>
    """
  end
end
