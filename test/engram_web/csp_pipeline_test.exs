defmodule EngramWeb.CSPPipelineTest do
  @moduledoc """
  Confirms the `:spa` pipeline actually wires `EngramWeb.CSP` — guards
  against the regression where `CSP.header/0` is correct but the plug
  was dropped from `pipeline :spa`. The unit tests in `csp_test.exs`
  prove the builder; this test proves the wiring.
  """
  use EngramWeb.ConnCase, async: false

  setup do
    prior = Application.get_env(:engram, :clerk_issuer)
    on_exit(fn -> Application.put_env(:engram, :clerk_issuer, prior) end)
    :ok
  end

  test "GET / emits content-security-policy header containing the Clerk custom-domain host",
       %{conn: conn} do
    Application.put_env(:engram, :clerk_issuer, "https://clerk.engram.page")

    conn = get(conn, "/")

    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "https://clerk.engram.page"
    assert csp =~ "default-src 'self'"
  end

  test "GET / on the SPA pipeline still sets the static security headers",
       %{conn: conn} do
    conn = get(conn, "/")

    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  # frontend/public/_headers sets this too, but that file is Cloudflare Pages
  # metadata — it covers ONLY the uploaded bundle. This pipeline serves the
  # self-hosted SPA, which is also the ONLY deployment where password reset
  # exists (RequireLocalAuth), so `/reset-password?token=` riding the Referer
  # of every same-origin subresource is a self-host-specific leak.
  #
  # Asserting the exact value, not just presence: Phoenix's default here is
  # `strict-origin-when-cross-origin`, which passes a presence check while
  # sending the full path same-origin — the thing being fixed.
  # The :api pipelines carried `x-frame-options: DENY` next to Phoenix's DEFAULT
  # CSP, whose `frame-ancestors 'self'` supersedes it — so the whole REST
  # surface advertised DENY and applied 'self'. Same defect as the OAuth
  # pipeline, found in the same review, fixed in the same pass.
  test "the api pipeline's CSP agrees with its x-frame-options", %{conn: conn} do
    conn = get(conn, "/api/health")

    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "frame-ancestors 'none'"
    refute csp =~ "frame-ancestors 'self'"
  end

  test "GET / sets referrer-policy to origin, matching the Cloudflare bundle",
       %{conn: conn} do
    conn = get(conn, "/")

    assert get_resp_header(conn, "referrer-policy") == ["origin"]
  end
end
