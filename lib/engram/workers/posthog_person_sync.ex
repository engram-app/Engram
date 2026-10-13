defmodule Engram.Workers.PostHogPersonSync do
  @moduledoc """
  Daily push of every live user's account facts to their PostHog person, so
  PostHog can segment by plan, size and signup date.

  Self-healing by construction: each run re-sends the full current state, so a
  new property fills in on the next run and a missed run costs one day of
  staleness. No-op when PostHog is not configured (self-host, dev, test).

  Only account-level facts leave: never note content, titles, paths, vault
  names or search text (privacy policy 2026-10-12).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Billing
  alias Engram.Billing.Subscription
  alias Engram.Observability.PostHog
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if PostHog.enabled?() do
      rows() |> Enum.map(&to_person/1) |> PostHog.set_people()
    else
      :ok
    end
  end

  # Cross-tenant on purpose: one aggregate over every user. Maintenance repo so
  # RLS does not hide other tenants' vaults and attachments.
  defp rows do
    vaults =
      from(v in Vault,
        where: is_nil(v.deleted_at),
        group_by: v.user_id,
        select: %{user_id: v.user_id, n: count(v.id)}
      )

    bytes =
      from(a in Attachment,
        where: is_nil(a.deleted_at),
        group_by: a.user_id,
        select: %{user_id: a.user_id, bytes: sum(a.size_bytes)}
      )

    query =
      from(u in User,
        left_join: s in Subscription,
        on: s.user_id == u.id,
        left_join: m in "usage_meters",
        on: m.user_id == u.id,
        left_join: vc in subquery(vaults),
        on: vc.user_id == u.id,
        left_join: ab in subquery(bytes),
        on: ab.user_id == u.id,
        where: is_nil(u.deleted_at) and not is_nil(u.email),
        select: %{
          email: u.email,
          name: u.display_name,
          created_at: u.created_at,
          tier: s.tier,
          status: s.status,
          notes_count: coalesce(m.notes_count, 0),
          vault_count: coalesce(vc.n, 0),
          storage_bytes: type(coalesce(ab.bytes, 0), :integer)
        }
      )

    repo = Repo.maintenance()
    Repo.cross_tenant(fn -> repo.all(query) end)
  end

  defp to_person(row) do
    {PostHog.analytics_id(row.email),
     %{
       email: row.email,
       name: row.name,
       signed_up_at: row.created_at,
       plan: plan(row.tier, row.status),
       subscription_status: row.status,
       notes_count: row.notes_count,
       vault_count: row.vault_count,
       storage_bytes: row.storage_bytes
     }}
  end

  # Mirrors `Billing.tier/1`: only an entitled status grants the paid tier.
  defp plan(tier, status) when tier in ["starter", "pro"] do
    if status in Billing.entitled_statuses(), do: tier, else: "free"
  end

  defp plan(_tier, _status), do: "free"
end
