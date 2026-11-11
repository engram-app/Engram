defmodule Engram.Workers.CimdRefresh do
  @moduledoc """
  Daily refresh of the stored CIMD client document, and (`kind: "jwks"`, every
  5 min) of the JWKS of every RECENTLY USED client. See `perform/1`.

  Live grant = at least one refresh token that is unrevoked and unexpired,
  whenever it was last used (`live_grant_client_ids/2`, the one subquery both sweeps use). A dormant
  grant must keep its document fresh: the refresh-token exchange never calls
  `ensure_client/1` and trusts the stored row (#1642). The JWKS sweep layers a
  30-day `last_used_at` rule on top, because a dormant client's JWKS is
  fetched on demand in the token path.

  The DOCUMENT sweep refreshes a client unless it is demonstrably DEAD: no
  live grant AND `cimd_fetched_at` older than `dead_after_days/0`. A healthy
  vendor nobody has connected yet keeps its daily early-warning refresh. Only
  a host unreachable for a week with no grant stops being retried (it would
  otherwise log four failure lines a day forever and trip the
  connector-refused alert). `cimd_fetched_at` only moves on a successful
  fetch, and NULL (never fetched) counts as not dead. A document exactly
  `dead_after_days/0` old by the time the sweep runs is dead.

  Skipped = dead. Nothing deletes or updates `oauth_clients` here; the sweep
  only stops REFETCHING. A skipped client refreshes on demand: the authorize
  path calls `Cimd.ensure_client/1`.

  `total=` in the sweep log lines counts the clients swept, not every stored
  CIMD client.

  `Engram.OAuth.Cimd.ensure_client/1` is called from exactly one place,
  `Engram.OAuth.fetch_client/1`, which only the authorize path reaches. So
  `cimd_fetched_at` measured time since a user last ran the interactive flow,
  NOT whether the vendor was reachable. A client living on 90-day refresh
  tokens could hold a document we last read months ago, and nothing would
  retry.

  That became a correctness problem once the row began carrying
  `token_endpoint_auth_methods_supported`, because the row then decides whether
  a credential is required at all. A vendor TIGHTENING its document — dropping
  `none` after a key compromise — could not land that change until somebody
  happened to re-authorize (#1642).

  This sweep makes the clock mean what it says. It calls the SAME
  `ensure_client/1` the authorize path calls, so a row inside its TTL (the document's clamped `max-age`, 5 min to 24h) is a
  no-op and anything older is refetched, validated and stored through one code
  path. Deliberately no second fetch implementation: a private one here would
  be free to drift from the validation the authorize path applies, which is the
  2026-08-04 mistake in a new place.

  What this does NOT change: a vendor that is unreachable still keeps its
  cached row. Availability still beats freshness (`Cimd.refresh/2`), because a
  five-minute vendor outage must not lock out its users. The difference is that
  we now retry daily instead of never.

  ## What the tally counts

  `Cimd.refresh/2` folds a failed refetch into a served cached row on purpose
  (availability beats freshness), which is why `ensure_client/1` alone cannot
  tell this worker whether anything was re-read. The sweep therefore calls
  `Cimd.ensure_client_status/1`, the same single fetch path with the outcome
  kept, and tallies it:

    * `fresh`: inside its TTL, nothing fetched (the common case)
    * `refreshed`: fetched, validated and stored
    * `stale_retained`: past its TTL, the refetch failed (unreachable host,
      invalid document, or refused by our own fetch limiter), cached row kept
    * any other key: the error reason (`ensure_client_status/1` returned
      `{:error, reason}`)

  A failed fetch also logs `mcp_cimd_stale_retained` from `Cimd.refresh/2`
  (the limiter refusal logs nothing by design, and is visible as
  `engram_prom_ex_rate_limiter_hit_total{purpose="cimd_fetch",result="deny"}`,
  which the `engram-prod-cimd-fetch-rate-limited` alert watches).

  ## No staleness ceiling here

  A ceiling that revokes permissions past some staleness threshold is
  deliberately NOT part of this. It was tried and reverted on 2026-09-16:
  stripping `none` from a stale row hands a terminal `invalid_client` to any
  client that exchanges publicly, and ChatGPT does exactly that while also
  publishing `private_key_jwt`. Read the #1642 discussion before adding one.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query
  import Engram.Repo.Utc, only: [utc_wall: 1]

  alias Engram.Logger.Metadata
  alias Engram.OAuth.Cimd
  alias Engram.OAuth.Cimd.JwksCache
  alias Engram.OAuth.Client
  alias Engram.OAuth.RefreshToken
  alias Engram.Repo

  require Logger

  # The JWKS sweep: vendor fetches in flight at once and the per-fetch ceiling
  # (the fetcher's own 3 s budget plus DNS and the persist).
  @jwks_concurrency 4
  @jwks_fetch_timeout_ms 15_000

  # Defaults for the two tunables below, read through `active_days/0` and
  # `dead_after_days/0` (the repo's `Application.get_env` convention for worker
  # knobs, `:cimd_active_days` / `:cimd_dead_after_days`).
  @default_active_days 30
  @default_dead_after_days 7

  @doc "How recently a client must have made a token request to get its JWKS swept."
  @spec active_days() :: pos_integer()
  def active_days, do: Application.get_env(:engram, :cimd_active_days, @default_active_days)

  @doc """
  Document sweep: a client with no live grant whose last good fetch is older
  than this many days is dead and no longer retried daily.
  """
  @spec dead_after_days() :: pos_integer()
  def dead_after_days,
    do: Application.get_env(:engram, :cimd_dead_after_days, @default_dead_after_days)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "jwks"}}) do
    uris = jwks_uris()

    # `_nolink` under the app's Task.Supervisor: one vendor's crash is a
    # `{:exit, _}` tallied as failed, not the sweep's death (second review
    # #10).
    tally =
      Engram.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(uris, &refresh_jwks/1,
        max_concurrency: @jwks_concurrency,
        ordered: false,
        timeout: @jwks_fetch_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, outcome}, acc -> Map.update(acc, outcome, 1, &(&1 + 1))
        {:exit, _reason}, acc -> Map.update(acc, :failed, 1, &(&1 + 1))
      end)

    log_sweep("mcp_jwks_refresh_sweep", length(uris), tally)

    {:ok, tally}
  end

  def perform(%Oban.Job{}) do
    rows = sweep_urls(DateTime.utc_now())
    tally = Enum.reduce(rows, %{}, &tally_refresh/2)

    log_sweep("mcp_cimd_refresh_sweep", length(rows), tally)

    {:ok, tally}
  end

  # `skip_tenant_check: true` for the same reason every other read in
  # `Engram.OAuth.Cimd` carries it: an OAuth client is not tenant-scoped, and
  # this sweep runs with no user in context at all.
  @doc false
  # The document sweep's client URLs as of `now`; public only so a test can pin
  # `now` and probe the dead-client boundary to the second.
  @spec sweep_urls(DateTime.t()) :: [String.t()]
  def sweep_urls(now) do
    Repo.all(
      from(c in cimd_clients(),
        where:
          c.client_id in subquery(live_grant_client_ids(now)) or is_nil(c.cimd_fetched_at) or
            c.cimd_fetched_at > ^days_ago(now, dead_after_days()),
        select: c.cimd_url
      ),
      skip_tenant_check: true
    )
  end

  defp cimd_clients, do: from(c in Client, where: not is_nil(c.cimd_url))

  # The one definition of "has a live grant", used by both sweeps: the ids of
  # clients with a refresh token (any user) that is unrevoked and unexpired.
  # With `last_used_after`, that token must also have been used since then. An
  # IN subquery (not EXISTS) because the document sweep ORs it with the
  # not-dead rule. A small, once-a-day semi-join over `oauth_refresh_tokens`
  # (~7k rows); the JWKS sweep reaches it every 5 min over the same rows.

  defp live_grant_client_ids(now, last_used_after \\ nil) do
    live =
      from(rt in RefreshToken,
        where: is_nil(rt.revoked_at) and rt.expires_at > ^now,
        select: rt.client_id
      )

    if last_used_after, do: where(live, [rt], rt.last_used_at > ^last_used_after), else: live
  end

  defp days_ago(now, days), do: DateTime.add(now, -days * 86_400, :second)

  # Recently used clients only (live grant used in the last `active_days/0`),
  # most recently used first, so a burst of registrations that never connect,
  # or grants since disconnected, cost no vendor fetches. One that comes back fetches on demand in the token
  # path. Clients sharing a jwks_uri collapse to one URI, ordered by its most
  # recent use.
  defp jwks_uris do
    now = DateTime.utc_now()

    from(c in cimd_clients(),
      where:
        c.client_id in subquery(live_grant_client_ids(now, days_ago(now, active_days()))) and
          not is_nil(c.jwks_uri),
      select: {
        c.jwks_uri,
        # `utc_wall`: Ecto casts this to `timestamp`, which would read a
        # `timestamptz` through the session TimeZone (`Engram.Repo.Utc`).
        type(
          utc_wall(
            fragment(
              "(SELECT max(r.last_used_at) FROM oauth_refresh_tokens r WHERE r.client_id = ? AND r.revoked_at IS NULL)",
              c.client_id
            )
          ),
          :utc_datetime_usec
        )
      }
    )
    |> Repo.all(skip_tenant_check: true)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {uri, used_at} -> {uri, Enum.max(used_at, DateTime)} end)
    |> Enum.sort_by(&elem(&1, 1), {:desc, DateTime})
    |> Enum.map(&elem(&1, 0))
  end

  defp refresh_jwks(uri) do
    case JwksCache.refresh_background(uri) do
      {:ok, _keys} -> :refreshed
      {:error, _reason} -> :failed
    end
  end

  defp tally_refresh(url, acc) do
    outcome =
      case Cimd.ensure_client_status(url) do
        {status, %Client{}} -> status
        {:error, reason} -> reason
      end

    Map.update(acc, outcome, 1, &(&1 + 1))
  end

  # One line per sweep. Stays at `:info`: `stale_retained` is already logged
  # per client by `Cimd.refresh/2`, and a routine all-fresh sweep is not news.
  defp log_sweep(event, total, tally) do
    Logger.info(
      "#{event} total=#{total} #{format_tally(tally)}",
      Metadata.with_category(:info, :lifecycle)
    )
  end

  defp format_tally(tally) do
    tally
    |> Enum.map(fn {outcome, count} -> "#{outcome}=#{count}" end)
    |> Enum.sort()
    |> Enum.join(" ")
  end
end
