defmodule Engram.OAuthRevokeByVaultRotationRaceTest do
  @moduledoc """
  `DELETE /api/connections/oauth/:client_id?vault_id=` finds leveled grants by
  reading only their unconsumed rows (`Connections.leveled_reaching/3`). The
  worry: a rotation mid-flight has consumed the old row and not yet inserted
  the successor, the revoke sees no unconsumed row, and the family escapes.

  It cannot, because rotation consumes and inserts in ONE transaction: another
  session sees the old row unconsumed until the successor commits with it.
  This proves that with a real second session. A trigger stalls the
  successor's INSERT, so the rotation sits uncommitted with the old row
  already consumed in its own transaction, and the revoke runs in that window.

  Real commits (the sandbox shares one transaction across processes, which
  would show the revoke the uncommitted consume), so everything is created
  through `unboxed_run` and deleted afterwards; the trigger only matches this
  test's family.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Engram.Factory
  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Connections, OAuth, Repo, Vaults}
  alias Engram.OAuth.RefreshToken

  @redirect "https://client.example/cb"
  @stall_seconds 1.5

  setup do
    Sandbox.unboxed_run(Repo, fn ->
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      {:ok, a, _} = Vaults.register_vault(user, "A", Ecto.UUID.generate())

      {:ok, client} =
        OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "Race"})

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])

          Repo.query!("DELETE FROM oauth_clients WHERE client_id = $1", [
            Ecto.UUID.dump!(client.client_id)
          ])
        end)
      end)

      %{user: user, a: a, client: client, tokens: grant(user, client, a)}
    end)
  end

  defp grant(user, client, vault) do
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

    {:ok, url} =
      OAuth.mint_authorization_code(user, validated, {%{vault.id => "read"}, "none"}, nil)

    {:ok, tokens} =
      OAuth.exchange_authorization_code(%{
        "code" => code_from_redirect(url),
        "redirect_uri" => @redirect,
        "client_id" => client.client_id,
        "code_verifier" => verifier
      })

    tokens
  end

  defp family_of(raw) do
    hash = Engram.Crypto.sha256_hex(raw)

    Repo.one!(
      from(t in RefreshToken, where: t.token_hash == ^hash, select: t.family_id),
      skip_tenant_check: true
    )
  end

  # Stalls the INSERT of this family's rotation successor (it has a parent).
  defp stall_successor_insert(family, fun) do
    name = "test_stall_rotation_#{System.unique_integer([:positive])}"

    Repo.query!("""
    CREATE FUNCTION public.#{name}() RETURNS trigger AS $$
    BEGIN
      PERFORM pg_sleep(#{@stall_seconds});
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER #{name} BEFORE INSERT ON oauth_refresh_tokens
    FOR EACH ROW WHEN (NEW.family_id = '#{family}'::uuid AND NEW.parent_id IS NOT NULL)
    EXECUTE FUNCTION public.#{name}()
    """)

    try do
      fun.()
    after
      Repo.query!("DROP TRIGGER IF EXISTS #{name} ON oauth_refresh_tokens")
      Repo.query!("DROP FUNCTION IF EXISTS public.#{name}()")
    end
  end

  defp await_stalled_insert(tries \\ 100)
  defp await_stalled_insert(0), do: flunk("the rotation never reached the stalled insert")

  defp await_stalled_insert(tries) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE wait_event = 'PgSleep'")

    if n > 0 do
      :ok
    else
      Process.sleep(20)
      await_stalled_insert(tries - 1)
    end
  end

  test "a revoke by vault during a rotation still revokes the family", ctx do
    Sandbox.unboxed_run(Repo, fn ->
      family = family_of(ctx.tokens.refresh_token)

      stall_successor_insert(family, fn ->
        rotation =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              OAuth.rotate_refresh_token(ctx.tokens.refresh_token, ctx.client.client_id)
            end)
          end)

        # Old row consumed inside the rotation's transaction, successor not
        # yet inserted: the window the concern names.
        await_stalled_insert()

        {waited_us, :ok} =
          :timer.tc(fn ->
            Connections.revoke_oauth_family(ctx.user.id, ctx.client.client_id, ctx.a.id)
          end)

        # It waited on the stalled rotation's grant lock: it ran inside the
        # window and found the family. (Mutating `leveled_reaching` to find
        # nothing fails here: the revoke returns at once.)
        assert waited_us > 500_000,
               "revoke took #{waited_us}us without waiting on the rotation: it found no family, or missed the window"

        # The rotation committed after the revoke's read, so its successor
        # exists, and was revoked: the revoke waited on the grant lock.
        assert {:ok, rotated} = Task.await(rotation, 10_000)
        assert family_of(rotated.refresh_token) == family

        live =
          Repo.all(
            from(t in RefreshToken,
              where: t.family_id == ^family and is_nil(t.revoked_at),
              select: t.id
            ),
            skip_tenant_check: true
          )

        assert live == []
        assert Engram.Accounts.grant_claims(rotated.access_token) == :revoked

        assert {:error, {:invalid_grant, _}} =
                 OAuth.rotate_refresh_token(rotated.refresh_token, ctx.client.client_id)
      end)
    end)
  end
end
