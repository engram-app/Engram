defmodule Engram.OAuth.Cimd.JwksTest do
  # async: false — the JWKS fetch rate limiter's ETS buckets and the JWKS cache
  # table are both node-global, and Mox expectations are set from the test
  # process.
  use Engram.DataCase, async: false

  import Mox

  alias Engram.OAuth.Cimd.FetcherMock
  alias Engram.OAuth.Cimd.Jwks
  alias Engram.OAuth.Client
  alias Engram.Repo

  setup :verify_on_exit!

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    # The cache is a node-global named table that outlives a test. Without this
    # the second test to use @jwks_uri gets a cache hit, the fetcher is never
    # called, and Mox fails the expectation for a reason that has nothing to do
    # with what the test is asserting.
    Engram.Cache.clear_local(:jwks)
    :ok
  end

  @client_url "https://chatgpt.com/oauth/client.json"
  @jwks_uri "https://chatgpt.com/oauth/jwks.json"
  @audience "https://mcp.engram.page/oauth/token"
  @issuer "https://mcp.engram.page"
  @kid "test-key-1"

  # One keypair for the whole module: generating RSA is slow enough that doing it
  # per test dominates the runtime, and none of these tests care about key reuse.
  setup_all do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, private_map} = JOSE.JWK.to_map(jwk)
    {_, public_map} = JOSE.JWK.to_public_map(jwk)

    %{private: private_map, public: Map.put(public_map, "kid", @kid)}
  end

  defp client(overrides \\ %{}) do
    Map.merge(
      %Client{
        cimd_url: @client_url,
        jwks_uri: @jwks_uri,
        token_endpoint_auth_method: "private_key_jwt",
        token_endpoint_auth_signing_alg: "RS256"
      },
      overrides
    )
  end

  defp claims(overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    Map.merge(
      %{
        "iss" => @client_url,
        "sub" => @client_url,
        "aud" => @audience,
        "exp" => now + 300,
        "iat" => now
      },
      overrides
    )
  end

  defp sign(private, claims, alg \\ "RS256", headers \\ %{"kid" => @kid}) do
    signer = Joken.Signer.create(alg, private, headers)
    {:ok, token, _} = Joken.encode_and_sign(claims, signer)
    token
  end

  defp expect_jwks(public, times \\ 1) do
    expect(FetcherMock, :fetch, times, fn @jwks_uri -> {:ok, %{"keys" => [public]}} end)
  end

  describe "verify_assertion/3" do
    test "accepts an assertion signed by a published key", %{private: private, public: public} do
      expect_jwks(public)

      assert :ok = Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
    end

    # The fix for the review's critical finding. Without a cache the fetch
    # limiter stops being a backstop and becomes a hard ceiling on token
    # exchanges per vendor, and the request that crosses it gets a TERMINAL 401.
    test "fetches the key set once and serves later assertions from cache", %{
      private: private,
      public: public
    } do
      expect_jwks(public, 1)

      for _ <- 1..5 do
        assert :ok = Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
      end
    end

    test "accepts when aud is an array containing us", %{private: private, public: public} do
      expect_jwks(public)

      assertion = sign(private, claims(%{"aud" => ["https://elsewhere", @audience]}))
      assert :ok = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    # RFC 7523 §3 permits EITHER the token endpoint URL or the issuer identifier,
    # and vendors split on which they send. `auth_opts/2` offers both, but every
    # other test here passes a single-element list, so nothing held that second
    # element in place — trimming it would break issuer-form vendors with CI
    # still green. That is the exact failure this whole series exists to stop.
    test "accepts the issuer identifier as aud, not just the token endpoint", %{
      private: private,
      public: public
    } do
      expect_jwks(public)

      assertion = sign(private, claims(%{"aud" => @issuer}))
      assert :ok = Jwks.verify_assertion(client(), assertion, [@audience, @issuer])
    end

    # Review of #1974: which `aud` form each assertion used is a bounded
    # counter label, computed once per assertion, not an info line per token
    # request. rfc7523bis will require the issuer form; this is how we see
    # who still sends the token endpoint before we tighten.
    test "counts the aud form once per assertion, with a bounded label", %{
      private: private,
      public: public
    } do
      expect_jwks(public)
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :cimd, :assertion_audience]])
      audiences = [@audience, @issuer]

      # Second review #8: which trailing slash, and for a list whether the
      # issuer (what rfc7523bis will require) is in it.
      for {aud, form} <- [
            {@audience, :token_endpoint},
            {@issuer, :issuer},
            {@issuer <> "/", :issuer_trailing_slash},
            {@audience <> "/", :token_endpoint_trailing_slash},
            {["https://elsewhere", @issuer], :list_with_issuer},
            {["https://elsewhere", @audience], :list_without_issuer}
          ] do
        assert :ok =
                 Jwks.verify_assertion(
                   client(),
                   sign(private, claims(%{"aud" => aud})),
                   audiences
                 )

        assert_received {[:engram, :cimd, :assertion_audience], ^ref, %{count: 1},
                         %{aud_form: ^form, client: "chatgpt"}}

        refute_received {[:engram, :cimd, :assertion_audience], ^ref, _, _}
      end

      :telemetry.detach(ref)
    end

    test "logs the audience only when it is none of ours", %{private: private, public: public} do
      expect_jwks(public)
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      accepted =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
        end)

      refute accepted =~ "mcp_assertion_audience"

      refused =
        ExUnit.CaptureLog.capture_log(fn ->
          assertion = sign(private, claims(%{"aud" => "https://elsewhere"}))

          assert {:error, :wrong_audience} =
                   Jwks.verify_assertion(client(), assertion, [@audience])
        end)

      assert refused =~ "mcp_assertion_audience"
      assert refused =~ "aud_form=other"
    end

    # The whole point of checking `aud`: an assertion minted for another
    # authorization server must not be replayable against this one.
    test "rejects an assertion addressed elsewhere", %{private: private, public: public} do
      expect_jwks(public)

      assertion = sign(private, claims(%{"aud" => "https://someone-else/oauth/token"}))
      assert {:error, :wrong_audience} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    test "rejects when iss/sub is not the client", %{private: private, public: public} do
      expect_jwks(public)

      assertion = sign(private, claims(%{"iss" => "https://evil.example/client.json"}))
      assert {:error, :wrong_issuer} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    test "rejects an expired assertion", %{private: private, public: public} do
      expect_jwks(public)

      past = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(60)
      assertion = sign(private, claims(%{"exp" => past}))

      assert {:error, :assertion_expired} =
               Jwks.verify_assertion(client(), assertion, [@audience])
    end

    test "rejects an assertion that is not yet valid", %{private: private, public: public} do
      expect_jwks(public)

      future = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      assertion = sign(private, claims(%{"nbf" => future}))

      assert {:error, :assertion_not_yet_valid} =
               Jwks.verify_assertion(client(), assertion, [@audience])
    end

    # A long-lived assertion is a bearer credential sitting in whatever logged
    # it. Its own reason: RFC 7523 sets no maximum, so this bound is OURS, and a
    # vendor minting a legitimate one-hour assertion must not read as a forgery.
    test "rejects an assertion valid for a year", %{private: private, public: public} do
      expect_jwks(public)

      far = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(365 * 24 * 3600)
      assertion = sign(private, claims(%{"exp" => far}))

      assert {:error, :assertion_lifetime_too_long} =
               Jwks.verify_assertion(client(), assertion, [@audience])
    end

    # Vendor clocks drift. A few minutes fast must not read as a policy
    # violation, or we refuse a correct vendor and blame them for it.
    test "tolerates modest clock skew", %{private: private, public: public} do
      expect_jwks(public)

      skewed = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(660)
      assertion = sign(private, claims(%{"exp" => skewed}))

      assert :ok = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    # THE forgery this module exists to refuse. The RSA public key is public by
    # definition, so anyone who can read the JWKS could mint an HMAC with it.
    # Verification must never take its algorithm from the attacker's header.
    test "rejects an HS256 assertion forged with the public key", %{public: public} do
      forged =
        Joken.Signer.create("HS256", Jason.encode!(public))
        |> then(fn signer ->
          {:ok, token, _} = Joken.encode_and_sign(claims(), signer)
          token
        end)

      assert {:error, :alg_not_allowed} = Jwks.verify_assertion(client(), forged, [@audience])
    end

    # No JWKS expectation: the algorithm is checked before anything is fetched,
    # which is the point — a rejected alg must never cost us an outbound request.
    # Distinct from :alg_not_allowed, because a vendor mid-rotation is not an
    # attacker and the two must not share a log line.
    test "rejects an alg the document did not pin", %{private: private} do
      assertion = sign(private, claims(), "RS512", %{"kid" => @kid})

      assert {:error, :alg_pin_mismatch} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    # An unknown kid means the vendor rotated, so we refetch once before giving
    # up — waiting out the cache TTL would break every assertion in between.
    test "refetches once on an unknown kid", %{private: private, public: public} do
      expect_jwks(public, 2)

      assertion = sign(private, claims(), "RS256", %{"kid" => "some-other-key"})
      assert {:error, :unknown_kid} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    test "rejects a signature from a different key", %{public: public} do
      expect_jwks(public)

      {_, other_private} = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_map()
      assertion = sign(other_private, claims())

      assert {:error, :bad_signature} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    # A vendor publishing a key we cannot parse will never self-heal. Reporting
    # it as :bad_signature sends the operator looking for an attacker.
    test "reports an unparseable published key distinctly", %{private: private} do
      expect(FetcherMock, :fetch, fn @jwks_uri ->
        {:ok,
         %{"keys" => [%{"kty" => "RSA", "kid" => @kid, "n" => "!!not-base64!!", "e" => "AQAB"}]}}
      end)

      assert {:error, :unusable_key} =
               Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
    end

    test "refuses a client with no published keys", %{private: private} do
      assertion = sign(private, claims())

      assert {:error, :no_jwks_uri} =
               Jwks.verify_assertion(client(%{jwks_uri: nil}), assertion, [@audience])
    end

    test "refuses garbage" do
      assert {:error, :malformed_assertion} =
               Jwks.verify_assertion(client(), "not-a-jwt", [@audience])
    end

    test "surfaces an unreachable JWKS endpoint as unavailable", %{private: private} do
      expect(FetcherMock, :fetch, fn @jwks_uri -> {:error, :fetch_failed} end)

      assert {:error, :jwks_unavailable} =
               Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
    end
  end

  # #1974 PR 2 spec. The 2026-10-13 ChatGPT 503 was a JWKS fetch timeout on a
  # key we had already verified many times: every one of these fails on a
  # cache that forgets the key the moment a refetch fails.
  describe "never fail when we already hold a good key" do
    defp persisted_client(public, fetched_at) do
      Repo.insert!(
        %Client{
          cimd_url: @client_url,
          cimd_fetched_at: DateTime.utc_now(),
          client_name: "ChatGPT",
          redirect_uris: ["https://chatgpt.com/cb"],
          token_endpoint_auth_method: "private_key_jwt",
          token_endpoint_auth_signing_alg: "RS256",
          jwks_uri: @jwks_uri,
          jwks_cached: %{"keys" => [public]},
          jwks_fetched_at: fetched_at,
          kind: "mcp"
        },
        skip_tenant_check: true
      )
    end

    defp ago(seconds),
      do: DateTime.add(DateTime.utc_now(), -seconds) |> DateTime.truncate(:second)

    test "a new node with a persisted JWKS verifies with no outbound fetch", %{
      private: private,
      public: public
    } do
      persisted_client(public, ago(60))
      # No FetcherMock expectation: any fetch fails the test.
      assert :ok = Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
    end

    test "an expired key set is still served while the vendor is failing", %{
      private: private,
      public: public
    } do
      persisted_client(public, ago(2 * 24 * 3600))

      expect(FetcherMock, :fetch, fn @jwks_uri ->
        {:error, {:transport_error, :connect, :timeout}}
      end)

      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :cimd, :fetch]])

      assert :ok = Jwks.verify_assertion(client(), sign(private, claims()), [@audience])

      # Stale-served is a warning, not a page: the metric must tell them apart.
      assert_received {[:engram, :cimd, :fetch], ^ref, %{duration_ms: _},
                       %{kind: :jwks, result: :stale, reason: :connect}}

      :telemetry.detach(ref)
    end

    test "a key set older than the stale limit is not served", %{private: private, public: public} do
      persisted_client(public, ago(8 * 24 * 3600))
      expect(FetcherMock, :fetch, fn @jwks_uri -> {:error, {:http_status, 503}} end)

      assert {:error, :jwks_unavailable} =
               Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
    end

    test "a successful fetch is persisted on every client row naming that jwks_uri", %{
      private: private,
      public: public
    } do
      row = persisted_client(%{"kid" => "old"}, ago(2 * 24 * 3600))
      expect_jwks(public)

      assert :ok = Jwks.verify_assertion(client(), sign(private, claims()), [@audience])

      reloaded = Repo.get!(Client, row.client_id, skip_tenant_check: true)
      assert reloaded.jwks_cached == %{"keys" => [public]}
      assert DateTime.diff(DateTime.utc_now(), reloaded.jwks_fetched_at) < 5
    end

    test "10 concurrent cold misses fetch exactly once", %{private: private, public: public} do
      Mox.set_mox_global()

      expect(FetcherMock, :fetch, 1, fn @jwks_uri ->
        Process.sleep(200)
        {:ok, %{"keys" => [public]}}
      end)

      assertion = sign(private, claims())

      results =
        1..10
        |> Enum.map(fn _ ->
          Task.async(fn -> Jwks.verify_assertion(client(), assertion, [@audience]) end)
        end)
        |> Task.await_many(5_000)

      assert Enum.all?(results, &(&1 == :ok))
    end

    # Without a per-URI cooldown, 10 random kids exhaust the 10/min rotation
    # bucket and the vendor's genuine rotation is refused for up to a minute.
    test "random-kid probes cannot starve a real rotation", %{private: private, public: public} do
      # 1 initial fetch + 1 kid-miss refetch; the other 19 probes are inside
      # the cooldown and cost nothing.
      expect_jwks(public, 2)

      # The first probe's refetch succeeds, so its kid is genuinely unknown
      # (401). The rest land in the cooldown and are told to retry (503,
      # review #3): an unchecked kid must never read as a terminal refusal.
      first = sign(private, claims(), "RS256", %{"kid" => "probe-1"})
      assert {:error, :unknown_kid} = Jwks.verify_assertion(client(), first, [@audience])

      for n <- 2..20 do
        probe = sign(private, claims(), "RS256", %{"kid" => "probe-#{n}"})
        assert {:error, :jwks_unavailable} = Jwks.verify_assertion(client(), probe, [@audience])
      end

      # 30 s later the vendor really rotates.
      Engram.OAuth.Cimd.JwksCache.expire_kid_miss_cooldown(@jwks_uri)
      rotated = %{public | "kid" => "rotated"}
      expect_jwks(rotated, 1)

      assertion = sign(private, claims(), "RS256", %{"kid" => "rotated"})
      assert :ok = Jwks.verify_assertion(client(), assertion, [@audience])
    end
  end

  # Review #3: on an unknown kid the held keys cannot help (the kid is not in
  # them), so a refetch that does not happen or does not succeed must be a
  # retryable 503, never the held set (which turns into a terminal 401).
  describe "unknown kid when the refetch cannot answer" do
    test "a failing refetch is transient", %{private: private, public: public} do
      expect_jwks(public)

      expect(FetcherMock, :fetch, fn @jwks_uri ->
        {:error, {:transport_error, :connect, :timeout}}
      end)

      rotated = sign(private, claims(), "RS256", %{"kid" => "rotated"})
      assert {:error, :jwks_unavailable} = Jwks.verify_assertion(client(), rotated, [@audience])
      assert Jwks.transient?(:jwks_unavailable)
    end

    test "a refetch inside the cooldown is transient", %{private: private, public: public} do
      expect_jwks(public, 2)

      a = sign(private, claims(), "RS256", %{"kid" => "a"})
      b = sign(private, claims(), "RS256", %{"kid" => "b"})
      assert {:error, :unknown_kid} = Jwks.verify_assertion(client(), a, [@audience])
      assert {:error, :jwks_unavailable} = Jwks.verify_assertion(client(), b, [@audience])
    end
  end

  # Review #9.
  describe "single-flight waiters" do
    alias Engram.OAuth.Cimd.JwksCache

    # Holds the flight lock for `jwks_uri` from another process, the way a
    # concurrent token request would, until told to stop.
    defp hold_flight(deadline_ms) do
      test_pid = self()

      pid =
        spawn(fn ->
          {:ok, _} = Registry.register(JwksCache.Flights, @jwks_uri, deadline_ms)
          send(test_pid, :flight_held)

          receive do
            :release -> :ok
          end
        end)

      assert_receive :flight_held
      on_exit(fn -> send(pid, :release) end)
      pid
    end

    test "a waiter holding stale keys uses them without waiting", %{
      private: private,
      public: public
    } do
      persisted_client(public, ago(2 * 24 * 3600))
      hold_flight(System.monotonic_time(:millisecond) + 60_000)

      {micros, result} =
        :timer.tc(fn -> Jwks.verify_assertion(client(), sign(private, claims()), [@audience]) end)

      assert :ok = result
      assert micros < 500_000
      assert JwksCache.take_source() == :stale
    end

    test "a waiter with no keys waits until the flight's own deadline, not a fixed timer", %{
      private: private
    } do
      hold_flight(System.monotonic_time(:millisecond) + 300)

      {micros, result} =
        :timer.tc(fn -> Jwks.verify_assertion(client(), sign(private, claims()), [@audience]) end)

      assert {:error, :jwks_unavailable} = result
      assert micros >= 250_000 and micros < 1_500_000
    end

    # Second review #1: a rotation refetch that joins someone else's flight
    # must not be answered with the keys it already knows lack the kid. If the
    # flight did not fetch anything newer, that is a retryable 503, not a 401.
    test "a kid-miss waiter whose flight fetched nothing new gets a transient error", %{
      private: private,
      public: public
    } do
      persisted_client(public, ago(60))
      pid = hold_flight(System.monotonic_time(:millisecond) + 5_000)

      Task.start(fn ->
        Process.sleep(100)
        send(pid, :release)
      end)

      rotated = sign(private, claims(), "RS256", %{"kid" => "rotated"})
      assert {:error, :jwks_unavailable} = Jwks.verify_assertion(client(), rotated, [@audience])
    end

    test "a background waiter whose flight failed is not counted as refreshed", %{
      public: public
    } do
      persisted_client(public, ago(2 * 24 * 3600))
      pid = hold_flight(System.monotonic_time(:millisecond) + 5_000)

      Task.start(fn ->
        Process.sleep(100)
        send(pid, :release)
      end)

      assert {:error, :jwks_unavailable} = JwksCache.refresh_background(@jwks_uri)
    end

    # Second review #6: the waiter's bound is its own, fixed when it joins, not
    # whatever deadline the current owner recorded (an owner that recorded a
    # long one, or a chain of owners, must not hold a token request ~10 s).
    test "a waiter gives up at its own deadline even when the owner's is later", %{
      private: private
    } do
      hold_flight(System.monotonic_time(:millisecond) + 60_000)

      {micros, result} =
        :timer.tc(fn -> Jwks.verify_assertion(client(), sign(private, claims()), [@audience]) end)

      assert {:error, :jwks_unavailable} = result
      assert micros < 6_000_000
    end

    test "a waiter served by the flight reports source :fetched", %{
      private: private,
      public: public
    } do
      pid = hold_flight(System.monotonic_time(:millisecond) + 5_000)

      Task.start(fn ->
        Process.sleep(100)

        Engram.Cache.put(:jwks, @jwks_uri, %{
          keys: [public],
          fetched_at: System.system_time(:millisecond)
        })

        send(pid, :release)
      end)

      assert :ok = Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
      assert JwksCache.take_source() == :fetched
    end
  end

  # Review #5: the background sweep must not page while usable keys exist.
  describe "background refresh" do
    alias Engram.OAuth.Cimd.JwksCache

    test "a failed sweep fetch with usable stale keys warns and reports :stale", %{public: public} do
      persisted_client(public, ago(2 * 24 * 3600))
      expect(FetcherMock, :fetch, fn @jwks_uri -> {:error, {:http_status, 503}} end)
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :cimd, :fetch]])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, _} = JwksCache.refresh_background(@jwks_uri)
        end)

      assert log =~ "mcp_jwks_refresh_failed"
      refute log =~ "mcp_jwks_unusable"
      assert_received {[:engram, :cimd, :fetch], ^ref, _, %{kind: :jwks, result: :stale}}
      :telemetry.detach(ref)
    end

    test "a failed sweep fetch with nothing usable is :error / mcp_jwks_unusable" do
      expect(FetcherMock, :fetch, fn @jwks_uri -> {:error, {:http_status, 503}} end)
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :cimd, :fetch]])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, _} = JwksCache.refresh_background(@jwks_uri)
        end)

      assert log =~ "mcp_jwks_unusable"
      assert_received {[:engram, :cimd, :fetch], ^ref, _, %{kind: :jwks, result: :error}}
      :telemetry.detach(ref)
    end
  end

  describe "error classification" do
    for status <- [404, 301] do
      test "HTTP #{status} from the vendor is terminal", %{private: private} do
        expect(FetcherMock, :fetch, fn @jwks_uri -> {:error, {:http_status, unquote(status)}} end)

        assert {:error, :jwks_invalid} =
                 Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
      end
    end

    test "a non-JSON body is terminal", %{private: private} do
      expect(FetcherMock, :fetch, fn @jwks_uri -> {:error, :not_json} end)

      assert {:error, :jwks_invalid} =
               Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
    end

    test "a document with no keys array is terminal", %{private: private} do
      expect(FetcherMock, :fetch, fn @jwks_uri -> {:ok, %{"nope" => 1}} end)

      assert {:error, :jwks_invalid} =
               Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
    end

    for error <- [{:http_status, 502}, {:http_status, 429}, {:transport_error, :recv, :timeout}] do
      test "#{inspect(error)} is transient", %{private: private} do
        expect(FetcherMock, :fetch, fn @jwks_uri -> {:error, unquote(Macro.escape(error))} end)

        assert {:error, :jwks_unavailable} =
                 Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
      end
    end

    test "jwks_invalid is not transient" do
      refute Jwks.transient?(:jwks_invalid)
    end
  end

  describe "assertion checks (P2)" do
    test "tolerates an exp up to 60 s in the past", %{private: private, public: public} do
      expect_jwks(public)
      exp = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(30)

      assert :ok =
               Jwks.verify_assertion(client(), sign(private, claims(%{"exp" => exp})), [@audience])
    end

    test "accepts aud with a trailing slash", %{private: private, public: public} do
      expect_jwks(public)
      assertion = sign(private, claims(%{"aud" => @issuer <> "/"}))
      assert :ok = Jwks.verify_assertion(client(), assertion, [@audience, @issuer])
    end

    test "accepts aud without the trailing slash we were configured with", %{
      private: private,
      public: public
    } do
      expect_jwks(public)
      assertion = sign(private, claims(%{"aud" => @issuer}))
      assert :ok = Jwks.verify_assertion(client(), assertion, [@issuer <> "/"])
    end

    test "refuses an RSA key under 2048 bits" do
      jwk = JOSE.JWK.generate_key({:rsa, 1024})
      {_, private} = JOSE.JWK.to_map(jwk)
      {_, public} = JOSE.JWK.to_public_map(jwk)
      expect_jwks(Map.put(public, "kid", @kid))

      assert {:error, :key_too_small} =
               Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
    end
  end

  describe "transient?/1" do
    # This predicate is what decides 503-and-retry vs a TERMINAL 401. Getting it
    # wrong hands a connector a permanent failure for a condition that clears on
    # its own — the exact misattribution this series is about.
    test "our own transient failures are retryable, the client's are not" do
      assert Jwks.transient?(:jwks_unavailable)
      assert Jwks.transient?(:jwks_rate_limited)

      refute Jwks.transient?(:bad_signature)
      refute Jwks.transient?(:wrong_audience)
      refute Jwks.transient?(:alg_not_allowed)
      refute Jwks.transient?(:assertion_expired)
    end
  end
end
