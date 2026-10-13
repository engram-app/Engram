defmodule Engram.Analytics.PersonProperties do
  @moduledoc """
  The account facts `Engram.Workers.PostHogPersonSync` puts on PostHog persons.

  Lives outside `lib/engram/workers/` because it builds a `name` property, and
  the plaintext-args lint bans that key in worker source. None of this is ever
  an Oban arg.

  Only account-level facts: never note content, titles, paths, vault names or
  search text (privacy policy 2026-10-12).
  """

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Billing
  alias Engram.Billing.Subscription
  alias Engram.Notes.Note
  alias Engram.Observability.PostHog
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @policy_version "2026-10-12"

  # Identified analytics starts only once the policy announcing it is in
  # effect (its 30-day notice window has run).
  @spec policy_in_effect?() :: boolean()
  def policy_in_effect? do
    case Engram.Legal.get("privacy_policy", @policy_version) do
      %{effective_date: nil} -> true
      %{effective_date: date} -> Date.compare(date, Date.utc_today()) != :gt
      nil -> false
    end
  end

  @doc "`{distinct_id, properties}` for every live, non-opted-out user."
  @spec all() :: [{String.t(), map()}]
  def all, do: Enum.map(rows(), &to_person/1)

  # Cross-tenant on purpose: one aggregate over every user. Maintenance repo so
  # RLS does not hide other tenants' vaults and attachments.
  defp rows do
    vaults =
      from(v in Vault,
        where: is_nil(v.deleted_at),
        group_by: v.user_id,
        select: %{user_id: v.user_id, n: count(v.id)}
      )

    # Counted from the rows, not `usage_meters.notes_count` (which misses some
    # write paths). Same filter as `Vaults.content_counts/2`, plus a live vault.
    notes =
      from(n in Note,
        join: v in Vault,
        on: v.id == n.vault_id and is_nil(v.deleted_at),
        where: is_nil(n.deleted_at) and n.kind == "note",
        group_by: n.user_id,
        select: %{user_id: n.user_id, n: count(n.id)}
      )

    bytes =
      from(a in Attachment,
        join: v in Vault,
        on: v.id == a.vault_id and is_nil(v.deleted_at),
        where: is_nil(a.deleted_at),
        group_by: a.user_id,
        select: %{user_id: a.user_id, bytes: sum(a.size_bytes)}
      )

    query =
      from(u in User,
        left_join: s in Subscription,
        on: s.user_id == u.id,
        left_join: nc in subquery(notes),
        on: nc.user_id == u.id,
        left_join: vc in subquery(vaults),
        on: vc.user_id == u.id,
        left_join: ab in subquery(bytes),
        on: ab.user_id == u.id,
        where: is_nil(u.deleted_at) and is_nil(u.analytics_opt_out_at) and not is_nil(u.email),
        select: %{
          email: u.email,
          name: u.display_name,
          created_at: u.created_at,
          tier: s.tier,
          status: s.status,
          notes_count: coalesce(nc.n, 0),
          vault_count: coalesce(vc.n, 0),
          attachment_bytes: type(coalesce(ab.bytes, 0), :integer)
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
       attachment_bytes: row.attachment_bytes
     }}
  end

  # Mirrors `Billing.tier/1`: only an entitled status grants the paid tier.
  defp plan(tier, status) when tier in ["starter", "pro"] do
    if status in Billing.entitled_statuses(), do: tier, else: "free"
  end

  defp plan(_tier, _status), do: "free"
end
