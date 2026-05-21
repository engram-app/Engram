# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Engram.Repo.insert!(%Engram.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Engram.Repo
alias Engram.Billing.{LimitKeys, Plan}

# Seed the three pricing tiers from LimitKeys catalog. Idempotent —
# on_conflict replaces the limits JSONB so re-running ecto.setup drives
# the matrix back to catalog defaults. To change a tier's limits in
# production, edit LimitKeys + cut a release; deploy runs seeds.
for tier <- LimitKeys.tiers() do
  limits =
    for key <- LimitKeys.all(), into: %{} do
      {to_string(key), LimitKeys.default_for(key, tier)}
    end

  Repo.insert!(
    %Plan{name: to_string(tier), limits: limits},
    on_conflict: {:replace, [:limits, :updated_at]},
    conflict_target: :name
  )
end
