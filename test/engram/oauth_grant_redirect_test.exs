defmodule Engram.OAuthGrantRedirectTest do
  @moduledoc """
  #1204. `oauth_refresh_tokens.redirect_uri` records where a grant's code was
  actually delivered, so `Engram.Connections` can decide the verified badge from
  what happened rather than from the client's registered list.

  These tests drive the real flow (register -> authorize -> exchange -> rotate)
  rather than inserting tokens, because the property under test is that the used
  redirect survives every hop. A factory insert would assert the schema, not the
  plumbing.
  """
  use Engram.DataCase, async: true

  alias Engram.OAuth
  alias Engram.OAuth.RefreshToken

  @vendor "https://claude.ai/api/mcp/auth_callback"
  @loopback "http://localhost:9999/steal"

  defp pkce_pair do
    verifier = 48 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  # Registers a client with `registered` redirects, authorizes against `used`,
  # and exchanges. Returns the token pair.
  defp grant(user, registered, used) do
    {:ok, client} =
      OAuth.register_client(%{"redirect_uris" => registered, "client_name" => "Claude"})

    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => used,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp"
      })

    {:ok, redirect_url} = OAuth.mint_authorization_code(user, validated, "vault:*")

    code =
      redirect_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.get("code")

    {:ok, tokens} =
      OAuth.exchange_authorization_code(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => used,
        "client_id" => client.client_id,
        "code_verifier" => verifier
      })

    {client, tokens}
  end

  defp stored_redirect(raw) do
    Repo.get_by!(RefreshToken, token_hash: Engram.Crypto.sha256_hex(raw)).redirect_uri
  end

  test "the exchange records the redirect the code was delivered to" do
    user = insert(:user)
    {_client, tokens} = grant(user, [@loopback, @vendor], @loopback)

    # NOT @vendor, even though the client registered it. That substitution is
    # the whole of #1204.
    assert stored_redirect(tokens.refresh_token) == @loopback
  end

  test "rotation carries the grant's redirect onto the successor" do
    user = insert(:user)
    {client, tokens} = grant(user, [@vendor], @vendor)

    {:ok, rotated} = OAuth.rotate_refresh_token(tokens.refresh_token, client.client_id)

    # Immutable for the life of the family: the grant was delivered once, and a
    # successor is the same grant, not a new one.
    assert stored_redirect(rotated.refresh_token) == @vendor
  end

  test "the connections badge follows the used redirect, not the registered list" do
    user = insert(:user)
    {_client, _tokens} = grant(user, [@loopback, @vendor], @loopback)

    assert [%{name: "Claude", verified: false, logo: nil}] =
             Engram.Connections.list_for_user(user)
  end

  test "an honest grant to the same client still verifies" do
    user = insert(:user)
    {_client, _tokens} = grant(user, [@loopback, @vendor], @vendor)

    assert [%{verified: true, slug: "claude", logo: "/assets/clients/claude.svg"}] =
             Engram.Connections.list_for_user(user)
  end
end
