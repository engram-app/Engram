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

  alias Engram.Accounts.ApiKey
  alias Engram.Accounts.User
  alias Engram.Analytics.McpClient
  alias Engram.Attachments.Attachment
  alias Engram.Auth.DeviceRefreshToken
  alias Engram.Billing
  alias Engram.Billing.Subscription
  alias Engram.Notes.Note
  alias Engram.OAuth.Client
  alias Engram.OAuth.RefreshToken
  alias Engram.Onboarding.Action
  alias Engram.Repo
  alias Engram.UsageMeters.Meter
  alias Engram.Vaults.Vault

  require Engram.OAuth

  # The privacy version that announced identified analytics. Its seeded
  # effective_date (2026-11-11 in `Engram.Legal.Seeder`) is the "takes effect on
  # November 11, 2026" date the policy text promises; change one, change both.
  # Must stay a version with a future-at-publish effective_date giving 30 days'
  # notice: a nil date would start linking analytics at once, unannounced.
  # `test/engram/analytics/person_properties_test.exs` enforces it.
  @policy_version "2026-10-12"

  @doc false
  def policy_version, do: @policy_version

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

  @doc "`{%{email: _}, traits}` for every live, non-opted-out user, for `Engram.Analytics.set_traits/1`."
  @spec all() :: [{map(), map()}]
  def all do
    repo = Repo.maintenance()
    {rows, oauth} = Repo.cross_tenant(fn -> {repo.all(query()), repo.all(oauth_clients())} end)
    oauth = Enum.group_by(oauth, &elem(&1, 0), &elem(&1, 1))
    Enum.map(rows, &to_person(&1, Map.get(oauth, &1.user_id, [])))
  end

  # Cross-tenant on purpose: one aggregate over every user. Maintenance repo so
  # RLS does not hide other tenants' vaults and attachments.
  defp query do
    # Deleted vaults count toward first_vault_at: it is when they started.
    first_vault =
      from(v in Vault, group_by: v.user_id, select: %{user_id: v.user_id, at: min(v.created_at)})

    # Counted from the rows, not `usage_meters.notes_count` (which misses some
    # write paths). Same filter as `Vaults.content_counts/2`, plus a live vault.
    notes =
      from(n in Note,
        where: is_nil(n.deleted_at) and n.kind == "note",
        group_by: n.vault_id,
        # Stored size: encrypted and possibly compressed, not plaintext.
        select: %{
          vault_id: n.vault_id,
          n: count(n.id),
          bytes: sum(fragment("octet_length(?)", n.content_ciphertext))
        }
      )

    attachments =
      from(a in Attachment,
        where: is_nil(a.deleted_at),
        group_by: a.vault_id,
        select: %{vault_id: a.vault_id, n: count(a.id), bytes: sum(a.size_bytes)}
      )

    per_vault =
      from(v in Vault,
        left_join: nv in subquery(notes),
        on: nv.vault_id == v.id,
        left_join: av in subquery(attachments),
        on: av.vault_id == v.id,
        where: is_nil(v.deleted_at),
        select: %{
          user_id: v.user_id,
          notes: coalesce(nv.n, 0),
          note_bytes: coalesce(nv.bytes, 0),
          attachments: coalesce(av.n, 0),
          attachment_bytes: coalesce(av.bytes, 0)
        }
      )

    sizes =
      from(p in subquery(per_vault),
        group_by: p.user_id,
        select: %{
          user_id: p.user_id,
          vaults: count(),
          notes: sum(p.notes),
          note_bytes: sum(p.note_bytes),
          attachments: sum(p.attachments),
          attachment_bytes: sum(p.attachment_bytes),
          largest_notes: max(p.notes),
          largest_bytes: max(p.note_bytes + p.attachment_bytes)
        }
      )

    # Live device families, as `Connections.count_active/2` reads them. Each
    # refresh mints a row, so the newest row is when a device was last seen.
    devices =
      from(rt in DeviceRefreshToken,
        group_by: rt.user_id,
        select: %{
          user_id: rt.user_id,
          n:
            filter(
              count(fragment("DISTINCT ?", rt.family_id)),
              is_nil(rt.revoked_at) and rt.expires_at > ^DateTime.utc_now()
            ),
          last_seen: max(rt.inserted_at)
        }
      )

    keys = from(k in ApiKey, group_by: k.user_id, select: %{user_id: k.user_id, n: count(k.id)})

    milestones =
      from(a in Action,
        where: a.action in ["plugin_connected", "ai_connected"],
        group_by: a.user_id,
        select: %{
          user_id: a.user_id,
          plugin_at: filter(min(a.inserted_at), a.action == "plugin_connected"),
          ai_at: filter(min(a.inserted_at), a.action == "ai_connected")
        }
      )

    from(u in User,
      left_join: s in Subscription,
      on: s.user_id == u.id,
      left_join: sz in subquery(sizes),
      on: sz.user_id == u.id,
      left_join: fv in subquery(first_vault),
      on: fv.user_id == u.id,
      left_join: dc in subquery(devices),
      on: dc.user_id == u.id,
      left_join: kc in subquery(keys),
      on: kc.user_id == u.id,
      left_join: m in subquery(milestones),
      on: m.user_id == u.id,
      left_join: um in Meter,
      on: um.user_id == u.id,
      where: is_nil(u.deleted_at) and is_nil(u.analytics_opt_out_at) and not is_nil(u.email),
      select: %{
        email: u.email,
        name: u.display_name,
        created_at: u.created_at,
        tier: s.tier,
        status: s.status,
        user_id: u.id,
        vault_count: coalesce(sz.vaults, 0),
        total_notes: type(coalesce(sz.notes, 0), :integer),
        total_note_bytes: type(coalesce(sz.note_bytes, 0), :integer),
        total_attachments: type(coalesce(sz.attachments, 0), :integer),
        total_attachment_bytes: type(coalesce(sz.attachment_bytes, 0), :integer),
        largest_vault_notes: type(coalesce(sz.largest_notes, 0), :integer),
        largest_vault_bytes: type(coalesce(sz.largest_bytes, 0), :integer),
        obsidian_devices: coalesce(dc.n, 0),
        obsidian_last_seen_at: dc.last_seen,
        api_keys_count: coalesce(kc.n, 0),
        embed_tokens_used: coalesce(um.lifetime_embed_tokens, 0),
        last_active_at: um.last_active_at,
        first_vault_at: fv.at,
        plugin_connected_at: m.plugin_at,
        ai_connected_at: m.ai_at
      }
    )
  end

  # `{user_id, client}` per live OAuth grant's client, one row per pair.
  defp oauth_clients do
    from(t in RefreshToken,
      join: c in Client,
      on: c.client_id == t.client_id,
      where: is_nil(t.revoked_at) and is_nil(t.consumed_at),
      where: Engram.OAuth.family_unrevoked(t.family_id),
      distinct: [t.user_id, c.client_id],
      select: {t.user_id, c}
    )
  end

  defp to_person(row, clients) do
    {obsidian, mcp} = Enum.split_with(clients, &(&1.kind == "obsidian"))

    {%{email: row.email},
     %{
       email: row.email,
       name: row.name,
       signed_up_at: row.created_at,
       plan: plan(row.tier, row.status),
       subscription_status: row.status,
       vault_count: row.vault_count,
       total_notes: row.total_notes,
       total_note_bytes: row.total_note_bytes,
       total_attachments: row.total_attachments,
       total_attachment_bytes: row.total_attachment_bytes,
       largest_vault_notes: row.largest_vault_notes,
       largest_vault_bytes: row.largest_vault_bytes,
       # Device-flow families plus OAuth-linked Obsidian clients.
       obsidian_devices: row.obsidian_devices + length(obsidian),
       obsidian_last_seen_at: row.obsidian_last_seen_at,
       mcp_clients:
         mcp |> Enum.map(&elem(McpClient.of_client(&1), 0)) |> Enum.uniq() |> Enum.sort(),
       mcp_client_count: length(mcp),
       api_keys_count: row.api_keys_count,
       embed_tokens_used: row.embed_tokens_used,
       last_active_at: row.last_active_at,
       first_vault_at: row.first_vault_at,
       plugin_connected_at: row.plugin_connected_at,
       ai_connected_at: row.ai_connected_at
     }}
  end

  @doc "The `plan` trait for a subscription's tier and status. Mirrors `Billing.tier/1`: only an entitled status grants the paid tier."
  @spec plan(String.t() | nil, String.t() | nil) :: String.t()
  def plan(tier, status) when tier in ["starter", "pro"] do
    if status in Billing.entitled_statuses(), do: tier, else: "free"
  end

  def plan(_tier, _status), do: "free"
end
