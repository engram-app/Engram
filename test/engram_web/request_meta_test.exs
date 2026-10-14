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

    test "is nil without the header" do
      assert RequestMeta.log_user_agent(Plug.Test.conn(:get, "/")) == nil
    end
  end
end
