defmodule Engram.Repo.Migrations.AddVaultSlugHmacExpand do
  use Ecto.Migration

  # phase/expand — `vaults.slug` is a plaintext copy of the (encrypted) vault
  # name, used as the `/v/:slug` URL. The slug moves to derive-on-read:
  # `slug_hmac` (keyed, per-user filter key, like `name_hmac`) carries lookup
  # and uniqueness, and `slug_suffixed` records whether this vault took the
  # collision suffix at mint so the slug stays derivable from name + id.
  # `slug` goes nullable in 20260926100050 so the migrate-data release can
  # stop writing it; the contract release drops it.
  def change do
    alter table(:vaults) do
      add :slug_hmac, :binary
      add :slug_suffixed, :boolean, null: false, default: false
    end
  end
end
