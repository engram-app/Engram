defmodule Engram.Workers.CimdRefresh do
  @moduledoc """
  Daily refresh of every stored CIMD client document.

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
  `ensure_client/1` the authorize path calls, so a row inside its 24h TTL is a
  no-op and anything older is refetched, validated and stored through one code
  path. Deliberately no second fetch implementation: a private one here would
  be free to drift from the validation the authorize path applies, which is the
  2026-08-04 mistake in a new place.

  What this does NOT change: a vendor that is unreachable still keeps its
  cached row. Availability still beats freshness (`Cimd.refresh/2`), because a
  five-minute vendor outage must not lock out its users. The difference is that
  we now retry daily instead of never.

  ## Why the tally counts timestamps rather than return values

  `Cimd.refresh/2` folds every fetch failure into `{:ok, cached_client}` on
  purpose, so `ensure_client/1` cannot tell this worker whether anything was
  actually re-read. Counting its `:ok`s would report a fully successful sweep
  while every vendor was unreachable. `cimd_fetched_at` moving is the only
  honest evidence a document was refreshed, so that is what gets counted.

  `unchanged` therefore covers two different facts that this worker cannot
  separate without duplicating the TTL: a row still inside its TTL (normal, the
  common case) and a row past it whose refetch failed. Both already have their
  own signal, which is why no third one is invented here:

    * a failed fetch logs `mcp_cimd_stale_retained` from `Cimd.refresh/2`
    * a refetch refused by our own fetch limiter logs NOTHING by design
      (unbounded volume behind a bounded refusal), and is instead visible as
      `engram_prom_ex_rate_limiter_hit_total{purpose="cimd_fetch",result="deny"}`,
      which the `engram-prod-cimd-fetch-rate-limited` alert watches

  ## No staleness ceiling here

  A ceiling that revokes permissions past some staleness threshold is
  deliberately NOT part of this. It was tried and reverted on 2026-09-16:
  stripping `none` from a stale row hands a terminal `invalid_client` to any
  client that exchanges publicly, and ChatGPT does exactly that while also
  publishing `private_key_jwt`. Read the #1642 discussion before adding one.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Engram.Logger.Metadata
  alias Engram.OAuth.Cimd
  alias Engram.OAuth.Client
  alias Engram.Repo

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    rows = cimd_rows()
    tally = Enum.reduce(rows, %{}, &tally_refresh/2)

    log_sweep(length(rows), tally)

    {:ok, tally}
  end

  # `skip_tenant_check: true` for the same reason every other read in
  # `Engram.OAuth.Cimd` carries it: an OAuth client is not tenant-scoped, and
  # this sweep runs with no user in context at all.
  defp cimd_rows do
    Repo.all(
      from(c in Client,
        where: not is_nil(c.cimd_url),
        select: {c.cimd_url, c.cimd_fetched_at}
      ),
      skip_tenant_check: true
    )
  end

  defp tally_refresh({url, before_at}, acc) do
    outcome =
      case Cimd.ensure_client(url) do
        {:ok, %Client{cimd_fetched_at: after_at}} -> refreshed?(before_at, after_at)
        {:error, reason} -> reason
      end

    Map.update(acc, outcome, 1, &(&1 + 1))
  end

  defp refreshed?(nil, %DateTime{}), do: :refreshed
  defp refreshed?(%DateTime{}, nil), do: :unchanged
  defp refreshed?(nil, nil), do: :unchanged

  defp refreshed?(%DateTime{} = before_at, %DateTime{} = after_at) do
    if DateTime.compare(after_at, before_at) == :gt, do: :refreshed, else: :unchanged
  end

  # One line per sweep. Stays at `:info`: with failures folded into `unchanged`
  # this worker has nothing to escalate that its two existing signals do not
  # already carry, and a routine all-fresh sweep is not news.
  defp log_sweep(total, tally) do
    Logger.info(
      "mcp_cimd_refresh_sweep total=#{total} #{format_tally(tally)}",
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
