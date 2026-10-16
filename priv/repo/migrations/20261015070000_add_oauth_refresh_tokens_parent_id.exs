defmodule Engram.Repo.Migrations.AddOAuthRefreshTokensParentId do
  use Ecto.Migration

  @moduledoc """
  `oauth_refresh_tokens.parent_id`: the row a rotation successor was minted
  from (the original rotation and every grace re-issue of it). The grace
  re-issue finds a token's successors by it instead of by `inserted_at >=
  consumed_at`, which compared two app-node clocks (#1974 fifth review).

  Nullable, no default, no FK (cleanup deletes rows singly), no backfill:
  NULL on a family's first row and on rows minted before this, which the
  grace path still matches by time. A metadata-only ALTER; purely additive.
  """

  def change do
    alter table(:oauth_refresh_tokens) do
      add :parent_id, :uuid
    end
  end
end
