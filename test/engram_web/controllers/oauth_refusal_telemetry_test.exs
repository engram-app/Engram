defmodule EngramWeb.OAuthRefusalTelemetryTest do
  @moduledoc """
  Every client refusal on the connect path must leave exactly one line an alert
  can match.

  `mcp-connector-refused` (engram-infra#1161) matches by MESSAGE, so a branch
  that logs nothing is unreachable by any filter — and five of them logged
  nothing: an unknown `client_id` on both the token and authorize paths, all
  three secret outcomes, and the Basic-vs-body credential conflict. That is the
  #1633 failure mode (a vendor 100% unable to connect, producing no attributable
  signal) one branch over from where it was just fixed (#1643).

  These tests assert the LINE, not the status code — the status codes were
  already covered and were never the gap.
  """
  use EngramWeb.ConnCase, async: true

  import Engram.OAuthHelpers, only: [code_from_redirect: 1]
  import ExUnit.CaptureLog

  alias Engram.OAuth
  alias Engram.Test.LogCapture

  @message "oauth_client_rejected"

  defp register_client(redirect_uri) do
    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => [redirect_uri],
        "client_name" => "Claude"
      })

    client
  end

  defp confidential_client(redirect_uri) do
    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => [redirect_uri],
        "client_name" => "LobeChat",
        "token_endpoint_auth_method" => "client_secret_post"
      })

    client
  end

  defp code_for(client, redirect_uri) do
    verifier = "verifier-that-is-long-enough-to-be-plausible"
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp"
      })

    {:ok, redirect_url} = OAuth.mint_authorization_code(insert(:user), validated, :all, nil)

    code = code_from_redirect(redirect_url)

    {code, verifier}
  end

  defp exchange(conn, params), do: post(conn, "/oauth/token", params)

  describe "POST /oauth/token refusals are attributable" do
    test "an unknown client_id logs a refusal", %{conn: conn} do
      log =
        capture_log(fn ->
          conn =
            exchange(conn, %{
              "grant_type" => "authorization_code",
              "code" => "engram_ac_nope",
              "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
              "client_id" => Ecto.UUID.generate(),
              "code_verifier" => "whatever-verifier-value-here"
            })

          assert %{"error" => "invalid_client"} = json_response(conn, 401)
        end)

      assert log =~ @message
      assert log =~ "client_unknown"
    end

    # The one refusal branch in the controller that was not routed through a
    # logged rejection, despite its neighbours' "Every branch logs" comment.
    test "credentials in both the Basic header and the body log a refusal", %{conn: conn} do
      uri = "https://app.lobehub.com/oauth/callback"
      client = confidential_client(uri)
      {code, verifier} = code_for(client, uri)
      basic = Base.encode64("#{client.client_id}:#{client.client_secret}")

      log =
        capture_log(fn ->
          conn =
            conn
            |> put_req_header("authorization", "Basic #{basic}")
            |> exchange(%{
              "grant_type" => "authorization_code",
              "code" => code,
              "redirect_uri" => uri,
              "client_id" => client.client_id,
              "client_secret" => client.client_secret,
              "code_verifier" => verifier
            })

          assert %{"error" => "invalid_client"} = json_response(conn, 401)
        end)

      assert log =~ @message
      assert log =~ "basic_and_body_credential_conflict"
    end

    test "a wrong secret logs a refusal", %{conn: conn} do
      uri = "https://app.lobehub.com/oauth/callback"
      client = confidential_client(uri)
      {code, verifier} = code_for(client, uri)

      log =
        capture_log(fn ->
          conn =
            exchange(conn, %{
              "grant_type" => "authorization_code",
              "code" => code,
              "redirect_uri" => uri,
              "client_id" => client.client_id,
              "client_secret" => "not-the-secret",
              "code_verifier" => verifier
            })

          assert %{"error" => "invalid_client"} = json_response(conn, 401)
        end)

      assert log =~ @message
      assert log =~ "secret_mismatch"
    end

    test "a confidential client that omits its secret logs a refusal", %{conn: conn} do
      uri = "https://app.lobehub.com/oauth/callback"
      client = confidential_client(uri)
      {code, verifier} = code_for(client, uri)

      log =
        capture_log(fn ->
          conn =
            exchange(conn, %{
              "grant_type" => "authorization_code",
              "code" => code,
              "redirect_uri" => uri,
              "client_id" => client.client_id,
              "code_verifier" => verifier
            })

          assert %{"error" => "invalid_client"} = json_response(conn, 401)
        end)

      assert log =~ @message
      assert log =~ "secret_missing"
    end

    test "a secret from a client registered public logs a refusal", %{conn: conn} do
      uri = "https://claude.ai/api/mcp/auth_callback"
      client = register_client(uri)
      {code, verifier} = code_for(client, uri)

      log =
        capture_log(fn ->
          conn =
            exchange(conn, %{
              "grant_type" => "authorization_code",
              "code" => code,
              "redirect_uri" => uri,
              "client_id" => client.client_id,
              "client_secret" => "unexpected",
              "code_verifier" => verifier
            })

          assert %{"error" => "invalid_client"} = json_response(conn, 401)
        end)

      assert log =~ @message
      assert log =~ "secret_presented_by_public_client"
    end

    # This branch carried NO `cimd_host` key, so a host-faceted alert or
    # dashboard dropped every malformed-assertion refusal without a trace. It
    # emits through `OAuth.log_refusal/3` now, like every sibling.
    #
    # Asserted through LogCapture rather than capture_log: `cimd_host` is not in
    # the formatter's metadata allowlist (config/config.exs), so formatter output
    # cannot see it. The structured event is what ships to Loki.
    test "a malformed assertion names the vendor host", %{conn: conn} do
      {_result, events} =
        LogCapture.with_events(fn ->
          conn =
            exchange(conn, %{
              "grant_type" => "authorization_code",
              "code" => "engram_ac_nope",
              "redirect_uri" => "https://chatgpt.com/connector_platform_oauth_redirect",
              "client_id" => "https://chatgpt.com/oauth/client.json",
              "client_assertion" => "not.a.jwt",
              "client_assertion_type" =>
                "urn:ietf:params:oauth:client-assertion-type:saml2-bearer",
              "code_verifier" => "whatever-verifier-value-here"
            })

          assert %{"error" => "invalid_client"} = json_response(conn, 401)
        end)

      event =
        Enum.find(events, &match?({:string, "oauth_client_assertion_malformed"}, &1.msg))

      assert event, "expected a malformed-assertion refusal event, got: #{inspect(events)}"
      assert event.meta[:cimd_host] == "chatgpt.com"
      assert event.meta[:reason] == ":client_assertion_type_unrecognised"
    end
  end

  describe "GET /oauth/authorize refusals are attributable" do
    defp authorize_params(client_id) do
      %{
        "client_id" => client_id,
        "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
        "response_type" => "code",
        "code_challenge" => "abc123challenge",
        "code_challenge_method" => "S256",
        "scope" => "mcp"
      }
    end

    test "an unknown client_id logs a refusal", %{conn: conn} do
      log =
        capture_log(fn ->
          conn = get(conn, "/oauth/authorize", authorize_params(Ecto.UUID.generate()))
          assert conn.status == 400
        end)

      assert log =~ @message
      assert log =~ "client_unknown"
    end

    test "a missing client_id logs a refusal", %{conn: conn} do
      log =
        capture_log(fn ->
          conn =
            get(conn, "/oauth/authorize", Map.delete(authorize_params(nil), "client_id"))

          assert conn.status == 400
        end)

      assert log =~ @message
      assert log =~ "client_id_missing"
    end
  end

  # Asserted on the structured event, because the metadata IS the diagnosis and
  # the formatter's allowlist is not what ships to Loki.
  describe "a refusal line keeps the detail that identifies the failure" do
    # `Metadata.safe_reason/1`'s generic tuple clause returns only the tag, so
    # routing CIMD refusals through it made a vendor serving 404 (wrong path),
    # 403 (blocked) and 503 (down) for its document indistinguishable — in the
    # telemetry built to tell them apart.
    test "an HTTP status on a document fetch is rendered, not flattened to its tag" do
      {_result, events} =
        LogCapture.with_events(fn ->
          OAuth.log_refusal(
            "mcp_cimd_rejected",
            "https://chatgpt.com/oauth/client.json",
            {:http_status, 404}
          )
        end)

      event = Enum.find(events, &match?({:string, "mcp_cimd_rejected"}, &1.msg))

      assert event, "expected a document-refusal event, got: #{inspect(events)}"
      assert event.meta[:reason] == "http_status 404"
      assert event.meta[:cimd_host] == "chatgpt.com"
    end

    # A DCR client_id is an opaque UUID with no host. The field must still carry
    # a string: one emitter used to write `nil` here while its siblings wrote
    # "unknown", giving the alert two shapes for the field it facets on.
    test "a subject with no host renders \"unknown\", never nil" do
      {_result, events} =
        LogCapture.with_events(fn ->
          OAuth.log_refusal("oauth_client_rejected", Ecto.UUID.generate(), :client_unknown)
        end)

      event = Enum.find(events, &match?({:string, "oauth_client_rejected"}, &1.msg))

      assert event, "expected a client-refusal event, got: #{inspect(events)}"
      assert event.meta[:cimd_host] == "unknown"
    end
  end
end
