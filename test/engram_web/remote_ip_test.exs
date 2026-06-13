defmodule EngramWeb.RemoteIpTest do
  use ExUnit.Case, async: false

  alias EngramWeb.RemoteIp

  # remote_ip is set on a bare Plug.Conn; no HTTP needed.
  defp conn(remote_ip, headers \\ []) do
    %Plug.Conn{remote_ip: remote_ip, req_headers: headers}
  end

  defp with_trust(value, fun) do
    prev = Application.get_env(:engram, :trust_cf_connecting_ip)
    Application.put_env(:engram, :trust_cf_connecting_ip, value)

    try do
      fun.()
    after
      Application.put_env(:engram, :trust_cf_connecting_ip, prev)
    end
  end

  describe "resolve/1 with trust disabled (default-deny)" do
    test "returns the raw socket IP and ignores CF-Connecting-IP" do
      with_trust(false, fn ->
        c = conn({10, 30, 1, 5}, [{"cf-connecting-ip", "203.0.113.7"}])
        assert RemoteIp.resolve(c) == {10, 30, 1, 5}
      end)
    end
  end

  describe "resolve/1 with trust enabled" do
    test "returns the CF-Connecting-IP when it is a valid address" do
      with_trust(true, fn ->
        c = conn({10, 30, 1, 5}, [{"cf-connecting-ip", "203.0.113.7"}])
        assert RemoteIp.resolve(c) == {203, 0, 113, 7}
      end)
    end

    test "parses an IPv6 CF-Connecting-IP" do
      with_trust(true, fn ->
        c = conn({10, 30, 1, 5}, [{"cf-connecting-ip", "2001:db8::1"}])
        assert RemoteIp.resolve(c) == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      end)
    end

    test "falls back to the socket IP when the header is absent" do
      with_trust(true, fn ->
        assert RemoteIp.resolve(conn({10, 30, 1, 5})) == {10, 30, 1, 5}
      end)
    end

    test "falls back to the socket IP when the header is not a valid IP" do
      with_trust(true, fn ->
        c = conn({10, 30, 1, 5}, [{"cf-connecting-ip", "not-an-ip"}])
        assert RemoteIp.resolve(c) == {10, 30, 1, 5}
      end)
    end

    test "ignores a spoofed-looking empty header value" do
      with_trust(true, fn ->
        c = conn({10, 30, 1, 5}, [{"cf-connecting-ip", ""}])
        assert RemoteIp.resolve(c) == {10, 30, 1, 5}
      end)
    end
  end
end
