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
end
