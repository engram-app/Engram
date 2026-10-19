defmodule EngramWeb.AttachmentsRefusalTelemetryTest do
  @moduledoc """
  Every refused attachment upload is attributable from telemetry alone: the
  plan, the reason the body names, the declared size, raw vs JSON, and the
  plugin version, on the request span and on the request's one log line.

  The 2026-10-19 bulk-upload incident (250x 402, 49x 415, 47x 413 from one
  device) could not be triaged because none of these were recorded.
  """
  # async: false — the OTel pid exporter is global, and the attachment storage
  # adapter is swapped by other async: false files.
  use EngramWeb.ConnCase, async: false

  alias Engram.Test.LogCapture

  require OpenTelemetry.Tracer
  require Record
  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  @plugin_version "1.40.0"

  setup %{conn: conn} do
    :application.set_env(:opentelemetry, :traces_exporter, {:otel_exporter_pid, self()})
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    # request_logger_test.exs detaches the handler on exit; re-attach so this
    # file does not depend on run order. Idempotent.
    EngramWeb.RequestLogger.attach()

    user = insert(:user)
    insert(:subscription, user: user, tier: "pro", status: "active")
    insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key}")
      |> put_req_header("x-plugin-version", @plugin_version)

    %{conn: conn, user: user}
  end

  # ConnTest sends no content-length; Bandit always has one (or chunking).
  defp raw_post(conn, query, body) do
    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> put_req_header("content-length", Integer.to_string(byte_size(body)))
    |> post("/api/attachments?" <> URI.encode_query(query), body)
  end

  # Runs the request inside a test span (ConnTest has no Bandit request span)
  # and returns {conn, span attributes, request log metadata}.
  defp observe(fun) do
    {conn, events} =
      LogCapture.with_events(fn ->
        OpenTelemetry.Tracer.with_span "test.request" do
          fun.()
        end
      end)

    assert_receive {:span, span(name: "test.request", attributes: attrs)}, 2_000
    {conn, :otel_attributes.map(attrs), request_meta(events)}
  end

  defp request_meta(events) do
    Enum.find_value(events, fn
      %{msg: {:string, s}, meta: meta} ->
        if IO.iodata_to_binary(s) =~ ~r/^[A-Z]+ \d+ in \d+ms$/, do: meta

      _ ->
        nil
    end)
  end

  test "a raw 402 carries plan, reason, declared size, body kind and plugin version", %{
    conn: conn,
    user: user
  } do
    insert(:user_limit_override,
      user: user,
      key: "attachments_all_types",
      value: %{"v" => false},
      reason: "revoke for test",
      set_by: "test"
    )

    {conn, attrs, meta} = observe(fn -> raw_post(conn, %{path: "a.png", mtime: "1"}, "12345") end)

    assert json_response(conn, 402)["reason"] == "attachment_must_be_text"

    assert attrs["engram.plan"] == "pro"
    assert attrs["engram.attachment.reject_reason"] == "attachment_must_be_text"
    assert attrs["engram.attachment.declared_bytes"] == 5
    assert attrs["engram.attachment.body_kind"] == "raw"
    assert attrs["engram.plugin_version"] == @plugin_version

    assert meta, "expected the request log line"
    assert meta.reason == "attachment_must_be_text"
    assert meta.plan == "pro"
    assert meta.declared_bytes == 5
    assert meta.body_kind == "raw"
    assert meta.plugin_version == @plugin_version
  end

  test "a JSON quota 402 names the quota reason and body kind json", %{conn: conn, user: user} do
    insert(:user_limit_override, user: user, key: "attachment_bytes_cap", value: %{"v" => 10})

    {conn, attrs, meta} =
      observe(fn ->
        body =
          Jason.encode!(%{
            path: "big.png",
            content_base64: Base.encode64(:binary.copy("a", 11)),
            mtime: 1.0
          })

        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-length", Integer.to_string(byte_size(body)))
        |> post("/api/attachments", body)
      end)

    assert json_response(conn, 402)["reason"] == "attachments_quota_exceeded"
    assert attrs["engram.attachment.reject_reason"] == "attachments_quota_exceeded"
    assert attrs["engram.attachment.body_kind"] == "json"
    assert attrs["engram.attachment.declared_bytes"] > 11
    assert meta.reason == "attachments_quota_exceeded"
    assert meta.body_kind == "json"
  end

  test "a 415 carries the error string from its body", %{conn: conn} do
    {conn, attrs, meta} = observe(fn -> raw_post(conn, %{path: "evil.exe"}, "MZ") end)

    assert json_response(conn, 415)["error"] == "mime_not_allowed"
    assert attrs["engram.attachment.reject_reason"] == "mime_not_allowed"
    assert meta.reason == "mime_not_allowed"
    assert meta.plan == "pro"
  end

  test "a 422 carries the error string from its body", %{conn: conn} do
    {conn, attrs, _meta} = observe(fn -> raw_post(conn, %{mtime: "1"}, "x") end)

    assert json_response(conn, 422)["error"] == "path is required"
    assert attrs["engram.attachment.reject_reason"] == "path is required"
  end

  test "an unparseable plugin version is not echoed", %{conn: conn} do
    conn = put_req_header(conn, "x-plugin-version", String.duplicate("x", 500))

    {conn, attrs, meta} = observe(fn -> raw_post(conn, %{path: "evil.exe"}, "MZ") end)

    assert json_response(conn, 415)
    assert attrs["engram.plugin_version"] == "unparsed"
    assert meta.plugin_version == "unparsed"
  end

  test "a successful upload is not tagged as a refusal", %{conn: conn} do
    {conn, attrs, meta} = observe(fn -> raw_post(conn, %{path: "ok.png", mtime: "1"}, "x") end)

    assert json_response(conn, 200)
    refute Map.has_key?(attrs, "engram.attachment.reject_reason")
    refute Map.has_key?(attrs, "engram.plan")
    # A 2xx request line is info, under the suite's :warning level.
    refute meta[:reason]
  end
end
