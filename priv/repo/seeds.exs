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
alias Engram.Billing.Plan

for {name, limits} <- [
      {"free",
       %{
         "max_vaults" => 1,
         "max_storage_bytes" => 104_857_600,
         "cross_vault_search" => false,
         "vault_scoped_keys" => false
       }},
      {"pro",
       %{
         "max_vaults" => -1,
         "max_storage_bytes" => 1_073_741_824,
         "cross_vault_search" => true,
         "vault_scoped_keys" => true
       }}
    ] do
  case Repo.get_by(Plan, name: name) do
    nil -> Repo.insert!(%Plan{name: name, limits: limits})
    existing -> Repo.update!(Plan.changeset(existing, %{limits: limits}))
  end
end
