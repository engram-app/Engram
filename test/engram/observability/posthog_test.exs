defmodule Engram.Observability.PostHogTest do
  @moduledoc """
  Function-of-env-var contract: the wrapper is a no-op when
  `:posthog_key` is unset, and emits to the configured host when it
  is. We intentionally don't pin the wire format — PostHog's
  capture endpoint accepts a small range of shapes — but we do
  assert the two structural invariants:

    1. `api_key` matches the configured key (else PostHog rejects).
    2. `distinct_id` matches the caller's value (else the funnel
       can't join with the frontend identify call).
  """

  use ExUnit.Case, async: false

  alias Engram.Observability.PostHog

  setup do
    prior_key = Application.get_env(:engram, :posthog_key)
    prior_host = Application.get_env(:engram, :posthog_host)

    on_exit(fn ->
      Application.put_env(:engram, :posthog_key, prior_key)
      Application.put_env(:engram, :posthog_host, prior_host)
    end)

    :ok
  end

  describe "capture/3" do
    test "is a no-op when posthog_key is unset" do
      Application.delete_env(:engram, :posthog_key)

      # The contract is "never raises, never blocks, always returns
      # :ok". No process spawned, no Req call, no Bypass needed —
      # if config returns :disabled the function returns immediately.
      assert :ok = PostHog.capture("user-1", "note_created")
    end

    test "is a no-op when posthog_key is an empty string" do
      Application.put_env(:engram, :posthog_key, "")

      assert :ok = PostHog.capture("user-1", "note_created")
    end

    test "POSTs to the configured host when key is set" do
      bypass = Bypass.open()
      Application.put_env(:engram, :posthog_key, "phc_test_token")
      Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")

      parent = self()

      Bypass.expect_once(bypass, "POST", "/capture/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:posthog_body, Jason.decode!(body)})
        Plug.Conn.resp(conn, 200, "1")
      end)

      assert :ok = PostHog.capture("clerk_user_abc", "note_created", %{vault: "v1"})

      assert_receive {:posthog_body, body}, 1_000
      assert body["api_key"] == "phc_test_token"
      assert body["distinct_id"] == "clerk_user_abc"
      assert body["event"] == "note_created"
      assert body["properties"]["vault"] == "v1"
    end

    test "maps :anon to a stable 'anonymous' distinct_id" do
      bypass = Bypass.open()
      Application.put_env(:engram, :posthog_key, "phc_test_token")
      Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")

      parent = self()

      Bypass.expect_once(bypass, "POST", "/capture/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:posthog_body, Jason.decode!(body)})
        Plug.Conn.resp(conn, 200, "1")
      end)

      assert :ok = PostHog.capture(:anon, "waitlist_signup")

      assert_receive {:posthog_body, body}, 1_000
      assert body["distinct_id"] == "anonymous"
    end
  end

  describe "analytics_id/1" do
    # Pins the algorithm. NOTE: this was originally a cross-repo contract with
    # engram-marketing, but that repo's waitlist and src/lib/hash-email.ts were
    # deleted in #189 — there is no marketing counterpart to match any more.
    # Keep the vector anyway: it is what catches a normalisation change.
    @key "dGVzdC1rZXktZG8tbm90LXVzZS1pbi1wcm9kdWN0aW9uLg=="
    @email "sabio@web.de"

    setup do
      prev = Application.get_env(:engram, :hmac_key_analytics_id)
      Application.put_env(:engram, :hmac_key_analytics_id, @key)
      on_exit(fn -> Application.put_env(:engram, :hmac_key_analytics_id, prev) end)
      :ok
    end

    test "normalises by trimming and downcasing" do
      assert PostHog.analytics_id("  Sabio@Web.DE  ") == PostHog.analytics_id(@email)
    end

    test "returns 64 lowercase hex characters" do
      assert PostHog.analytics_id(@email) =~ ~r/^[0-9a-f]{64}$/
    end

    test "is keyed, not a bare digest" do
      plain = :crypto.hash(:sha256, @email) |> Base.encode16(case: :lower)
      refute PostHog.analytics_id(@email) == plain
    end

    test "a different key yields a different id" do
      first = PostHog.analytics_id(@email)

      Application.put_env(
        :engram,
        :hmac_key_analytics_id,
        "b3RoZXIta2V5LW90aGVyLWtleS0xMjM0NTY3OA=="
      )

      refute PostHog.analytics_id(@email) == first
    end

    # Oracle computed independently (Python `hmac.new(key, email, sha256)`).
    # The tests above prove the output is not a bare digest; only this one
    # proves the construction is genuinely HMAC and not sha256(key <> email),
    # which would produce 9149107753017daac3b7cb57b12fab6319e4ad415dae5bd5e8dbd66b3b4dc969.
    # There is no second implementation to cross-check against — engram-marketing's
    # was deleted in #189 — so this literal IS the contract.
    test "matches an independently computed HMAC vector" do
      assert PostHog.analytics_id(@email) ==
               "6f2afb8435bef1b20c37300002a4827c68eca6aa666c401626d5d227624e2bb6"
    end
  end

  describe "opt-out" do
    test "distinct_id/1 is the analytics id, or nil for an opted-out or emailless user" do
      assert PostHog.distinct_id(%{email: "a@b.co"}) == PostHog.analytics_id("a@b.co")

      assert PostHog.distinct_id(%{email: "a@b.co", analytics_opt_out_at: DateTime.utc_now()}) ==
               nil

      assert PostHog.distinct_id(%{email: nil}) == nil
    end

    test "capture/3 with a nil distinct id sends nothing" do
      bypass = Bypass.open()
      Application.put_env(:engram, :posthog_key, "phc_test_token")
      Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")
      Bypass.stub(bypass, "POST", "/capture/", fn _ -> flunk("captured an opted-out user") end)

      assert :ok = PostHog.capture(nil, "note_created")
      Process.sleep(100)
    end
  end

  describe "server-side properties" do
    test "every server event disables GeoIP, which would locate users at the AWS region" do
      bypass = Bypass.open()
      Application.put_env(:engram, :posthog_key, "phc_test_token")
      Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")
      parent = self()

      Bypass.expect_once(bypass, "POST", "/capture/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:posthog_body, Jason.decode!(body)})
        Plug.Conn.resp(conn, 200, "1")
      end)

      Bypass.expect_once(bypass, "POST", "/batch/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:batch_body, Jason.decode!(body)})
        Plug.Conn.resp(conn, 200, "{}")
      end)

      PostHog.capture("id", "note_created")
      assert :ok = PostHog.set_people([{"id", %{plan: "pro"}}])

      assert_receive {:posthog_body, %{"properties" => %{"$geoip_disable" => true}}}, 1_000
      assert_receive {:batch_body, %{"batch" => [%{"properties" => props}]}}, 1_000
      assert props["$geoip_disable"] == true
      assert props["$set"] == %{"plan" => "pro"}
    end
  end

  describe "set_people/2" do
    test "sends every chunk even when one fails, then reports the failure" do
      bypass = Bypass.open()
      Application.put_env(:engram, :posthog_key, "phc_test_token")
      Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")
      parent = self()

      Bypass.expect(bypass, "POST", "/batch/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [%{"distinct_id" => id}] = Jason.decode!(body)["batch"]
        send(parent, {:sent, id})
        Plug.Conn.resp(conn, if(id == "a", do: 503, else: 200), "{}")
      end)

      assert {:error, _} = PostHog.set_people([{"a", %{}}, {"b", %{}}], 1)
      assert_received {:sent, "a"}
      assert_received {:sent, "b"}
    end
  end
end
