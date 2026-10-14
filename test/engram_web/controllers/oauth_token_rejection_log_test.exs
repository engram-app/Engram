defmodule EngramWeb.OAuthTokenRejectionLogTest do
  @moduledoc """
  Every `/oauth/token` rejection leaves one structured `oauth_token_rejected`
  line naming WHY, plus a low-cardinality telemetry event (#1974).

  Before this, `invalid_grant`, `invalid_request` and `unsupported_grant_type`
  were returned with no line at all, so a connector whose refresh kept failing
  (the 2026-10-12 churn) was invisible until the user gave up.

  Events and log lines are filtered to the test process: both the logger
  handler and the telemetry handler are global, and this file is async.
  """
  use EngramWeb.ConnCase, async: true

  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]
  import ExUnit.CaptureLog

  alias Engram.OAuth
  alias Engram.Repo
  alias Engram.Test.LogCapture

  @event [:engram, :oauth, :token]
  @message "oauth_token_rejected"
  @redirect "https://claude.ai/api/mcp/auth_callback"

  setup do
    test_pid = self()
    handler = "oauth-token-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      @event,
      fn _e, _m, meta, _ ->
        if self() == test_pid, do: send(test_pid, {:oauth_token, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp register_client do
    {:ok, client} =
      OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "Claude"})

    client
  end

  defp mint_code(client, challenge) do
    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp"
      })

    {:ok, url} = OAuth.mint_authorization_code(insert(:user), validated, :all, nil)
    code_from_redirect(url)
  end

  defp code_params(client) do
    {verifier, challenge} = pkce_pair()

    %{
      "grant_type" => "authorization_code",
      "code" => mint_code(client, challenge),
      "redirect_uri" => @redirect,
      "client_id" => client.client_id,
      "code_verifier" => verifier
    }
  end

  defp refresh_token_for(client) do
    %{"refresh_token" => rt} =
      json_response(post(build_conn(), "/oauth/token", code_params(client)), 200)

    # Drain the issued event so a later assert_received sees only the rejection.
    assert_received {:oauth_token, %{result: :issued}}
    rt
  end

  # Posts, asserts the status + OAuth error, and returns this process's single
  # rejection log event.
  defp reject(params, status, error, conn \\ build_conn()) do
    {_, events} =
      LogCapture.with_events(fn ->
        assert %{"error" => ^error} = json_response(post(conn, "/oauth/token", params), status)
      end)

    me = self()

    assert [event] =
             Enum.filter(events, &(&1.msg == {:string, @message} and &1.meta[:pid] == me)),
           "expected exactly one #{@message} line, got: #{inspect(Enum.map(events, & &1.msg))}"

    event.meta
  end

  defp assert_rejected(meta, grant_type, error, reason) do
    assert meta[:grant_type] == Atom.to_string(grant_type)
    assert meta[:error_code] == error
    assert meta[:reason] == inspect(reason)

    assert_received {:oauth_token,
                     %{grant_type: ^grant_type, result: :rejected, error: ^error, reason: ^reason}}
  end

  describe "request-shape rejections" do
    test "unsupported grant_type" do
      meta = reject(%{"grant_type" => "password"}, 400, "unsupported_grant_type")
      assert_rejected(meta, :other, "unsupported_grant_type", :unsupported_grant_type)
    end

    test "missing grant_type" do
      meta = reject(%{}, 400, "invalid_request")
      assert_rejected(meta, :missing, "invalid_request", :grant_type_missing)
    end

    test "refresh grant without a refresh_token" do
      client = register_client()

      meta =
        reject(
          %{"grant_type" => "refresh_token", "client_id" => client.client_id},
          400,
          "invalid_request"
        )

      assert_rejected(meta, :refresh_token, "invalid_request", :refresh_token_missing)
    end
  end

  describe "authorization_code rejections" do
    test "unknown code" do
      params = %{code_params(register_client()) | "code" => "engram_ac_doesnotexist"}
      meta = reject(params, 400, "invalid_grant")
      assert_rejected(meta, :authorization_code, "invalid_grant", :code_unknown)
    end

    test "missing code" do
      params = Map.delete(code_params(register_client()), "code")
      meta = reject(params, 400, "invalid_grant")
      assert_rejected(meta, :authorization_code, "invalid_grant", :code_missing)
    end

    test "expired code" do
      params = code_params(register_client())
      {:ok, row} = OAuth.get_authorization_code_by_raw(params["code"])
      past = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
      row |> Ecto.Changeset.change(expires_at: past) |> Repo.update!(skip_tenant_check: true)

      meta = reject(params, 400, "invalid_grant")
      assert_rejected(meta, :authorization_code, "invalid_grant", :code_expired)
    end

    test "already-consumed code" do
      params = code_params(register_client())
      json_response(post(build_conn(), "/oauth/token", params), 200)
      assert_received {:oauth_token, %{result: :issued}}

      meta = reject(params, 400, "invalid_grant")
      assert_rejected(meta, :authorization_code, "invalid_grant", :code_consumed)
    end

    test "PKCE verifier mismatch" do
      params = %{code_params(register_client()) | "code_verifier" => "not-the-verifier"}
      meta = reject(params, 400, "invalid_grant")
      assert_rejected(meta, :authorization_code, "invalid_grant", :pkce_mismatch)
    end

    test "PKCE verifier missing" do
      params = Map.delete(code_params(register_client()), "code_verifier")
      meta = reject(params, 400, "invalid_grant")
      assert_rejected(meta, :authorization_code, "invalid_grant", :pkce_verifier_missing)
    end

    test "redirect_uri mismatch" do
      params = %{code_params(register_client()) | "redirect_uri" => "https://elsewhere/cb"}
      meta = reject(params, 400, "invalid_grant")
      assert_rejected(meta, :authorization_code, "invalid_grant", :redirect_uri_mismatch)
    end

    test "code issued to a different client" do
      params = %{code_params(register_client()) | "client_id" => register_client().client_id}
      meta = reject(params, 400, "invalid_grant")
      assert_rejected(meta, :authorization_code, "invalid_grant", :client_mismatch)
    end
  end

  describe "refresh_token rejections" do
    test "unknown refresh token" do
      client = register_client()

      meta =
        reject(
          %{
            "grant_type" => "refresh_token",
            "refresh_token" => "engram_oauth_rt_nope",
            "client_id" => client.client_id
          },
          400,
          "invalid_grant"
        )

      assert_rejected(meta, :refresh_token, "invalid_grant", :refresh_token_unknown)
    end

    test "reused (already rotated) refresh token" do
      client = register_client()
      rt = refresh_token_for(client)

      params = %{
        "grant_type" => "refresh_token",
        "refresh_token" => rt,
        "client_id" => client.client_id
      }

      json_response(post(build_conn(), "/oauth/token", params), 200)
      assert_received {:oauth_token, %{result: :issued}}

      meta = reject(params, 400, "invalid_grant")
      assert_rejected(meta, :refresh_token, "invalid_grant", :refresh_token_reuse)
    end

    test "revoked refresh token" do
      client = register_client()
      rt = refresh_token_for(client)
      :ok = OAuth.revoke_token(rt, client.client_id, nil)

      meta =
        reject(
          %{
            "grant_type" => "refresh_token",
            "refresh_token" => rt,
            "client_id" => client.client_id
          },
          400,
          "invalid_grant"
        )

      assert_rejected(meta, :refresh_token, "invalid_grant", :refresh_token_revoked)
    end

    test "refresh token presented by a different client" do
      rt = refresh_token_for(register_client())
      other = register_client()

      meta =
        reject(
          %{
            "grant_type" => "refresh_token",
            "refresh_token" => rt,
            "client_id" => other.client_id
          },
          400,
          "invalid_grant"
        )

      assert_rejected(meta, :refresh_token, "invalid_grant", :client_mismatch)
    end
  end

  describe "client identity and privacy" do
    test "logs the client_id and user agent of the rejected client" do
      client = register_client()
      params = %{code_params(client) | "code_verifier" => "wrong"}
      conn = put_req_header(build_conn(), "user-agent", "openai-mcp/1.0 node")

      meta = reject(params, 400, "invalid_grant", conn)

      assert meta[:client_id] == client.client_id
      assert meta[:user_agent] == "openai-mcp/1.0 node"
      assert Map.has_key?(meta, :cimd_host)
    end

    test "a non-UUID client_id is not echoed into the log" do
      meta =
        reject(
          %{"grant_type" => "password", "client_id" => "x\n<script>"},
          400,
          "unsupported_grant_type"
        )

      assert meta[:client_id] == nil
    end

    test "no code, verifier or refresh token value reaches the log output" do
      client = register_client()
      params = %{code_params(client) | "redirect_uri" => "https://elsewhere/cb"}
      rt = refresh_token_for(client)

      log =
        capture_log(fn ->
          post(build_conn(), "/oauth/token", params)

          post(build_conn(), "/oauth/token", %{
            "grant_type" => "refresh_token",
            "refresh_token" => rt,
            "client_id" => register_client().client_id
          })
        end)

      assert log =~ @message
      refute log =~ params["code"]
      refute log =~ params["code_verifier"]
      refute log =~ rt
    end
  end

  test "a successful exchange emits an issued event and no rejection line" do
    params = code_params(register_client())

    {_, events} =
      LogCapture.with_events(fn ->
        json_response(post(build_conn(), "/oauth/token", params), 200)
      end)

    me = self()
    refute Enum.any?(events, &(&1.msg == {:string, @message} and &1.meta[:pid] == me))

    assert_received {:oauth_token,
                     %{
                       grant_type: :authorization_code,
                       result: :issued,
                       error: nil,
                       reason: :none
                     }}
  end
end
