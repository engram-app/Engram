defmodule Engram.Insights.Snapshot do
  @moduledoc """
  Daily account and vault snapshots for the operator insights
  (`user_daily_metrics`, `vault_daily_metrics`), run by
  `Engram.Workers.DailySnapshot`. Lives outside `lib/engram/workers/` because
  it names a `tags` column, which the plaintext-args lint bans in worker
  source; none of this is ever an Oban arg.

  `run/1` writes YESTERDAY by default: each live,
  non-opted-out user's state as of the run (the facts
  `Engram.Analytics.PersonProperties` builds) plus their activity that day
  from `analytics_events`, and each live vault's size.

  Idempotent: every row is an upsert keyed on (user or vault, date), so a
  rerun rewrites the same rows. Self-healing for activity: each run also
  rebuilds the event rollups of the 7 days before yesterday, so a missed
  run loses no activity. Account state cannot be recovered after the fact,
  so a healed day keeps `captured_at` NULL (and its state columns empty)
  unless an earlier run captured it.

  Cross-tenant by design: reads every tenant through `Repo.maintenance()`.
  Set-based: a fixed number of queries whatever the user count. Never stores
  note content, titles, paths or vault names.
  """
  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Analytics.Event
  alias Engram.Analytics.PersonProperties
  alias Engram.Attachments.Attachment
  alias Engram.Billing
  alias Engram.Billing.UserLimitOverride
  alias Engram.Insights.UserDailyMetric
  alias Engram.Insights.VaultDailyMetric
  alias Engram.Links.NoteLink
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @heal_days 7
  # Postgres caps a statement at 65,535 parameters; ~25 columns a row.
  @chunk 1_000
  @rollup_fields [:searches, :mcp_tool_calls, :web_edited, :updated_at]
  # Vaults per snapshot query; each chunk is its own statement and commit.
  @vault_chunk 500
  @chunk_timeout :timer.minutes(2)

  @doc """
  Write one day's snapshots (default yesterday). Returns the day and the rows
  written.

  Vaults go in chunks of `:chunk` vault ids, each chunk its own query and
  upsert, so no single statement scans every note. `:since` makes a retry
  resume: a vault whose row for the day was written at or after `:since` (by
  an earlier attempt of the same job) is skipped. A new run (no `:since`)
  rewrites every vault.
  """
  @spec run(keyword()) :: %{
          date: Date.t(),
          users: non_neg_integer(),
          healed: non_neg_integer(),
          vaults: non_neg_integer()
        }
  def run(opts \\ []) do
    day = Keyword.get_lazy(opts, :day, fn -> Date.add(Date.utc_today(), -1) end)
    today = Date.add(day, 1)
    now = DateTime.utc_now()
    repo = Repo.maintenance()

    {users, healed} =
      Repo.cross_tenant(fn ->
        facts = PersonProperties.by_user()
        live = MapSet.new(facts, &elem(&1, 0))
        rollups = rollups(repo, Date.add(day, -@heal_days), today, live)

        users = state_rows(repo, facts, day, now, rollups)
        upsert(repo, UserDailyMetric, users, {:replace_all_except, [:inserted_at]})

        healed =
          for {{user_id, date}, r} <- rollups, date != day do
            Map.merge(r, %{user_id: user_id, date: date, inserted_at: now, updated_at: now})
          end

        upsert(repo, UserDailyMetric, healed, {:replace, @rollup_fields})
        {length(users), length(healed)}
      end)

    vaults = snapshot_vaults(repo, day, now, opts)
    %{date: day, users: users, healed: healed, vaults: vaults}
  end

  # Each chunk commits on its own, so a timeout keeps every chunk before it.
  defp snapshot_vaults(repo, day, now, opts) do
    chunk = Keyword.get(opts, :chunk, @vault_chunk)

    Repo.cross_tenant(fn -> vault_ids(repo, day, opts[:since]) end)
    |> Enum.chunk_every(chunk)
    |> Enum.reduce(0, fn ids, n ->
      rows = Repo.cross_tenant(fn -> vault_rows(repo, ids, day, now) end)
      upsert(repo, VaultDailyMetric, rows, {:replace_all_except, [:inserted_at]})
      n + length(rows)
    end)
  end

  # Live vaults of live, non-opted-out users, minus those this job already
  # wrote for the day.
  defp vault_ids(repo, day, since) do
    query =
      from(v in Vault,
        as: :vault,
        join: u in User,
        on: u.id == v.user_id,
        # The users `PersonProperties.by_user/0` snapshots.
        where: is_nil(v.deleted_at) and is_nil(u.deleted_at),
        where: is_nil(u.analytics_opt_out_at) and not is_nil(u.email),
        order_by: v.id,
        select: v.id
      )

    query =
      if since do
        from(v in query,
          where:
            not exists(
              from(m in VaultDailyMetric,
                where:
                  m.vault_id == parent_as(:vault).id and m.date == ^day and
                    m.updated_at >= ^since,
                select: 1
              )
            )
        )
      else
        query
      end

    repo.all(query, timeout: @chunk_timeout)
  end

  defp upsert(repo, schema, rows, on_conflict) do
    target = if schema == UserDailyMetric, do: [:user_id, :date], else: [:vault_id, :date]

    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.each(&repo.insert_all(schema, &1, on_conflict: on_conflict, conflict_target: target))
  end

  defp state_rows(repo, facts, day, now, rollups) do
    ids = Enum.map(facts, &elem(&1, 0))
    created = keys_created(repo, ids)
    overrides = embed_cap_overrides(repo, ids, now)
    buckets = embed_buckets(repo, ids)

    for {user_id, t} <- facts do
      rollup = Map.get(rollups, {user_id, day}, empty_rollup())

      Map.merge(rollup, %{
        user_id: user_id,
        date: day,
        captured_at: now,
        plan: t.plan,
        subscription_status: t.subscription_status,
        vault_count: t.vault_count,
        notes: t.total_notes,
        note_bytes: t.total_note_bytes,
        attachments: t.total_attachments,
        attachment_bytes: t.total_attachment_bytes,
        obsidian_devices: t.obsidian_devices,
        obsidian_last_seen_at: usec(t.obsidian_last_seen_at),
        mcp_clients: t.mcp_clients,
        mcp_client_count: t.mcp_client_count,
        api_keys_live: t.api_keys_count,
        api_keys_created: Map.get(created, user_id, 0),
        embed_tokens_used: t.embed_tokens_used,
        embed_budget_pct:
          budget_pct(t, Map.fetch(overrides, user_id), Map.get(buckets, user_id), now),
        last_active_at: usec(t.last_active_at),
        inserted_at: now,
        updated_at: now
      })
    end
  end

  defp empty_rollup, do: %{searches: 0, mcp_tool_calls: %{}, web_edited: false}

  defp usec(nil), do: nil
  defp usec(%DateTime{} = dt), do: DateTime.add(dt, 0, :microsecond)
  defp usec(%NaiveDateTime{} = dt), do: dt |> DateTime.from_naive!("Etc/UTC") |> usec()

  # Share of the refilling embed bucket currently spent (0 = full, 100 =
  # empty). A per-user override wins (-1 / nil: no bucket); else the tier's.
  defp budget_pct(t, override, bucket, now) do
    cap =
      case override do
        {:ok, v} when is_integer(v) and v >= 0 -> v
        {:ok, _no_ceiling} -> nil
        :error -> Billing.tier_cap(String.to_existing_atom(t.plan), :embed_token_bucket)
      end

    if is_integer(cap) and cap > 0 do
      {tokens, at} = bucket || {nil, nil}
      left = Engram.UsageMeters.bucket_level(tokens, at, cap, now)
      Float.round((cap - left) * 100 / cap, 2)
    end
  end

  defp embed_buckets(repo, ids) do
    from(m in Engram.UsageMeters.Meter,
      where: m.user_id in ^ids and not is_nil(m.embed_bucket_tokens),
      select: {m.user_id, {m.embed_bucket_tokens, m.embed_bucket_at}}
    )
    |> repo.all()
    |> Map.new()
  end

  defp keys_created(repo, ids) do
    from(e in Event,
      where: e.event == "api_key_created" and e.user_id in ^ids,
      group_by: e.user_id,
      select: {e.user_id, count()}
    )
    |> repo.all()
    |> Map.new()
  end

  defp embed_cap_overrides(repo, ids, now) do
    from(o in UserLimitOverride,
      where: o.key == "embed_token_bucket" and o.user_id in ^ids,
      where: is_nil(o.expires_at) or o.expires_at > ^now,
      select: {o.user_id, fragment("?->'v'", o.value)}
    )
    |> repo.all()
    |> Map.new()
  end

  # `%{{user_id, date} => rollup}` for every day in [from, to) with activity.
  defp rollups(repo, from, to, live) do
    {from_at, to_at} = {midnight(from), midnight(to)}

    base =
      from(e in Event,
        where: e.inserted_at >= ^from_at and e.inserted_at < ^to_at and not is_nil(e.user_id)
      )

    days =
      from(e in base,
        group_by: [e.user_id, fragment("(? AT TIME ZONE 'UTC')::date", e.inserted_at)],
        select: {
          {e.user_id, fragment("(? AT TIME ZONE 'UTC')::date", e.inserted_at)},
          %{
            searches: filter(count(), e.event == "search_performed"),
            web_edited:
              fragment(
                "coalesce(bool_or(? = 'surface_active' AND ?->>'surface' = 'web' AND ?->>'client_type' = 'web'), false)",
                e.event,
                e.props,
                e.props
              )
          }
        }
      )
      |> repo.all()

    # A throttled mcp_tool_called carries every call since the last one; a
    # rollup carries the calls no later event picked up (Analytics.Folds).
    tools =
      from(e in base,
        where: e.event in ["mcp_tool_called", "mcp_tool_called_rollup"],
        group_by: [
          e.user_id,
          fragment("(? AT TIME ZONE 'UTC')::date", e.inserted_at),
          fragment("?->>'tool'", e.props)
        ],
        select: {
          {e.user_id, fragment("(? AT TIME ZONE 'UTC')::date", e.inserted_at)},
          fragment("?->>'tool'", e.props),
          type(sum(fragment("coalesce((?->>'calls')::bigint, 1)", e.props)), :integer)
        }
      )
      |> repo.all()
      |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})

    for {key, r} <- days, MapSet.member?(live, elem(key, 0)), into: %{} do
      {key, Map.put(r, :mcp_tool_calls, Map.new(Map.get(tools, key, [])))}
    end
  end

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp vault_rows(repo, ids, day, now) do
    notes =
      from(n in Note,
        where: n.vault_id in ^ids and is_nil(n.deleted_at) and n.kind == "note",
        group_by: n.vault_id,
        select: %{
          vault_id: n.vault_id,
          n: count(n.id),
          bytes: sum(fragment("octet_length(?)", n.content_ciphertext))
        }
      )

    # Derived folders and empty-folder markers alike.
    folders =
      from(n in Note,
        where: n.vault_id in ^ids and is_nil(n.deleted_at) and not is_nil(n.folder_hmac),
        group_by: n.vault_id,
        select: %{vault_id: n.vault_id, n: count(n.folder_hmac, :distinct)}
      )

    tag_rows =
      from(n in Note,
        where: n.vault_id in ^ids and is_nil(n.deleted_at) and n.kind == "note",
        select: %{vault_id: n.vault_id, tag: fragment("unnest(?)", n.tags_hmac)}
      )

    tags =
      from(t in subquery(tag_rows),
        group_by: t.vault_id,
        select: %{vault_id: t.vault_id, n: count(t.tag, :distinct)}
      )

    links =
      from(l in NoteLink,
        where: l.vault_id in ^ids,
        group_by: l.vault_id,
        select: %{vault_id: l.vault_id, n: count(l.id)}
      )

    attachments =
      from(a in Attachment,
        where: a.vault_id in ^ids and is_nil(a.deleted_at),
        group_by: a.vault_id,
        select: %{vault_id: a.vault_id, n: count(a.id), bytes: sum(a.size_bytes)}
      )

    from(v in Vault,
      left_join: nv in subquery(notes),
      on: nv.vault_id == v.id,
      left_join: fv in subquery(folders),
      on: fv.vault_id == v.id,
      left_join: tv in subquery(tags),
      on: tv.vault_id == v.id,
      left_join: lv in subquery(links),
      on: lv.vault_id == v.id,
      left_join: av in subquery(attachments),
      on: av.vault_id == v.id,
      where: v.id in ^ids,
      select: %{
        vault_id: v.id,
        user_id: v.user_id,
        vault_created_at: v.created_at,
        notes: type(coalesce(nv.n, 0), :integer),
        note_bytes: type(coalesce(nv.bytes, 0), :integer),
        attachments: type(coalesce(av.n, 0), :integer),
        attachment_bytes: type(coalesce(av.bytes, 0), :integer),
        folders: type(coalesce(fv.n, 0), :integer),
        links: type(coalesce(lv.n, 0), :integer),
        tags: type(coalesce(tv.n, 0), :integer)
      }
    )
    |> repo.all(timeout: @chunk_timeout)
    |> Enum.map(
      &Map.merge(&1, %{
        date: day,
        vault_created_at: usec(&1.vault_created_at),
        inserted_at: now,
        updated_at: now
      })
    )
  end
end
