defmodule Engram.OAuthConnectionCreatedTest do
  @moduledoc """
  `connection_created` on `user:{id}` fires once, when an authorization code
  becomes a live grant. A refresh rotation is the same connection, so it is
  silent.
  """
  use Engram.DataCase, async: true

  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Engram.OAuth
  alias Phoenix.Socket.Broadcast

  defp exchange_params(user) do
    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "client_name" => "Claude"
      })

    redirect_uri = hd(client.redirect_uris)
    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => "xyz",
        "scope" => "mcp offline_access"
      })

    {:ok, redirect_url} = OAuth.mint_authorization_code(user, validated, :all, nil)

    %{
      "grant_type" => "authorization_code",
      "code" => code_from_redirect(redirect_url),
      "redirect_uri" => redirect_uri,
      "client_id" => client.client_id,
      "code_verifier" => verifier
    }
  end

  test "exchanging a code broadcasts once; a refresh rotation does not" do
    user = insert(:user)
    params = exchange_params(user)
    client_id = params["client_id"]
    EngramWeb.Endpoint.subscribe("user:#{user.id}")

    assert {:ok, %{refresh_token: refresh}} = OAuth.exchange_authorization_code(params)

    assert_receive %Broadcast{event: "connection_created", payload: %{client_id: ^client_id}}
    refute_receive %Broadcast{event: "connection_created"}

    assert {:ok, _} = OAuth.rotate_refresh_token(refresh, client_id)
    refute_receive %Broadcast{event: "connection_created"}
  end

  test "a refused exchange broadcasts nothing" do
    user = insert(:user)
    params = exchange_params(user)
    EngramWeb.Endpoint.subscribe("user:#{user.id}")

    assert {:error, _} =
             OAuth.exchange_authorization_code(%{params | "code_verifier" => "wrong"})

    refute_receive %Broadcast{event: "connection_created"}
  end
end
