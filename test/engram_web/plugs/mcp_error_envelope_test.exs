defmodule EngramWeb.Plugs.McpErrorEnvelopeTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias EngramWeb.Plugs.McpErrorEnvelope

  # Drives the plug the way the pipeline does: register the callback on the way
  # in, then send a response and read what actually went out.
  defp send_through(status, body, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "application/json")
    raw = Keyword.get(opts, :raw, false)
    payload = if raw, do: body, else: Jason.encode!(body)

    conn(:post, "/api/mcp")
    |> Map.put(:body_params, Keyword.get(opts, :body_params, %{}))
    |> McpErrorEnvelope.call([])
    |> put_resp_content_type(content_type)
    |> resp(status, payload)
    |> send_resp()
  end

  defp decoded(conn), do: Jason.decode!(conn.resp_body)

  describe "wrapping" do
    test "wraps a refusal into a JSON-RPC error, preserving the status" do
      conn = send_through(403, %{"error" => "onboarding_required"})

      assert conn.status == 403
      assert decoded(conn)["jsonrpc"] == "2.0"
      assert decoded(conn)["error"]["code"] == -32_001
    end

    test "keeps the original body verbatim under error.data" do
      original = %{"error" => "plugin_upgrade_required", "minimum" => "1.2.0"}

      assert decoded(send_through(426, original))["error"]["data"] == original
    end

    test "prefers a message the refusing plug wrote itself" do
      conn = send_through(403, %{"error" => "onboarding_required", "message" => "Go here: /x"})

      assert decoded(conn)["error"]["message"] == "Go here: /x"
    end

    test "falls back to the error slug as a sentence" do
      conn = send_through(426, %{"error" => "plugin_upgrade_required"})

      assert decoded(conn)["error"]["message"] == "Plugin upgrade required."
    end

    test "an empty message does not win over the slug" do
      conn = send_through(402, %{"error" => "account_suspended", "message" => ""})

      assert decoded(conn)["error"]["message"] == "Account suspended."
    end

    test "a 4xx body with neither message nor error slug still yields a sentence" do
      conn = send_through(409, %{"whatever" => true})

      assert decoded(conn)["error"]["message"] == "The request was refused."
    end

    # A crash is not a verdict. This is the shape Phoenix renders an unhandled
    # 500 in, and it matches no refusal clause, so it used to be described as a
    # refusal. #1666 is what that misreading costs: hours spent retrying a rule
    # that did not exist.
    test "a 5xx with no self-describing body reads as a fault, not a refusal" do
      conn = send_through(500, %{"errors" => %{"detail" => "Internal Server Error"}})

      message = decoded(conn)["error"]["message"]

      assert conn.status == 500
      assert message =~ "internal error"
      refute message =~ "refused"
    end

    test "a 5xx is still wrapped and still carries the original body" do
      original = %{"errors" => %{"detail" => "Internal Server Error"}}
      body = decoded(send_through(500, original))

      assert body["jsonrpc"] == "2.0"
      assert body["error"]["data"] == original
    end

    # Status alone cannot tell a crash from a deliberate 5xx refusal, so a plug
    # that wrote its own sentence keeps it. `503 rotating` is the real case.
    test "a 5xx keeps a message the halting plug wrote itself" do
      conn = send_through(503, %{"error" => "rotating", "message" => "Keys are rotating."})

      assert decoded(conn)["error"]["message"] == "Keys are rotating."
    end

    test "a 5xx keeps its slug sentence rather than the generic fault text" do
      conn = send_through(503, %{"error" => "rotating"})

      assert decoded(conn)["error"]["message"] == "Rotating."
    end
  end

  describe "the JSON-RPC id" do
    test "echoes an integer id from the request body" do
      conn = send_through(403, %{"error" => "x"}, body_params: %{"id" => 99})

      assert decoded(conn)["id"] == 99
    end

    test "echoes a string id" do
      conn = send_through(403, %{"error" => "x"}, body_params: %{"id" => "abc"})

      assert decoded(conn)["id"] == "abc"
    end

    # JSON-RPC 2.0 §5: null id is the correct answer when the request's own id
    # cannot be determined. Inventing one would be worse.
    test "is null when the request carried no id" do
      conn = send_through(403, %{"error" => "x"})

      assert decoded(conn)["id"] == nil
    end

    test "is null rather than echoing a non-scalar id" do
      conn = send_through(403, %{"error" => "x"}, body_params: %{"id" => %{"not" => "scalar"}})

      assert decoded(conn)["id"] == nil
    end
  end

  describe "what it must not touch" do
    # The OAuth discovery entry point. Its bare body plus WWW-Authenticate is
    # what a spec-following client acts on.
    test "leaves a 401 alone" do
      conn = send_through(401, %{"error" => "unauthorized"})

      assert decoded(conn) == %{"error" => "unauthorized"}
    end

    test "leaves a success alone" do
      conn = send_through(200, %{"result" => %{"ok" => true}})

      assert decoded(conn) == %{"result" => %{"ok" => true}}
    end

    test "leaves McpController's own JSON-RPC error alone" do
      already = %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32_601}}

      assert decoded(send_through(400, already)) == already
    end

    test "leaves a non-JSON response alone" do
      conn = send_through(403, "<html>nope</html>", content_type: "text/html", raw: true)

      assert conn.resp_body == "<html>nope</html>"
    end

    test "leaves a body that is not valid JSON alone" do
      conn = send_through(403, "not json at all", raw: true)

      assert conn.resp_body == "not json at all"
    end

    test "leaves a JSON array alone (only objects carry our error shape)" do
      conn = send_through(403, [1, 2, 3])

      assert decoded(conn) == [1, 2, 3]
    end
  end
end
