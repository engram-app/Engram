defmodule Engram.OAuthSingleUseTest do
  use Engram.DataCase, async: true

  alias Engram.OAuth

  defp pkce_pair do
    verifier =
      :crypto.strong_rand_bytes(48)
      |> Base.url_encode64(padding: false)

    challenge =
      :crypto.hash(:sha256, verifier)
      |> Base.url_encode64(padding: false)

    {verifier, challenge}
  end

  defp mint_code(user, client, redirect_uri, challenge) do
    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => "xyz",
        "scope" => "mcp"
      })

    {:ok, redirect_url} = OAuth.mint_authorization_code(user, validated, "vault:*")

    %{query: query} = URI.parse(redirect_url)
    URI.decode_query(query)["code"]
  end

  defp exchange_params(user) do
    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "client_name" => "Claude"
      })

    redirect_uri = hd(client.redirect_uris)
    {verifier, challenge} = pkce_pair()
    code = mint_code(user, client, redirect_uri, challenge)

    %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => client.client_id,
      "code_verifier" => verifier
    }
  end

  describe "exchange_authorization_code/2 single-use guarantee" do
    test "concurrent exchanges of the same code yield exactly one success" do
      user = insert(:user)
      params = exchange_params(user)

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn -> OAuth.exchange_authorization_code(params) end)
        end)
        |> Task.await_many(30_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :invalid_grant}, &1)) == 7
    end
  end

  describe "rotate_refresh_token/3 single-use guarantee" do
    test "concurrent rotations of the same refresh token yield at most one success" do
      user = insert(:user)
      params = exchange_params(user)
      {:ok, %{refresh_token: refresh_raw}} = OAuth.exchange_authorization_code(params)

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn ->
            OAuth.rotate_refresh_token(refresh_raw, params["client_id"])
          end)
        end)
        |> Task.await_many(30_000)

      # A loser of the race revokes the family (RFC 6749 §10.4 replay
      # response), which may race the winner's own mint — so the winner
      # count is 0 or 1, never more.
      assert Enum.count(results, &match?({:ok, _}, &1)) <= 1
      assert Enum.count(results, &match?({:error, :invalid_grant}, &1)) >= 7
    end
  end
end
