defmodule Engram.Http.SsrfGuardTest do
  use ExUnit.Case, async: true

  alias Engram.Http.SsrfGuard

  # Every test here uses either an IP literal or `localhost`, never a real
  # hostname: this suite must not depend on the network. `localhost` is
  # hosts-file resolved, so the hostname path is still covered deterministically.

  describe "resolve/1 URL shape" do
    test "rejects a non-https scheme" do
      assert {:error, :not_https} = SsrfGuard.resolve("http://93.184.216.34/doc.json")
      assert {:error, :not_https} = SsrfGuard.resolve("ftp://93.184.216.34/doc.json")
      assert {:error, :not_https} = SsrfGuard.resolve("file:///etc/passwd")
    end

    # `https:///x` and `https:x` parse with scheme "https" and a nil/empty host.
    # The same shape slipped past a redirect-URI check in PR #1147; a host-less
    # URL must never reach DNS resolution.
    test "rejects https with no host" do
      assert {:error, :missing_host} = SsrfGuard.resolve("https:///doc.json")
      assert {:error, :missing_host} = SsrfGuard.resolve("https://")
      assert {:error, :missing_host} = SsrfGuard.resolve("https:doc.json")
    end

    # `https://claude.ai@169.254.169.254/` has host 169.254.169.254 and userinfo
    # "claude.ai". A human reading the client_id sees claude.ai. Reject rather
    # than rely on every future reader parsing it correctly.
    test "rejects userinfo" do
      assert {:error, :userinfo_present} = SsrfGuard.resolve("https://user@93.184.216.34/d.json")

      assert {:error, :userinfo_present} =
               SsrfGuard.resolve("https://claude.ai@93.184.216.34/d.json")
    end

    # A fragment is never sent to the server, so a client_id that differs only by
    # its fragment would fetch the same document while claiming to be a distinct
    # client. Refuse the ambiguity.
    test "rejects a fragment" do
      assert {:error, :fragment_present} = SsrfGuard.resolve("https://93.184.216.34/d.json#frag")
    end

    test "rejects a non-443 port" do
      assert {:error, :unsupported_port} = SsrfGuard.resolve("https://93.184.216.34:8443/d.json")
      assert {:error, :unsupported_port} = SsrfGuard.resolve("https://93.184.216.34:22/d.json")
    end

    test "rejects a non-binary or over-long URL" do
      assert {:error, :invalid_url} = SsrfGuard.resolve(nil)
      assert {:error, :invalid_url} = SsrfGuard.resolve(:not_a_url)
      long = "https://93.184.216.34/" <> String.duplicate("a", 2048)
      assert {:error, :url_too_long} = SsrfGuard.resolve(long)
    end

    test "accepts a public https URL and pins it to the resolved address" do
      assert {:ok, target} = SsrfGuard.resolve("https://93.184.216.34/.well-known/doc.json")
      assert target.host == "93.184.216.34"
      assert target.ip == {93, 184, 216, 34}
      assert target.url == "https://93.184.216.34/.well-known/doc.json"
    end

    test "preserves path and query in the pinned URL" do
      assert {:ok, %{url: url}} = SsrfGuard.resolve("https://93.184.216.34/a/b?x=1&y=2")
      assert url == "https://93.184.216.34/a/b?x=1&y=2"
    end

    # The pinned URL is what gets fetched, so an IPv6 target must come back
    # bracketed or the fetch builds a malformed URL.
    test "brackets an IPv6 literal in the pinned URL" do
      assert {:ok, target} = SsrfGuard.resolve("https://[2606:2800:220:1::]/d.json")
      assert target.url == "https://[2606:2800:220:1::]/d.json"
      assert target.host == "2606:2800:220:1::"
    end
  end

  describe "resolve/1 address filtering" do
    test "rejects loopback, link-local, private and CGNAT literals" do
      for host <- [
            "127.0.0.1",
            "127.1.2.3",
            "169.254.169.254",
            "10.1.2.3",
            "172.16.5.5",
            "192.168.1.1",
            "100.64.0.1",
            "0.0.0.0"
          ] do
        assert {:error, :private_address} = SsrfGuard.resolve("https://#{host}/d.json"),
               "#{host} must be rejected"
      end
    end

    test "rejects IPv6 loopback, ULA, link-local and IPv4-mapped private literals" do
      for host <- ["[::1]", "[fc00::1]", "[fe80::1]", "[::ffff:127.0.0.1]", "[::ffff:10.0.0.1]"] do
        assert {:error, :private_address} = SsrfGuard.resolve("https://#{host}/d.json"),
               "#{host} must be rejected"
      end
    end

    # `localhost` exercises the DNS path (not the literal path) and must be
    # rejected on the resolved address, not on its name.
    test "rejects a hostname that resolves to loopback" do
      assert {:error, :private_address} = SsrfGuard.resolve("https://localhost/d.json")
    end

    test "reports dns_failure for a name that does not resolve" do
      assert {:error, :dns_failure} =
               SsrfGuard.resolve("https://this-host-does-not-exist.invalid/d.json")
    end
  end

  describe "public_address?/1" do
    test "accepts ordinary public addresses" do
      assert SsrfGuard.public_address?({93, 184, 216, 34})
      assert SsrfGuard.public_address?({1, 1, 1, 1})
      assert SsrfGuard.public_address?({0x2606, 0x2800, 0x220, 1, 0, 0, 0, 0})
    end

    test "rejects every reserved IPv4 range" do
      refute SsrfGuard.public_address?({0, 0, 0, 0})
      refute SsrfGuard.public_address?({10, 0, 0, 1})
      refute SsrfGuard.public_address?({100, 64, 0, 1})
      refute SsrfGuard.public_address?({127, 0, 0, 1})
      refute SsrfGuard.public_address?({169, 254, 169, 254})
      refute SsrfGuard.public_address?({172, 31, 255, 255})
      refute SsrfGuard.public_address?({192, 0, 0, 1})
      refute SsrfGuard.public_address?({192, 0, 2, 1})
      refute SsrfGuard.public_address?({192, 88, 99, 1})
      refute SsrfGuard.public_address?({192, 168, 0, 1})
      refute SsrfGuard.public_address?({198, 19, 0, 1})
      refute SsrfGuard.public_address?({198, 51, 100, 1})
      refute SsrfGuard.public_address?({203, 0, 113, 1})
      refute SsrfGuard.public_address?({224, 0, 0, 1})
      refute SsrfGuard.public_address?({255, 255, 255, 255})
    end

    # 172.16.0.0/12 is 172.16 through 172.31 — 172.32 is public. A /12 mask
    # implemented as a /16 comparison would wrongly reject it, and one
    # implemented as a byte prefix would wrongly accept 172.15.
    test "gets the 172.16/12 boundary exactly right" do
      refute SsrfGuard.public_address?({172, 16, 0, 0})
      refute SsrfGuard.public_address?({172, 31, 255, 255})
      assert SsrfGuard.public_address?({172, 15, 255, 255})
      assert SsrfGuard.public_address?({172, 32, 0, 0})
    end

    test "gets the 100.64/10 CGNAT boundary exactly right" do
      refute SsrfGuard.public_address?({100, 64, 0, 0})
      refute SsrfGuard.public_address?({100, 127, 255, 255})
      assert SsrfGuard.public_address?({100, 63, 255, 255})
      assert SsrfGuard.public_address?({100, 128, 0, 0})
    end

    test "rejects reserved IPv6 ranges" do
      refute SsrfGuard.public_address?({0, 0, 0, 0, 0, 0, 0, 0})
      refute SsrfGuard.public_address?({0, 0, 0, 0, 0, 0, 0, 1})
      refute SsrfGuard.public_address?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      refute SsrfGuard.public_address?({0xFD00, 0, 0, 0, 0, 0, 0, 1})
      refute SsrfGuard.public_address?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      refute SsrfGuard.public_address?({0xFF02, 0, 0, 0, 0, 0, 0, 1})
      refute SsrfGuard.public_address?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      refute SsrfGuard.public_address?({0x64, 0xFF9B, 0, 0, 0, 0, 0, 1})
      refute SsrfGuard.public_address?({0x100, 0, 0, 0, 0, 0, 0, 1})
    end

    # 6to4 and Teredo embed an IPv4 address that a relay will forward to, so a
    # public-looking v6 address can reach a private v4 host.
    test "rejects v4-embedding transition ranges" do
      refute SsrfGuard.public_address?({0x2002, 0xC0A8, 0x0001, 0, 0, 0, 0, 1})
      refute SsrfGuard.public_address?({0x2001, 0, 0, 0, 0, 0, 0, 1})
    end

    # ::ffff:a.b.c.d must be unwrapped and judged as the IPv4 address it is,
    # otherwise ::ffff:169.254.169.254 reads as an ordinary public v6 address.
    test "unwraps IPv4-mapped IPv6 and judges the inner address" do
      refute SsrfGuard.public_address?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
      refute SsrfGuard.public_address?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
      assert SsrfGuard.public_address?({0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD822})
    end

    test "rejects anything that is not an IP tuple" do
      refute SsrfGuard.public_address?("127.0.0.1")
      refute SsrfGuard.public_address?(nil)
      refute SsrfGuard.public_address?({1, 2, 3})
    end
  end
end
