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
end
