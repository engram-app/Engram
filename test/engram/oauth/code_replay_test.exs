defmodule Engram.OAuth.CodeReplayTest do
  @moduledoc """
  RFC 6749 §4.1.2: a replayed authorization code is refused and revokes the
  tokens it issued (#1977), but only past the 60 s grace window and only for a
  replay that passes the client and PKCE checks.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Engram.OAuth
  alias Engram.OAuth.AuthorizationCode
  alias Engram.OAuth.RefreshToken
  alias Engram.Repo

  @redirect "https://claude.ai/api/mcp/auth_callback"

  setup do
    {:ok, client} = OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "C"})
    user = insert(:user)
    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    {:ok, url} = OAuth.mint_authorization_code(user, validated, :all, nil)
    code = code_from_redirect(url)

    params = %{
      "code" => code,
      "client_id" => client.client_id,
      "redirect_uri" => @redirect,
      "code_verifier" => verifier
    }

    {:ok, %{refresh_token: rt}} = OAuth.exchange_authorization_code(params)
    %{params: params, rt: rt, client: client}
  end

  defp age_code(seconds) do
    at = DateTime.utc_now(:second) |> DateTime.add(-seconds, :second)
    Repo.update_all(AuthorizationCode, [set: [consumed_at: at]], skip_tenant_check: true)
  end

  defp live?(rt) do
    hash = Engram.Crypto.sha256_hex(rt)

    Repo.one!(
      from(r in RefreshToken, where: r.token_hash == ^hash, select: is_nil(r.revoked_at)),
      skip_tenant_check: true
    )
  end

  test "a replay inside the grace window is refused and revokes nothing", ctx do
    assert {:error, {:invalid_grant, :code_consumed}} =
             OAuth.exchange_authorization_code(ctx.params)

    assert live?(ctx.rt)
  end

  test "a replay past the grace window revokes the tokens the code issued", ctx do
    age_code(120)

    assert {:error, {:invalid_grant, :code_replay_revoked}} =
             OAuth.exchange_authorization_code(ctx.params)

    refute live?(ctx.rt)
  end

  # A callback page reloaded long after the connect is not an attack.
  test "a replay of an expired code revokes nothing", ctx do
    age_code(120)
    past = DateTime.utc_now(:second) |> DateTime.add(-1, :second)
    Repo.update_all(AuthorizationCode, [set: [expires_at: past]], skip_tenant_check: true)

    assert {:error, {:invalid_grant, :code_consumed}} =
             OAuth.exchange_authorization_code(ctx.params)

    assert live?(ctx.rt)
  end

  test "a rotated successor is revoked too: the whole family goes", ctx do
    {:ok, %{refresh_token: next}} = OAuth.rotate_refresh_token(ctx.rt, ctx.client.client_id)
    age_code(120)
    _ = OAuth.exchange_authorization_code(ctx.params)
    refute live?(next)
  end

  # A stolen code without the verifier must not be a way to cut the user off.
  test "a replay without the right verifier revokes nothing", ctx do
    age_code(120)
    bad = Map.put(ctx.params, "code_verifier", String.duplicate("a", 64))
    assert {:error, {:invalid_grant, :pkce_mismatch}} = OAuth.exchange_authorization_code(bad)
    assert live?(ctx.rt)
  end
end
