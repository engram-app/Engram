defmodule Engram.Repo.Migrations.RenameStripeToPaddleOnSubscriptions do
  use Ecto.Migration

  def change do
    drop_if_exists index(:subscriptions, [:stripe_customer_id])
    drop_if_exists index(:subscriptions, [:stripe_subscription_id])

    alter table(:subscriptions) do
      remove :stripe_customer_id, :string, null: false
      remove :stripe_subscription_id, :string
      add :paddle_customer_id, :string, null: false
      add :paddle_subscription_id, :string
      add :custom_data, :map, null: false, default: %{}
    end

    create index(:subscriptions, [:paddle_customer_id])
    create unique_index(:subscriptions, [:paddle_subscription_id])
  end
end
