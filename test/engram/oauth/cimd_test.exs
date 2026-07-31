defmodule Engram.OAuth.CimdTest do
  # async: false — these tests flip the node-global :cimd_enabled flag, and Mox
  # expectations on the fetcher are set from the test process.
  use Engram.DataCase, async: false

  import Mox

  alias Engram.OAuth
  alias Engram.OAuth.Cimd
  alias Engram.OAuth.Cimd.FetcherMock
  alias Engram.OAuth.Client
  alias Engram.Repo

  setup :verify_on_exit!

  # The fetch rate limiter is real and its ETS buckets are node-global, so
  # without this the eleventh fetch in this module is denied and every later test
  # fails with :rate_limited rather than what it was actually asserting. Found the
  # honest way: by writing the tests and watching exactly ten of them pass.
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

  defp with_cimd(enabled) do
    previous = Application.get_env(:engram, :cimd_enabled)
    Application.put_env(:engram, :cimd_enabled, enabled)
    on_exit(fn -> Application.put_env(:engram, :cimd_enabled, previous) end)
  end

  describe "url_shaped?/1" do
    test "only https URLs are CIMD-shaped" do
      assert Cimd.url_shaped?("https://claude.ai/x")
      refute Cimd.url_shaped?("http://claude.ai/x")
      refute Cimd.url_shaped?(Ecto.UUID.generate())
      refute Cimd.url_shaped?("garbage")
      refute Cimd.url_shaped?(nil)
    end
  end

  describe "ensure_client/1 gating" do
    test "refuses to resolve anything while the flag is off" do
      with_cimd(false)
      assert {:error, :cimd_disabled} = Cimd.ensure_client(@url)
    end

    test "refuses a non-URL client_id" do
      with_cimd(true)
      assert {:error, :not_cimd} = Cimd.ensure_client(Ecto.UUID.generate())
    end
  end

  describe "ensure_client/1 first contact" do
    setup do
      with_cimd(true)
      :ok
    end

    test "fetches the document and stores a client whose wire id is the URL" do
      expect(FetcherMock, :fetch, fn @url -> {:ok, document()} end)

      assert {:ok, %Client{} = client} = Cimd.ensure_client(@url)
      assert client.cimd_url == @url
      assert client.client_name == "Claude Code"
      assert client.redirect_uris == ["http://127.0.0.1:9999/callback"]
      assert %DateTime{} = client.cimd_fetched_at
      # The internal identity stays a UUID: widening the primary key would drag
      # in both the authorization-code and refresh-token tables for nothing.
      assert {:ok, _} = Ecto.UUID.cast(client.client_id)
    end

    # THE binding. Without it a vendor could serve a document claiming any
    # client_id, and any host with an open redirect could serve someone else's.
    test "rejects a document whose client_id is not the URL it was served from" do
      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"client_id" => "https://claude.ai/some-other-client"})}
      end)

      assert {:error, :client_id_mismatch} = Cimd.ensure_client(@url)
      assert Repo.aggregate(Client, :count) == 0
    end

    test "rejects a document with no client_id at all" do
      expect(FetcherMock, :fetch, fn @url -> {:ok, Map.delete(document(), "client_id")} end)
      assert {:error, :client_id_mismatch} = Cimd.ensure_client(@url)
    end

    test "rejects a document with no usable redirect_uris" do
      for uris <- [nil, [], "https://x/cb", [123]] do
        expect(FetcherMock, :fetch, fn @url -> {:ok, document(%{"redirect_uris" => uris})} end)

        assert {:error, :missing_redirect_uris} = Cimd.ensure_client(@url),
               "expected #{inspect(uris)} to be refused"
      end
    end

    # A CIMD client never registered, so no secret was ever minted for it.
    # Honouring the request would leave it unable to authenticate (nil hash);
    # silently downgrading would make it send a secret we must then reject for
    # being present at all. Both failures are opaque, so refuse the document.
    test "rejects a document asking for a confidential auth method" do
      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"token_endpoint_auth_method" => "client_secret_post"})}
      end)

      assert {:error, :confidential_not_supported} = Cimd.ensure_client(@url)
    end

    test "stores a public client with no secret even so" do
      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"token_endpoint_auth_method" => "none"})}
      end)

      assert {:ok, client} = Cimd.ensure_client(@url)
      assert client.token_endpoint_auth_method == "none"
      assert is_nil(client.client_secret_hash)
    end

    # The document goes through the same redirect-URI validation as a DCR body:
    # a CIMD-specific validation path would be a second copy of those rules, free
    # to drift from the ones PR #1147 hardened.
    test "applies DCR redirect-URI validation to the document" do
      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"redirect_uris" => ["javascript:alert(1)"]})}
      end)

      assert {:error, :invalid_document} = Cimd.ensure_client(@url)
    end

    test "propagates a transport error without storing anything" do
      expect(FetcherMock, :fetch, fn @url -> {:error, {:http_status, 404}} end)
      assert {:error, {:http_status, 404}} = Cimd.ensure_client(@url)
      assert Repo.aggregate(Client, :count) == 0
    end

    test "a software_id in the document is not stored" do
      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"software_id" => "anthropic-claude-desktop"})}
      end)

      assert {:ok, client} = Cimd.ensure_client(@url)
      assert is_nil(client.software_id)
    end
  end

  describe "ensure_client/1 caching" do
    setup do
      with_cimd(true)
      :ok
    end

    test "a fresh row is served without refetching" do
      expect(FetcherMock, :fetch, 1, fn @url -> {:ok, document()} end)

      assert {:ok, first} = Cimd.ensure_client(@url)
      assert {:ok, second} = Cimd.ensure_client(@url)
      assert first.client_id == second.client_id
    end

    test "a stale row is refetched and updated in place" do
      expect(FetcherMock, :fetch, fn @url -> {:ok, document()} end)
      assert {:ok, client} = Cimd.ensure_client(@url)

      expire(client)

      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"redirect_uris" => ["http://127.0.0.1:1234/cb"]})}
      end)

      assert {:ok, refreshed} = Cimd.ensure_client(@url)
      assert refreshed.client_id == client.client_id, "must update in place, not fork a row"
      assert refreshed.redirect_uris == ["http://127.0.0.1:1234/cb"]
      assert Repo.aggregate(Client, :count) == 1
    end

    # A vendor being briefly unreachable must not lock out every user of that
    # client. A document fetched yesterday is far better evidence than none.
    test "a failed refresh keeps serving the stale row" do
      expect(FetcherMock, :fetch, fn @url -> {:ok, document()} end)
      assert {:ok, client} = Cimd.ensure_client(@url)
      expire(client)

      expect(FetcherMock, :fetch, fn @url -> {:error, :fetch_failed} end)

      assert {:ok, stale} = Cimd.ensure_client(@url)
      assert stale.client_id == client.client_id
      assert stale.redirect_uris == client.redirect_uris
    end

    # A rejected refresh is still a failed refresh: a vendor that starts serving
    # a broken document must not invalidate a grant that already works.
    test "a refresh whose document no longer validates keeps the stale row" do
      expect(FetcherMock, :fetch, fn @url -> {:ok, document()} end)
      assert {:ok, client} = Cimd.ensure_client(@url)
      expire(client)

      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"client_id" => "https://evil.example/x"})}
      end)

      assert {:ok, stale} = Cimd.ensure_client(@url)
      assert stale.client_id == client.client_id
    end

    defp expire(client) do
      client
      |> Ecto.Changeset.change(%{
        cimd_fetched_at: DateTime.add(DateTime.utc_now(), -25 * 3600, :second)
      })
      |> Repo.update!(skip_tenant_check: true)
    end
  end

  # This is an unauthenticated-request-triggered outbound fetch, so it is a
  # traffic amplifier pointed at third parties, not merely a load risk for us.
  describe "rate limiting" do
    setup do
      with_cimd(true)
      :ok
    end

    test "stops fetching the same host once the per-host budget is spent" do
      stub(FetcherMock, :fetch, fn url -> {:ok, %{document() | "client_id" => url}} end)

      # 10/min per host. Distinct paths so each is a distinct first contact
      # rather than a cache hit.
      results =
        for index <- 1..12 do
          Cimd.ensure_client("https://claude.ai/client-#{index}")
        end

      assert Enum.count(results, &match?({:ok, _}, &1)) == 10
      assert Enum.count(results, &(&1 == {:error, :rate_limited})) == 2
    end

    # THE reason discovery and refresh have separate budgets. If they shared one,
    # an attacker cycling hosts would consume it and every legitimate refresh would
    # be stuck serving a stale document — the anti-amplification control turned
    # into a denial-of-service vector against the vendors we actually serve.
    test "a saturated discovery budget does not starve a refresh of a known client" do
      stub(FetcherMock, :fetch, fn url -> {:ok, %{document() | "client_id" => url}} end)

      assert {:ok, client} = Cimd.ensure_client(@url)
      expire(client)

      # Burn the whole discovery budget on hosts nobody is connected to.
      for index <- 1..70 do
        Cimd.ensure_client("https://attacker-#{index}.example/client")
      end

      # The known client is stale, so this is a refresh, and it must still go out
      # rather than silently degrading to the retained stale row.
      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"redirect_uris" => ["http://127.0.0.1:4321/cb"]})}
      end)

      assert {:ok, refreshed} = Cimd.ensure_client(@url)

      assert refreshed.redirect_uris == ["http://127.0.0.1:4321/cb"],
             "refresh was starved by discovery traffic — the buckets are shared again"
    end

    # A per-host bucket alone is useless against an attacker who varies the host,
    # which is exactly the amplification case, so a global bucket has to exist too.
    test "a global budget bounds fetches across all hosts" do
      stub(FetcherMock, :fetch, fn url -> {:ok, %{document() | "client_id" => url}} end)

      results =
        for index <- 1..70 do
          Cimd.ensure_client("https://vendor-#{index}.example/client")
        end

      assert Enum.any?(results, &(&1 == {:error, :rate_limited})),
             "a global cap must bound total outbound fetches, not just per-host ones"

      assert Enum.count(results, &match?({:ok, _}, &1)) <= 60
    end
  end

  describe "get_by_url/1" do
    test "never reaches the network" do
      with_cimd(true)
      # No expectation set: a fetch here would fail verify_on_exit!.
      assert {:error, :not_found} = Cimd.get_by_url(@url)
      assert {:error, :not_found} = Cimd.get_by_url(nil)
    end
  end

  # The seam the ticket flagged as the real cost: the wire client_id is a URL,
  # but every table downstream stores the internal UUID.
  describe "the wire client_id round-trip" do
    setup do
      with_cimd(true)
      expect(FetcherMock, :fetch, fn @url -> {:ok, document()} end)
      {:ok, client} = Cimd.ensure_client(@url)
      %{client: client}
    end

    test "get_client/1 resolves the URL to the same row as the UUID", %{client: client} do
      assert {:ok, by_url} = OAuth.get_client(@url)
      assert {:ok, by_uuid} = OAuth.get_client(client.client_id)
      assert by_url.client_id == by_uuid.client_id
    end

    test "get_client/1 does not treat an unknown URL as a client" do
      assert {:error, :not_found} = OAuth.get_client("https://unknown.example/client")
    end

    test "authenticate_client/2 accepts the URL for a public client" do
      assert :ok = OAuth.authenticate_client(@url, nil)
      assert {:error, :invalid_client} = OAuth.authenticate_client(@url, "some-secret")
    end

    test "a token exchange presenting the URL as client_id succeeds", %{client: client} do
      user = insert_user()
      vault = insert(:vault, user: user)
      verifier = "verifier-that-is-long-enough-to-be-plausible"
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
      redirect_uri = "http://127.0.0.1:9999/callback"

      validated = %{
        client: client,
        client_id: client.client_id,
        client_name: client.client_name,
        redirect_uri: redirect_uri,
        code_challenge: challenge,
        code_challenge_method: "S256",
        scope: "mcp",
        state: nil
      }

      assert {:ok, redirect} =
               OAuth.mint_authorization_code(user, validated, "vault:#{vault.id}")

      code = redirect |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("code")

      # The wire client_id here is the URL; the code row holds the UUID. If the
      # comparison were a bare ==, this is where the legitimate client would be
      # rejected with invalid_grant.
      assert {:ok, tokens} =
               OAuth.exchange_authorization_code(%{
                 "code" => code,
                 "client_id" => @url,
                 "redirect_uri" => redirect_uri,
                 "code_verifier" => verifier
               })

      assert is_binary(tokens.refresh_token)

      # Same seam again on rotation.
      assert {:ok, rotated} = OAuth.rotate_refresh_token(tokens.refresh_token, @url)
      assert is_binary(rotated.refresh_token)

      # And on revocation, which must actually revoke rather than silently no-op.
      assert :ok = OAuth.revoke_token(rotated.refresh_token, @url, nil)
      assert {:error, :invalid_grant} = OAuth.rotate_refresh_token(rotated.refresh_token, @url)
    end

    test "another client's URL cannot redeem this client's code", %{client: client} do
      user = insert_user()
      vault = insert(:vault, user: user)
      verifier = "another-verifier-long-enough-to-pass"
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
      redirect_uri = "http://127.0.0.1:9999/callback"

      other = insert(:oauth_client, cimd_url: "https://evil.example/client")

      validated = %{
        client: client,
        client_id: client.client_id,
        client_name: client.client_name,
        redirect_uri: redirect_uri,
        code_challenge: challenge,
        code_challenge_method: "S256",
        scope: "mcp",
        state: nil
      }

      {:ok, redirect} = OAuth.mint_authorization_code(user, validated, "vault:#{vault.id}")
      code = redirect |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("code")

      assert {:error, :invalid_grant} =
               OAuth.exchange_authorization_code(%{
                 "code" => code,
                 "client_id" => other.cimd_url,
                 "redirect_uri" => redirect_uri,
                 "code_verifier" => verifier
               })
    end
  end
end
