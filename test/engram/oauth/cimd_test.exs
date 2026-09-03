defmodule Engram.OAuth.CimdTest do
  # async: false — the CIMD fetch rate limiter's ETS buckets are node-global, and
  # Mox expectations on the fetcher are set from the test process.
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

  defp authorize(url) do
    Engram.OAuth.validate_authorization_request(%{
      "client_id" => url,
      "redirect_uri" => "http://127.0.0.1:9999/callback",
      "response_type" => "code",
      "code_challenge" => "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
      "code_challenge_method" => "S256"
    })
  end

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
    # The `https://` prefix is the only discriminator, so a DCR uuid (or any
    # garbage) must never be sent down the fetch path.
    test "refuses anything that is not a URL-shaped client_id" do
      assert {:error, :not_cimd} = Cimd.ensure_client(Ecto.UUID.generate())
      assert {:error, :not_cimd} = Cimd.ensure_client("http://claude.ai/insecure")
      assert {:error, :not_cimd} = Cimd.ensure_client("garbage")
      assert {:error, :not_cimd} = Cimd.ensure_client(nil)
    end
  end

  describe "ensure_client/1 first contact" do
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

    # MCP 2025-11-25 lists client_id, client_name and redirect_uris as the three
    # properties a metadata document MUST carry. We enforced two.
    #
    # Refusing here rather than negotiating is a deliberate line: an unknown
    # grant_type costs nothing to ignore, but a nameless client cannot be
    # rendered on the consent screen, and "Authorize this app" is a worse
    # outcome for the user than a legible refusal.
    test "rejects a document with no usable client_name" do
      for name <- [nil, "", "   ", 42] do
        expect(FetcherMock, :fetch, fn @url -> {:ok, document(%{"client_name" => name})} end)

        assert {:error, :missing_client_name} = Cimd.ensure_client(@url),
               "expected #{inspect(name)} to be refused"
      end

      assert Repo.aggregate(Client, :count) == 0
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
    #
    # Safety rules stay shared. What must NOT be shared is DCR's *registration
    # policy* — see the "negotiated, not enforced" tests below.
    test "applies DCR redirect-URI validation to the document" do
      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"redirect_uris" => ["javascript:alert(1)"]})}
      end)

      assert {:error, {:invalid_document, _errors}} = Cimd.ensure_client(@url)
    end
  end

  # A published CIMD document describes what its vendor's client can do, against
  # every authorization server in the world. It is not a registration request
  # asking our permission. RFC 7591 §3.2.1 has the AS record what it supports and
  # report back what it granted; the CIMD draft asks for structural validation
  # plus the self-referential binding. Neither licenses "reject the client because
  # it also declares a grant you don't implement".
  #
  # Regression for the 2026-08-04 prod incident: Claude connect died on
  # `invalid_client` because DCR's registration policy was being applied to a
  # fetched vendor document.
  # WHY THIS EXISTS, and why it is verbatim.
  #
  # `document/1` above is a three-key fixture — client_id, client_name,
  # redirect_uris. Those happen to be exactly the three fields
  # `registration_changeset/2` was never going to reject, so every CIMD test
  # written against it passed no matter how strict the changeset became. The
  # subset allowlists, the size caps and the https-only rules all sat on fields
  # no test ever populated. The fixture was named after a real client and shaped
  # like our own validator, which is how #1167 shipped green and took out every
  # Claude connect on contact with a real one.
  #
  # So this one is copied byte-for-byte from what claude.ai actually serves, and
  # it is the shape of the regression test this class needs: not "does our
  # validator accept what our validator expects", but "does it accept what is
  # actually on the wire". If Anthropic changes the document and this starts
  # failing, that is the test doing its job — re-fetch it, don't edit it to fit.
  describe "the real published Claude Code document" do
    # curl https://claude.ai/oauth/claude-code-client-metadata  (2026-08-04)
    @claude_code_url "https://claude.ai/oauth/claude-code-client-metadata"
    @claude_code_document %{
      "client_id" => "https://claude.ai/oauth/claude-code-client-metadata",
      "client_name" => "Claude Code",
      "client_uri" => "https://claude.ai",
      "redirect_uris" => ["http://localhost/callback", "http://127.0.0.1/callback"],
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none"
    }

    test "is accepted as published" do
      expect(FetcherMock, :fetch, fn @claude_code_url -> {:ok, @claude_code_document} end)

      assert {:ok, client} = Cimd.ensure_client(@claude_code_url)
      assert client.client_name == "Claude Code"
      assert client.token_endpoint_auth_method == "none"
    end

    # The document declares its loopback redirects WITHOUT a port; the client
    # binds an ephemeral one at runtime (RFC 8252 §7.3). If the port exemption
    # ever regressed, CIMD clients would authorize once and fail forever after,
    # which no unit test of `match_redirect_uri/2` alone would surface.
    test "authorizes against the ephemeral port it actually binds" do
      expect(FetcherMock, :fetch, fn @claude_code_url -> {:ok, @claude_code_document} end)

      assert {:ok, validated} =
               Engram.OAuth.validate_authorization_request(%{
                 "client_id" => @claude_code_url,
                 "redirect_uri" => "http://localhost:3118/callback",
                 "response_type" => "code",
                 "code_challenge" => "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
                 "code_challenge_method" => "S256"
               })

      assert validated.redirect_uri == "http://localhost:3118/callback"
    end
  end

  # The second external fixture, and the one that actually reproduces the
  # incident. MCPJam is a widely-used MCP inspector; this is its real published
  # document, and against the pre-fix code it failed TWICE over:
  #
  #   grant_types:   "contains an unsupported grant_type"  (device_code)
  #   redirect_uris: "should have at most 10 item(s)"      (it lists 14)
  #
  # Neither has anything to do with whether MCPJam can safely use us. The first
  # is a grant we don't implement and it never asked us to; the second is a tool
  # supporting three ports and two hosted environments. Both were fatal.
  #
  # Keep this fixture verbatim too. Its value is precisely that nobody here
  # chose its contents.
  describe "the real published MCPJam document" do
    @mcpjam_url "https://www.mcpjam.com/.well-known/oauth/client-metadata.json"
    @mcpjam_document %{
      "client_id" => "https://www.mcpjam.com/.well-known/oauth/client-metadata.json",
      "client_name" => "MCPJam",
      "client_uri" => "https://www.mcpjam.com",
      "logo_uri" => "https://www.mcpjam.com/mcp_jam_2row.png",
      "redirect_uris" => [
        "http://127.0.0.1:6274/oauth/callback",
        "http://127.0.0.1:6274/callback",
        "http://127.0.0.1:6274/oauth/callback/debug",
        "http://localhost:6274/oauth/callback",
        "http://localhost:6274/callback",
        "http://localhost:6274/oauth/callback/debug",
        "http://127.0.0.1:5173/oauth/callback",
        "http://127.0.0.1:5173/oauth/callback/debug",
        "http://localhost:5173/oauth/callback",
        "http://localhost:5173/oauth/callback/debug",
        "https://app.mcpjam.com/oauth/callback",
        "https://app.mcpjam.com/oauth/callback/debug",
        "https://staging.mcpjam.com/oauth/callback",
        "https://staging.mcpjam.com/oauth/callback/debug"
      ],
      "grant_types" => [
        "authorization_code",
        "refresh_token",
        "urn:ietf:params:oauth:grant-type:device_code"
      ],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none",
      "application_type" => "native"
    }

    test "is accepted, keeping the grants we implement and all 14 redirects" do
      expect(FetcherMock, :fetch, fn @mcpjam_url -> {:ok, @mcpjam_document} end)

      assert {:ok, client} = Cimd.ensure_client(@mcpjam_url)
      assert client.grant_types == ["authorization_code", "refresh_token"]
      assert length(client.redirect_uris) == 14
      assert client.logo_uri == "https://www.mcpjam.com/mcp_jam_2row.png"
    end

    test "authorizes on one of the redirects it published" do
      expect(FetcherMock, :fetch, fn @mcpjam_url -> {:ok, @mcpjam_document} end)

      assert {:ok, validated} =
               Engram.OAuth.validate_authorization_request(%{
                 "client_id" => @mcpjam_url,
                 "redirect_uri" => "https://app.mcpjam.com/oauth/callback",
                 "response_type" => "code",
                 "code_challenge" => "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
                 "code_challenge_method" => "S256"
               })

      assert validated.redirect_uri == "https://app.mcpjam.com/oauth/callback"
    end
  end

  # DCR's tighter cap is unchanged: an anonymous POST is a different threat from
  # a fetched, size-capped vendor document.
  describe "the DCR redirect cap is untouched by the CIMD one" do
    test "an 11-entry DCR registration is still refused" do
      uris = for i <- 1..11, do: "https://dcr.example/cb#{i}"

      changeset =
        Client.registration_changeset(%Client{}, %{
          "client_name" => "Greedy",
          "redirect_uris" => uris
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :redirect_uris)
    end
  end

  describe "ensure_client/1 capability metadata is negotiated, not enforced" do
    test "keeps only the grant types we implement, rather than refusing the client" do
      expect(FetcherMock, :fetch, fn @url ->
        {:ok,
         document(%{
           "grant_types" => [
             "authorization_code",
             "refresh_token",
             "urn:ietf:params:oauth:grant-type:token-exchange"
           ]
         })}
      end)

      assert {:ok, client} = Cimd.ensure_client(@url)
      assert client.grant_types == ["authorization_code", "refresh_token"]
    end

    test "keeps only the response types we implement" do
      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"response_types" => ["code", "code id_token", "token"]})}
      end)

      assert {:ok, client} = Cimd.ensure_client(@url)
      assert client.response_types == ["code"]
    end

    # Intersecting to nothing is different: there is no flow left to run, so the
    # refusal is about us, not about tidiness.
    test "refuses a document with no grant type in common with us" do
      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"grant_types" => ["client_credentials"]})}
      end)

      assert {:error, :no_supported_grant_type} = Cimd.ensure_client(@url)
    end

    test "refuses a document with no response type in common with us" do
      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"response_types" => ["token"]})}
      end)

      assert {:error, :no_supported_response_type} = Cimd.ensure_client(@url)
    end

    # Decorative metadata must never cost a client its authorization. Dropping the
    # field loses a logo; refusing the document loses the connector.
    test "drops metadata URIs we will not display instead of refusing the client" do
      expect(FetcherMock, :fetch, fn @url ->
        {:ok,
         document(%{
           "logo_uri" => "http://claude.ai/logo.png",
           "tos_uri" => "not a uri at all",
           "policy_uri" => "https://claude.ai/policy"
         })}
      end)

      assert {:ok, client} = Cimd.ensure_client(@url)
      assert is_nil(client.logo_uri)
      assert is_nil(client.tos_uri)
      assert client.policy_uri == "https://claude.ai/policy"
    end

    test "truncates an over-long client_name instead of refusing the client" do
      long = String.duplicate("a", 500)
      expect(FetcherMock, :fetch, fn @url -> {:ok, document(%{"client_name" => long})} end)

      assert {:ok, client} = Cimd.ensure_client(@url)
      assert byte_size(client.client_name) == 200
    end

    test "an absent grant_types/response_types still gets our defaults" do
      expect(FetcherMock, :fetch, fn @url -> {:ok, document()} end)

      assert {:ok, client} = Cimd.ensure_client(@url)
      assert client.grant_types == ["authorization_code", "refresh_token"]
      assert client.response_types == ["code"]
    end

    # The rejection reason is the tripwire's whole value. `:invalid_document` on
    # its own could not tell us WHICH field a vendor's document died on, which is
    # what left the 2026-08-04 incident undiagnosable from logs.
    test "a genuine changeset refusal carries the offending fields" do
      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"redirect_uris" => ["javascript:alert(1)"]})}
      end)

      assert {:error, {:invalid_document, errors}} = Cimd.ensure_client(@url)
      assert Keyword.has_key?(errors, :redirect_uris)
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
      # No expectation set: a fetch here would fail verify_on_exit!.
      assert {:error, :not_found} = Cimd.get_by_url(@url)
      assert {:error, :not_found} = Cimd.get_by_url(nil)
    end
  end

  # `invalid_client` is terminal — the client gives up and the user is told their
  # app is not recognized. Reserving it for failures that really are the client's
  # is what keeps a transient outage on our side from looking like a permanently
  # broken connector, which is exactly how the 2026-08-04 incident presented.
  describe "how a CIMD failure is reported to the authorization endpoint" do
    test "a transport failure is retryable, not the client's fault" do
      expect(FetcherMock, :fetch, fn @url -> {:error, :fetch_failed} end)
      assert {:server_error, "temporarily_unavailable"} = authorize(@url)
    end

    test "the vendor being down or throttling us is retryable" do
      for status <- [429, 500, 503] do
        expect(FetcherMock, :fetch, fn @url -> {:error, {:http_status, status}} end)

        assert {:server_error, "temporarily_unavailable"} = authorize(@url),
               "expected HTTP #{status} to be reported as transient"
      end
    end

    # Our own limiter refusing the fetch must never be dressed up as the vendor's
    # fault: it is silent by design, so `invalid_client` here produced pages of
    # user-visible failure with no matching log line at all.
    # Coupled to Cimd's @per_host_limit (10/min, same host). If that constant
    # moves, raise the loop bound rather than deleting the test — the behaviour
    # it pins is "our limiter is not the vendor's fault", not the number.
    test "our own fetch rate limiter is retryable" do
      stub(FetcherMock, :fetch, fn url -> {:ok, %{document() | "client_id" => url}} end)

      # Burst until the limiter actually refuses, rather than firing a fixed 11
      # and assuming the 12th is over. `@per_host_limit` is 10 per FIXED 60s
      # window, so a burst that straddles a window boundary leaves the last
      # probe in a fresh window and it is allowed — which failed this test with
      # `{:ok, _}` for a reason unrelated to the behaviour it pins. Once the
      # limiter refuses it keeps refusing for the rest of the window, so
      # halting on the first refusal is stable.
      #
      # Bounded at 30 so a genuinely broken limiter fails instead of looping:
      # comfortably over @per_host_limit even after one window roll, and under
      # @discover_limit (60) so it stays the PER-HOST limiter being pinned.
      result =
        Enum.reduce_while(1..30, nil, fn i, _acc ->
          case authorize("https://claude.ai/limiter-probe-#{i}") do
            {:server_error, _} = refused -> {:halt, refused}
            allowed -> {:cont, allowed}
          end
        end)

      assert {:server_error, "temporarily_unavailable"} = result
    end

    test "a document we cannot bind or parse really is the client's fault" do
      expect(FetcherMock, :fetch, fn @url ->
        {:ok, document(%{"client_id" => "https://claude.ai/someone-else"})}
      end)

      assert {:client_error, "invalid_client"} = authorize(@url)
    end

    test "a 404 on the document URL really is the client's fault" do
      expect(FetcherMock, :fetch, fn @url -> {:error, {:http_status, 404}} end)
      assert {:client_error, "invalid_client"} = authorize(@url)
    end
  end

  # The seam the ticket flagged as the real cost: the wire client_id is a URL,
  # but every table downstream stores the internal UUID.
  describe "the wire client_id round-trip" do
    setup do
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
               OAuth.mint_authorization_code(user, validated, [vault.id])

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

      {:ok, redirect} = OAuth.mint_authorization_code(user, validated, [vault.id])
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
