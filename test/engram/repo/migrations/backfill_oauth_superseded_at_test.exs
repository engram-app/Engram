defmodule Engram.Repo.Migrations.BackfillOAuthRefreshTokensSupersededAtTest do
  @moduledoc """
  The one-time backfill of `superseded_at` onto the rows 0.52.0's grace
  re-issue (#1981) revoked without it. `Engram.OAuth.cleanup_expired/0`
  re-applies the same predicate hourly (tested in `OAuthGrantStateTest`).
  """
  use Engram.DataCase, async: true

  alias Engram.OAuth.RefreshToken
  alias Engram.Repo

  Code.require_file(
    "priv/repo/migrations/20261015060000_backfill_oauth_refresh_tokens_superseded_at.exs"
  )

  alias Engram.Repo.Migrations.BackfillOAuthRefreshTokensSupersededAt, as: Migration

  setup do
    user = insert(:user)
    {:ok, client} = Engram.OAuth.register_client(%{"redirect_uris" => ["https://c.example/cb"]})
    %{user: user, client: client}
  end

  defp token(ctx, family, attrs) do
    Repo.insert!(
      struct!(
        RefreshToken,
        Map.merge(
          %{
            token_hash: Ecto.UUID.generate(),
            family_id: family,
            client_id: ctx.client.client_id,
            user_id: ctx.user.id,
            expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)
          },
          attrs
        )
      ),
      skip_tenant_check: true
    )
  end

  defp migrate, do: Enum.each(Migration.statements(), &Repo.query!/1)

  defp superseded_at(t), do: Repo.reload!(t, skip_tenant_check: true).superseded_at

  test "stamps a revoked unused row whose family still has a live row", ctx do
    family = Ecto.UUID.generate()
    at = DateTime.utc_now(:second)
    token(ctx, family, %{consumed_at: at})
    replaced = token(ctx, family, %{revoked_at: at})
    token(ctx, family, %{})

    migrate()

    assert superseded_at(replaced) == at
  end

  test "leaves a family revoke and a leaf revoke alone", ctx do
    at = DateTime.utc_now(:second)

    family_revoked = Ecto.UUID.generate()
    token(ctx, family_revoked, %{consumed_at: at, revoked_at: at})
    whole = token(ctx, family_revoked, %{revoked_at: at})

    leaf_revoked = Ecto.UUID.generate()
    token(ctx, leaf_revoked, %{consumed_at: at})
    leaf = token(ctx, leaf_revoked, %{revoked_at: at})

    consumed_and_revoked = Ecto.UUID.generate()
    used = token(ctx, consumed_and_revoked, %{consumed_at: at, revoked_at: at})
    token(ctx, consumed_and_revoked, %{})

    migrate()

    refute superseded_at(whole)
    refute superseded_at(leaf)
    refute superseded_at(used)
  end
end
