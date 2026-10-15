defmodule EngramWeb.RequestMetaTest do
  use ExUnit.Case, async: true

  alias EngramWeb.RequestMeta

  defp conn_with_ua(ua),
    do: Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("user-agent", ua)

  describe "log_user_agent/1" do
    test "keeps a real user agent whole" do
      assert RequestMeta.log_user_agent(conn_with_ua("Claude-User/1.0")) == "Claude-User/1.0"
    end

    # Attacker-controlled and up to Bandit's 10 KB header cap: bounded before
    # it reaches a log line.
    test "bounds an oversized one to 200 characters" do
      assert RequestMeta.log_user_agent(conn_with_ua(String.duplicate("a", 5_000))) ==
               String.duplicate("a", 200)
    end

    # String.slice/3 counts graphemes, and one grapheme can carry thousands of
    # combining marks: 200 graphemes is not a byte bound.
    test "bounds bytes, not graphemes, and stays valid UTF-8" do
      ua = "a" <> String.duplicate("\u0301", 5_000)
      logged = RequestMeta.log_user_agent(conn_with_ua(ua))

      assert byte_size(logged) <= 200
      assert String.valid?(logged)
    end

    test "is nil without the header" do
      assert RequestMeta.log_user_agent(Plug.Test.conn(:get, "/")) == nil
    end
  end
end
