defmodule Engram.OAuthRotationNarrowingRaceTest do
  @moduledoc """
  A rotation successor must carry its family's state as it is AFTER the
  consume, not the predecessor as `rotate_refresh_token/3` read it a moment
  earlier: vault deletion narrowing the family in between would otherwise be
  undone by the successor, which is the row every later read answers from.

  The narrowing is staged with a trigger that rewrites the row at consume
  time, the latest point a concurrent narrowing can land on it. DDL locks
  the table for the test's whole sandbox transaction, hence `async: false`
  (sync modules run after every async one).
  """
  use Engram.DataCase, async: false

  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Engram.{OAuth, Vaults}
  alias Engram.OAuth.RefreshToken
  alias Engram.Repo

  @redirect "https://client.example/cb"

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, a, _} = Vaults.register_vault(user, "A", Ecto.UUID.generate())
    {:ok, b, _} = Vaults.register_vault(user, "B", Ecto.UUID.generate())

    {:ok, client} =
      OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "Client"})

    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp"
      })

    {:ok, url} = OAuth.mint_authorization_code(user, validated, [a.id, b.id], nil)

    {:ok, tokens} =
      OAuth.exchange_authorization_code(%{
        "code" => code_from_redirect(url),
        "redirect_uri" => @redirect,
        "client_id" => client.client_id,
        "code_verifier" => verifier
      })

    %{client: client, a: a, b: b, tokens: tokens}
  end

  defp row(raw), do: Repo.get_by!(RefreshToken, token_hash: Engram.Crypto.sha256_hex(raw))

  test "a narrowing that lands at consume time is not undone by the successor", ctx do
    Repo.query!("""
    CREATE FUNCTION pg_temp.narrow_on_consume() RETURNS trigger AS $$
    BEGIN
      NEW.vault_ids := array_remove(NEW.vault_ids, '#{ctx.b.id}'::uuid);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER narrow_on_consume BEFORE UPDATE ON oauth_refresh_tokens
    FOR EACH ROW WHEN (OLD.consumed_at IS NULL AND NEW.consumed_at IS NOT NULL)
    EXECUTE FUNCTION pg_temp.narrow_on_consume()
    """)

    {:ok, rotated} = OAuth.rotate_refresh_token(ctx.tokens.refresh_token, ctx.client.client_id)

    assert row(ctx.tokens.refresh_token).vault_ids == [ctx.a.id]
    assert row(rotated.refresh_token).vault_ids == [ctx.a.id]
    {:ok, claims} = Engram.Token.verify(rotated.access_token)
    assert claims["vault_ids"] == [ctx.a.id]
  end
end
