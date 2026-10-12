defmodule EngramWeb.McpSendFeedbackTest do
  # Not async: points the global PostHog config at a Bypass.
  use EngramWeb.ConnCase, async: false

  alias Engram.MCP.Tools

  setup %{conn: conn} do
    prior_key = Application.get_env(:engram, :posthog_key)
    prior_host = Application.get_env(:engram, :posthog_host)

    on_exit(fn ->
      Application.put_env(:engram, :posthog_key, prior_key)
      Application.put_env(:engram, :posthog_host, prior_host)
    end)

    bypass = Bypass.open()
    parent = self()

    Bypass.stub(bypass, "POST", "/capture/", fn c ->
      {:ok, body, c} = Plug.Conn.read_body(c)
      send(parent, {:posthog, Jason.decode!(body)})
      Plug.Conn.resp(c, 200, "1")
    end)

    Application.put_env(:engram, :posthog_key, "phc_test_token")
    Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")

    user = insert(:user)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key}")
      |> put_req_header("user-agent", "claude-code/2.1")

    {:ok, conn: conn, user: user}
  end

  test "is listed account-wide (no vault_id), and neither read-only nor destructive" do
    {:ok, tool} = Tools.get("send_feedback")
    assert tool in Tools.list()
    refute Map.has_key?(tool.inputSchema["properties"], "vault_id")
    assert tool.annotations["readOnlyHint"] == false
    assert tool.annotations["destructiveHint"] == false
    assert "message" in tool.inputSchema["required"]
    assert "initiated_by" in tool.inputSchema["required"]
  end

  test "the description forbids note content" do
    {:ok, tool} = Tools.get("send_feedback")
    assert tool.description =~ "Never include note content"
  end

  test "sends user_feedback tagged as MCP with the request's user agent", %{conn: conn} do
    conn =
      call_tool(conn, "send_feedback", %{
        "message" => "search missed a note I know exists",
        "category" => "bug",
        "initiated_by" => "model",
        "tool_name" => "search_notes"
      })

    body = json_response(conn, 200)
    refute body["result"]["isError"]
    assert body["result"]["structuredContent"] == %{"status" => "sent"}

    assert_receive {:posthog, %{"event" => "user_feedback", "properties" => props}}, 1_000

    assert %{
             "message" => "search missed a note I know exists",
             "category" => "bug",
             "source" => "mcp",
             "initiated_by" => "model",
             "tool_name" => "search_notes",
             "user_agent" => "claude-code/2.1"
           } = props
  end

  test "accepts missing_capability", %{conn: conn} do
    conn =
      call_tool(conn, "send_feedback", %{
        "message" => "cannot list recently edited notes",
        "category" => "missing_capability",
        "initiated_by" => "user"
      })

    refute json_response(conn, 200)["result"]["isError"]
    assert_receive {:posthog, %{"properties" => %{"category" => "missing_capability"}}}, 1_000
  end

  test "a blank message or unknown category is a tool error the model can fix",
       %{conn: conn} do
    for args <- [
          %{"message" => "   ", "initiated_by" => "user"},
          %{"message" => "hi", "initiated_by" => "user", "category" => "rant"},
          %{"message" => "hi", "initiated_by" => "nobody"}
        ] do
      assert json_response(call_tool(conn, "send_feedback", args), 200)["result"]["isError"] ==
               true,
             inspect(args)
    end

    refute_receive {:posthog, %{"event" => "user_feedback"}}, 200
  end
end
