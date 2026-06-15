defmodule Engram.Connections.LogoAllowlistTest do
  use ExUnit.Case, async: true
  alias Engram.Connections.LogoAllowlist

  test "known software_id returns verified entry" do
    result = LogoAllowlist.lookup("engram-vault-sync")
    assert %{verified: true, logo: "/assets/clients/engram-vault-sync.svg"} = result
  end

  test "unknown software_id returns unverified placeholder" do
    assert %{verified: false, logo: nil} = LogoAllowlist.lookup("unknown-thing")
  end

  test "nil software_id returns unverified placeholder" do
    assert %{verified: false, logo: nil} = LogoAllowlist.lookup(nil)
  end

  test "resolve matches verified Claude by claude.ai redirect host" do
    result = LogoAllowlist.resolve(nil, ["https://claude.ai/api/mcp/auth_callback"])

    assert %{
             verified: true,
             slug: "claude",
             display_name: "Claude",
             logo: "/assets/clients/claude.svg"
           } = result
  end

  test "resolve prefers software_id over redirect host" do
    result = LogoAllowlist.resolve("engram-vault-sync", ["https://claude.ai/x"])
    assert %{verified: true, slug: nil, logo: "/assets/clients/engram-vault-sync.svg"} = result
  end

  test "resolve ignores loopback and custom-scheme redirects" do
    assert %{verified: false, logo: nil, slug: nil} =
             LogoAllowlist.resolve(nil, ["http://127.0.0.1:51234/cb"])

    assert %{verified: false, slug: nil} = LogoAllowlist.resolve(nil, ["cursor://anyscheme"])
  end

  test "resolve handles nil/empty redirect list" do
    assert %{verified: false, slug: nil} = LogoAllowlist.resolve(nil, nil)
    assert %{verified: false, slug: nil} = LogoAllowlist.resolve(nil, [])
  end

  test "lookup result carries slug key" do
    assert %{slug: nil} = LogoAllowlist.lookup("engram-vault-sync")
  end
end
