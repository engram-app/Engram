defmodule EngramWeb.McpToolSpanTest do
  @moduledoc """
  "Which tool, which user" is answerable from Tempo: an MCP `tools/call`
  request span carries the tool name and the hashed `app.user_id`
  (2026-10-24 triage).
  """
  # async: false: the OTel pid exporter is global.
  use EngramWeb.ConnCase, async: false

  require OpenTelemetry.Tracer
  require Record
  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  setup do
    :application.set_env(:opentelemetry, :traces_exporter, {:otel_exporter_pid, self()})
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, _vault, _} = Engram.Vaults.register_vault(user, "V", Ecto.UUID.generate())
    {:ok, key, _} = Engram.Accounts.create_api_key(user, "k")
    lift_api_rps_cap!(user)
    %{user: user, key: key}
  end

  # ConnTest has no Bandit request span; the test span stands in for it.
  defp span_attrs(key, tool) do
    OpenTelemetry.Tracer.with_span "test.request" do
      build_conn()
      |> put_req_header("authorization", "Bearer #{key}")
      |> post("/api/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => tool, "arguments" => %{}}
      })
    end

    assert_receive {:span, span(name: "test.request", attributes: attrs)}, 2_000
    :otel_attributes.map(attrs)
  end

  test "a tools/call span carries the tool name and the hashed user id", %{user: user, key: key} do
    attrs = span_attrs(key, "list_vaults")

    assert attrs["gen_ai.tool.name"] == "list_vaults"
    assert attrs["mcp.method.name"] == "tools/call"
    assert attrs["app.user_id"] == Engram.Crypto.HMAC.hash_user_id(user.id)
  end

  test "an unknown tool name is bucketed, never echoed", %{key: key} do
    attrs = span_attrs(key, "made_up_tool_<script>")
    assert attrs["gen_ai.tool.name"] == "unknown"
  end
end
