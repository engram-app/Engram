defmodule Engram.OAuthScopeNarrowingTest do
  @moduledoc """
  Unknown scopes are narrowed away at /authorize, never refused (#1974).

  RFC 6749 §3.3 lets the server issue a narrower scope than requested and
  report it in the token response. Refusing with `invalid_scope` instead
  killed connectors that add `offline_access`, `openid` or `profile` by habit:
  the refusal is a 302 back to the client, which most show as a generic
  failure.
  """
  use Engram.DataCase, async: true

  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Engram.OAuth

  setup do
    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "client_name" => "Claude"
      })

    %{client: client}
  end

  defp authorize(client, scope) do
    {_verifier, challenge} = pkce_pair()

    OAuth.validate_authorization_request(%{
      "client_id" => client.client_id,
      "redirect_uri" => hd(client.redirect_uris),
      "response_type" => "code",
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => "s",
      "scope" => scope
    })
  end

  for scope <- ["mcp offline_access", "openid profile mcp", "offline_access", "openid email"] do
    test "#{inspect(scope)} is narrowed to mcp", %{client: client} do
      assert {:ok, validated} = authorize(client, unquote(scope))
      assert validated.scope == "mcp"
      assert validated.scope_requested == String.split(unquote(scope))
    end
  end

  test "the narrowed scope is what the grant and its tokens carry", %{client: client} do
    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => hd(client.redirect_uris),
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp offline_access openid"
      })

    {:ok, url} = OAuth.mint_authorization_code(insert(:user), validated, :all, nil)

    assert {:ok, %{scope: "mcp"}} =
             OAuth.exchange_authorization_code(%{
               "code" => code_from_redirect(url),
               "redirect_uri" => hd(client.redirect_uris),
               "client_id" => client.client_id,
               "code_verifier" => verifier
             })
  end
end
