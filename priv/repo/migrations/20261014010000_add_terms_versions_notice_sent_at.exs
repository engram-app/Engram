defmodule Engram.Repo.Migrations.AddTermsVersionsNoticeSentAt do
  use Ecto.Migration

  @moduledoc """
  phase/expand. Two nullable `:timestamptz` columns (Squawk prefer-timestamp-tz),
  no default, no backfill: metadata-only ALTERs. `Engram.Workers.LegalNoticeDispatch`
  stamps `notified_at` when it emails users about a version and `reminded_at`
  when it sends the pre-effective reminder, so each goes out once.
  """

  def change do
    alter table(:terms_versions) do
      add :notified_at, :timestamptz
      add :reminded_at, :timestamptz
    end
  end
end
