defmodule EngramWeb.CSPTest do
  @moduledoc """
  CSP is built from runtime config so a Clerk custom-domain
  (`CLERK_ISSUER=https://clerk.engram.page`) or self-host operator's
  own Clerk tenant flows into `script-src` / `connect-src` / `frame-src`
  without needing a code change.

  Pure unit tests on `EngramWeb.CSP.header/0`. Each test sets the
  relevant `Application` env, asserts on the rendered header, and
  restores prior state on exit.
  """
  use ExUnit.Case, async: false

  alias EngramWeb.CSP

  setup do
    prior_issuer = Application.get_env(:engram, :clerk_issuer)
    on_exit(fn -> Application.put_env(:engram, :clerk_issuer, prior_issuer) end)
    :ok
  end

  describe "static directives" do
    test "always present regardless of integration config" do
      Application.put_env(:engram, :clerk_issuer, nil)

      header = CSP.header()

      assert header =~ "default-src 'self'"
      assert header =~ "style-src 'self' 'unsafe-inline'"
      assert header =~ "img-src 'self' data: blob: https:"
      assert header =~ "font-src 'self' data:"
      assert header =~ "worker-src 'self' blob:"
      assert header =~ "form-action 'self'"
      assert header =~ "base-uri 'self'"
      assert header =~ "frame-ancestors 'none'"
    end

    test "always whitelists Cloudflare Turnstile (Clerk bot-protection)" do
      Application.put_env(:engram, :clerk_issuer, nil)

      header = CSP.header()

      assert script_src(header) =~ "https://challenges.cloudflare.com"
      assert frame_src(header) =~ "https://challenges.cloudflare.com"
    end

    test "always whitelists Paddle (billing overlay)" do
      Application.put_env(:engram, :clerk_issuer, nil)

      header = CSP.header()

      assert script_src(header) =~ "https://*.paddle.com"
      assert connect_src(header) =~ "https://*.paddle.com"
      assert frame_src(header) =~ "https://*.paddle.com"
    end

    test "always whitelists Cloudflare Web Analytics (edge-injected beacon)" do
      # CF Web Analytics injects `<script src="https://static.cloudflareinsights.com/
      # beacon.min.js/...">` at edge time when the dashboard toggle is on. The
      # beacon also POSTs telemetry back to the same host, so it needs both
      # script-src + connect-src. Without this allowlist, prod analytics breaks
      # silently (no console error from the beacon itself — CSP blocks the script
      # load before it can run). See workspace memory cookie-audit-2026-05-24
      # for why this matters for the no-banner launch posture.
      Application.put_env(:engram, :clerk_issuer, nil)

      header = CSP.header()

      assert script_src(header) =~ "https://static.cloudflareinsights.com"
      assert connect_src(header) =~ "https://static.cloudflareinsights.com"
    end

    test "always whitelists Sentry ingest hosts on connect-src" do
      # Sentry browser SDK is bundled (no script-src host needed) but
      # captured events POST to `*.ingest.sentry.io`. Without this
      # entry the SDK silently fails — the network POST returns blocked
      # by CSP, no error reaches `Sentry.captureException`'s caller,
      # and prod errors evaporate at the CSP gate.
      Application.put_env(:engram, :clerk_issuer, nil)

      header = CSP.header()

      assert connect_src(header) =~ "https://*.ingest.sentry.io"
    end

    test "always whitelists PostHog ingest hosts on connect-src" do
      # Same silent-failure trap as Sentry. PostHog SDK is bundled, so
      # only connect-src needs the wildcard regional ingest hosts
      # (us.i.posthog.com, eu.i.posthog.com). Without this entry
      # `posthog.capture(...)` returns successfully but the network
      # POST is blocked by CSP and no funnel data lands.
      Application.put_env(:engram, :clerk_issuer, nil)

      header = CSP.header()

      assert connect_src(header) =~ "https://*.i.posthog.com"
      assert connect_src(header) =~ "https://*.posthog.com"
    end
  end

  describe "Clerk integration — dev/test instance (CLERK_ISSUER under *.clerk.accounts.dev)" do
    test "whitelists *.clerk.accounts.dev + *.clerk.com on script-src / connect-src / frame-src" do
      Application.put_env(:engram, :clerk_issuer, "https://example.clerk.accounts.dev")

      header = CSP.header()

      assert script_src(header) =~ "https://*.clerk.accounts.dev"
      assert script_src(header) =~ "https://*.clerk.com"
      assert connect_src(header) =~ "https://*.clerk.accounts.dev"
      assert connect_src(header) =~ "https://*.clerk.com"
      assert frame_src(header) =~ "https://*.clerk.accounts.dev"
    end
  end

  describe "Clerk integration — prod custom domain (CLERK_ISSUER on tenant zone)" do
    test "issuer host is allowed on script-src" do
      Application.put_env(:engram, :clerk_issuer, "https://clerk.engram.page")

      assert script_src(CSP.header()) =~ "https://clerk.engram.page"
    end

    test "issuer host is allowed on connect-src" do
      Application.put_env(:engram, :clerk_issuer, "https://clerk.engram.page")

      assert connect_src(CSP.header()) =~ "https://clerk.engram.page"
    end

    test "issuer host is allowed on frame-src" do
      Application.put_env(:engram, :clerk_issuer, "https://clerk.engram.page")

      assert frame_src(CSP.header()) =~ "https://clerk.engram.page"
    end

    test "operator-supplied custom domain (e.g. self-host) flows in identically" do
      Application.put_env(:engram, :clerk_issuer, "https://auth.example.com")

      header = CSP.header()

      assert script_src(header) =~ "https://auth.example.com"
      assert connect_src(header) =~ "https://auth.example.com"
      assert frame_src(header) =~ "https://auth.example.com"
    end

    test "trailing slash + whitespace in issuer is normalized" do
      Application.put_env(:engram, :clerk_issuer, "  https://clerk.engram.page/  ")

      header = CSP.header()

      assert script_src(header) =~ "https://clerk.engram.page"
      refute script_src(header) =~ "https://clerk.engram.page/"
    end
  end

  describe "Clerk integration — degenerate config" do
    test "nil clerk_issuer does NOT inject a stray host" do
      Application.put_env(:engram, :clerk_issuer, nil)

      header = CSP.header()

      refute header =~ "https://nil"
      refute header =~ "https://\""
    end

    test "empty-string clerk_issuer does NOT inject a stray host" do
      Application.put_env(:engram, :clerk_issuer, "")

      header = CSP.header()

      refute header =~ "https:// "
      refute header =~ "https:// ;"
    end

    test "issuer without scheme falls back gracefully (no malformed entry)" do
      Application.put_env(:engram, :clerk_issuer, "clerk.engram.page")

      header = CSP.header()

      # Either the host is added (if the impl tolerates schemeless input)
      # or it's dropped — both are valid; what matters is no malformed
      # `https://nil` or stray-token leak into the directive.
      refute header =~ "https://nil"
      refute header =~ ~r/script-src[^;]*\s;/
    end
  end

  describe "directive shape" do
    test "header is a single line with directives separated by `; `" do
      header = CSP.header()

      refute header =~ "\n"
      assert header =~ "; "
    end

    test "no directive contains duplicate hosts" do
      Application.put_env(:engram, :clerk_issuer, "https://clerk.engram.page")

      for directive <- String.split(CSP.header(), "; ", trim: true) do
        tokens = String.split(directive, " ", trim: true)

        assert tokens == Enum.uniq(tokens),
               "duplicate token in directive: #{inspect(directive)}"
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp script_src(header), do: directive(header, "script-src")
  defp connect_src(header), do: directive(header, "connect-src")
  defp frame_src(header), do: directive(header, "frame-src")

  defp directive(header, name) do
    header
    |> String.split("; ", trim: true)
    |> Enum.find(fn d -> String.starts_with?(d, name <> " ") end)
    |> Kernel.||("")
  end
end
