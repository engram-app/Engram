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
end
