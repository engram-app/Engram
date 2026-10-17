defmodule Engram.Workers.CimdRefreshTest do
  @moduledoc """
  The sweep that makes `cimd_fetched_at` mean "last time we could read the
  vendor" rather than "last time a user clicked Connect" (#1642).
  """
  # async: false — the CIMD fetch rate limiter's ETS buckets are node-global,
  # and Mox expectations on the fetcher are set from the test process.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.Factory
  import Mox

  alias Engram.OAuth.Cimd.FetcherMock
  alias Engram.OAuth.Client
  alias Engram.Repo
  alias Engram.Workers.CimdRefresh

  require Logger

  setup :verify_on_exit!

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    :ok
  end

  @url "https://claude.ai/.well-known/oauth-client"

  defp document(overrides \\ %{}) do
    Map.merge(
      %{
        "client_id" => @url,
        "client_name" => "Claude Code",
        "redirect_uris" => ["http://127.0.0.1:9999/callback"]
      },
      overrides
    )
  end

  defp cimd_client(overrides) do
    insert(:oauth_client, Keyword.merge([kind: "mcp", cimd_url: @url], overrides))
  end

  defp reload(client), do: Repo.get!(Client, client.client_id, skip_tenant_check: true)

  defp aged(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  # The JWKS sweep only covers clients that made a token request recently: a
  # refresh token's `last_used_at` is that evidence.
  defp used(client, days_ago \\ 0, attrs \\ []) do
    insert(
      :oauth_refresh_token,
      Keyword.merge(
        [client_id: client.client_id, user_id: insert(:user).id, last_used_at: aged(days_ago)],
        attrs
      )
    )

    client
  end

  describe "perform/1" do
    # The whole point: nobody authorized, and the document still got re-read.
    test "refetches a row past its TTL" do
      client = cimd_client(cimd_fetched_at: aged(2))

      expect(FetcherMock, :fetch, fn @url -> {:ok, document()} end)

      assert {:ok, %{refreshed: 1}} = perform_job(CimdRefresh, %{})

      assert DateTime.compare(reload(client).cimd_fetched_at, client.cimd_fetched_at) == :gt
    end

    # Reuses `ensure_client/1`'s freshness check rather than reimplementing it,
    # so a row inside the TTL costs no outbound fetch. Mox is strict here: an
    # unexpected `fetch` call fails the test.
    test "leaves a fresh row alone" do
      cimd_client(cimd_fetched_at: DateTime.utc_now())

      assert {:ok, %{unchanged: 1}} = perform_job(CimdRefresh, %{})
    end

    # THE #1642 CLOSURE. A vendor drops `none` after a key compromise. Before
    # this sweep that narrowing landed only when somebody re-authorized, so a
    # client on a 90-day refresh token kept the widened permission
    # indefinitely. No authorize happens anywhere in this test.
    test "a vendor narrowing its permitted set lands without anyone re-authorizing" do
      client =
        cimd_client(
          cimd_fetched_at: aged(2),
          token_endpoint_auth_method: "none",
          token_endpoint_auth_methods_supported: ["none", "private_key_jwt"],
          jwks_uri: "https://claude.ai/oauth/jwks.json"
        )

      assert Client.public_auth_permitted?(client),
             "precondition: the cached row grants credential-free exchanges"

      narrowed =
        document(%{
          "token_endpoint_auth_method" => "private_key_jwt",
          "token_endpoint_auth_methods_supported" => ["private_key_jwt"],
          "token_endpoint_auth_signing_alg" => "RS256",
          "jwks_uri" => "https://claude.ai/oauth/jwks.json"
        })

      expect(FetcherMock, :fetch, fn @url -> {:ok, narrowed} end)

      assert {:ok, %{refreshed: 1}} = perform_job(CimdRefresh, %{})

      refute reload(client) |> Client.public_auth_permitted?(),
             "the narrowing must land: a credential is now required"
    end

    # Availability still beats freshness. An unreachable vendor keeps its
    # cached row instead of losing its connector, unchanged from before this
    # sweep existed.
    #
    # It counts as `unchanged`, NOT as an error, and that is the honest answer:
    # `Cimd.refresh/2` folds the failure into `{:ok, cached}`, so the moved (or
    # unmoved) timestamp is the only evidence this worker has. The failure
    # itself is carried by `mcp_cimd_stale_retained`, not by this tally.
    test "keeps the cached row when the vendor is unreachable" do
      client = cimd_client(cimd_fetched_at: aged(2))

      expect(FetcherMock, :fetch, fn @url -> {:error, :fetch_failed} end)

      assert {:ok, %{unchanged: 1}} = perform_job(CimdRefresh, %{})

      kept = reload(client)
      assert kept.cimd_fetched_at == client.cimd_fetched_at
      assert kept.cimd_url == @url
    end

    # DCR clients never published a document, so there is nothing to refresh
    # and no outbound fetch to make. Mox strictness is the assertion.
    test "ignores DCR clients" do
      insert(:oauth_client, kind: "mcp", cimd_url: nil)

      assert {:ok, tally} = perform_job(CimdRefresh, %{})
      assert tally == %{}
    end

    test "is a no-op with no CIMD clients at all" do
      assert {:ok, %{}} = perform_job(CimdRefresh, %{})
    end
  end

  # #1974: the token path must never block on the network once a key exists,
  # so the JWKS of every CIMD client is refetched in the background.
  describe "perform/1 with kind=jwks" do
    @jwks_uri "https://claude.ai/.well-known/jwks.json"

    test "refetches every distinct jwks_uri once and persists the result" do
      a = [jwks_uri: @jwks_uri] |> cimd_client() |> used()

      b =
        :oauth_client
        |> insert(kind: "mcp", cimd_url: "https://claude.ai/other", jwks_uri: @jwks_uri)
        |> used()

      [kind: "mcp", cimd_url: "https://claude.ai/third"]
      |> then(&insert(:oauth_client, &1))
      |> used()

      keys = [%{"kty" => "RSA", "kid" => "k1", "n" => "abc", "e" => "AQAB"}]
      expect(FetcherMock, :fetch, 1, fn @jwks_uri -> {:ok, %{"keys" => keys}} end)

      assert {:ok, %{refreshed: 1}} = perform_job(CimdRefresh, %{"kind" => "jwks"})

      for client <- [a, b] do
        assert reload(client).jwks_cached == %{"keys" => keys}
      end
    end

    test "CimdJwksRefresh runs the same sweep, with no sleep inside the job" do
      [jwks_uri: @jwks_uri] |> cimd_client() |> used()
      stub(FetcherMock, :fetch, fn @jwks_uri -> {:ok, %{"keys" => []}} end)

      # The spread lives in scheduled_at (CimdJwksSchedule), so Oban's exec
      # time is the fetch work alone. Three runs: a random in-job sleep would
      # pass one by luck.
      {us, results} =
        :timer.tc(fn ->
          for _ <- 1..3, do: perform_job(Engram.Workers.CimdJwksRefresh, %{})
        end)

      assert [{:ok, %{refreshed: 1}}, {:ok, _}, {:ok, _}] = results
      assert us < 1_000_000
    end

    # The cron entry: schedules the sweep 1-30 s out instead of sleeping, so
    # the spread is neither exec nor queue time on the dashboard.
    test "CimdJwksSchedule enqueues the sweep with a 1-30 s spread" do
      now = DateTime.utc_now()

      for _ <- 1..20, do: assert(:ok = perform_job(Engram.Workers.CimdJwksSchedule, %{}))

      jobs = all_enqueued(worker: Engram.Workers.CimdJwksRefresh, queue: :cimd_refresh)
      assert length(jobs) == 20

      delays = Enum.map(jobs, &DateTime.diff(&1.scheduled_at, now, :second))
      assert Enum.all?(delays, &(&1 in 0..31))
      assert length(Enum.uniq(delays)) > 1, "no spread: every sweep lands on the cron tick"
    end

    test "a failing vendor keeps its last good keys" do
      keys = [%{"kty" => "RSA", "kid" => "k1"}]

      client =
        cimd_client(
          jwks_uri: @jwks_uri,
          jwks_cached: %{"keys" => keys},
          jwks_fetched_at: aged(1)
        )
        |> used()

      expect(FetcherMock, :fetch, fn @jwks_uri -> {:error, {:http_status, 503}} end)

      assert {:ok, %{failed: 1}} = perform_job(CimdRefresh, %{"kind" => "jwks"})
      assert reload(client).jwks_cached == %{"keys" => keys}
    end

    # Review of #1974: a client nobody has used is not worth a vendor fetch
    # every 5 min. The token path still fetches on demand if one comes back.
    test "skips clients idle for 30 days and clients never used" do
      [jwks_uri: "https://a.example/jwks.json"] |> cimd_client() |> used(1)

      :oauth_client
      |> insert(
        kind: "mcp",
        cimd_url: "https://b.example/c",
        jwks_uri: "https://b.example/jwks.json"
      )
      |> used(31)

      insert(:oauth_client,
        kind: "mcp",
        cimd_url: "https://c.example/c",
        jwks_uri: "https://c.example/jwks.json"
      )

      expect(FetcherMock, :fetch, 1, fn "https://a.example/jwks.json" ->
        {:ok, %{"keys" => []}}
      end)

      assert {:ok, %{refreshed: 1}} = perform_job(CimdRefresh, %{"kind" => "jwks"})
    end

    # Second review #10: one vendor's crash is that vendor's failure, not the
    # sweep's. The rest still refresh and the sweep line still logs.
    test "a crash fetching one URI is tallied as failed and the sweep continues" do
      for i <- 1..3 do
        :oauth_client
        |> insert(
          kind: "mcp",
          cimd_url: "https://c#{i}.example/c",
          jwks_uri: "https://c#{i}.example/jwks.json"
        )
        |> used()
      end

      expect(FetcherMock, :fetch, 3, fn
        "https://c2.example/jwks.json" -> raise "boom"
        _uri -> {:ok, %{"keys" => []}}
      end)

      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{refreshed: 2, failed: 1}} = perform_job(CimdRefresh, %{"kind" => "jwks"})
        end)

      assert log =~ "mcp_jwks_refresh_sweep"
    end

    # A disconnected grant is not a client anyone is using.
    test "skips a client whose only recent token is revoked" do
      [jwks_uri: "https://live.example/jwks.json"] |> cimd_client() |> used(1)

      :oauth_client
      |> insert(
        kind: "mcp",
        cimd_url: "https://gone.example/c",
        jwks_uri: "https://gone.example/jwks.json"
      )
      |> used(1, revoked_at: DateTime.utc_now(:second))

      expect(FetcherMock, :fetch, 1, fn "https://live.example/jwks.json" ->
        {:ok, %{"keys" => []}}
      end)

      assert {:ok, %{refreshed: 1}} = perform_job(CimdRefresh, %{"kind" => "jwks"})
    end

    test "runs at most 4 vendor fetches at once" do
      for i <- 1..8 do
        :oauth_client
        |> insert(
          kind: "mcp",
          cimd_url: "https://v#{i}.example/c",
          jwks_uri: "https://v#{i}.example/jwks.json"
        )
        |> used()
      end

      {:ok, gauge} = Agent.start_link(fn -> {0, 0} end)

      expect(FetcherMock, :fetch, 8, fn _uri ->
        Agent.update(gauge, fn {now, peak} -> {now + 1, max(peak, now + 1)} end)
        Process.sleep(50)
        Agent.update(gauge, fn {now, peak} -> {now - 1, peak} end)
        {:ok, %{"keys" => []}}
      end)

      assert {:ok, %{refreshed: 8}} = perform_job(CimdRefresh, %{"kind" => "jwks"})
      {_, peak} = Agent.get(gauge, & &1)
      assert peak in 2..4
    end
  end
end
