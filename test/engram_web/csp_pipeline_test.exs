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
end
