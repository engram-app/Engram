defmodule Engram.Repo.Migrations.CreateEmailSuppressions do
  use Ecto.Migration

  @moduledoc """
  Suppression list for engram-originated email. Resend posts bounce/complaint
  webhook events; we record the address here and skip future sends to it to
  protect sender reputation/deliverability. Non-tenant (keyed by address, not
  user). Email is stored normalized to lowercase with a unique index.
  """

  def change do
    create table(:email_suppressions) do
      add :email, :string, null: false
      add :reason, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:email_suppressions, [:email])

    # Enforce the closed reason set at the storage layer too, independent of the
    # Ecto.Enum changeset cast (guards raw inserts / future backfills).
    create constraint(:email_suppressions, :reason_must_be_valid,
             check: "reason IN ('bounced', 'complained')"
           )
  end
end
