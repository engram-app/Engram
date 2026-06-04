defmodule Engram.Observability.EmittersTest do
  @moduledoc """
  Per-emitter Bypass tests for PR8. Each test exercises the production
  code path (Notes context, Search context, controller, or forwarder
  module) and asserts the PostHog capture body landed with the expected
  event name + distinct_id + properties.

  These tests are NOT a contract on the wire format (PostHog accepts a
  range of shapes — see Engram.Observability.PostHogTest); they pin the
  funnel-join invariant: `distinct_id` MUST be the Clerk user id, so the
  server-emitted events join with the frontend's `posthog.identify` call.

  `async: false` because every test mutates the global Application env
  (:posthog_key, :posthog_host) — Bypass setup is per-test but the env
  is process-global.
  """

  use EngramWeb.ConnCase, async: false

  import Mox

  alias Engram.Notes
  alias Engram.Search
  alias EngramWeb.Webhooks.PostHogForwarder

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    prior_key = Application.get_env(:engram, :posthog_key)
    prior_host = Application.get_env(:engram, :posthog_host)
    Application.put_env(:engram, :posthog_key, "phc_emitters_test")
    Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      Application.put_env(:engram, :posthog_key, prior_key)
      Application.put_env(:engram, :posthog_host, prior_host)
    end)

    %{bypass: bypass}
  end

  # PostHog.capture spawns Task.start — assert_receive needs the bypass to
  # send to *this* process. Wire it through self() captured at expect-time.
  defp expect_capture(bypass) do
    parent = self()

    Bypass.expect_once(bypass, "POST", "/capture/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:posthog_body, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, "1")
    end)
  end

  defp user_with_clerk_id(opts \\ []) do
    ext_id = Keyword.get(opts, :external_id, "user_clerk_#{System.unique_integer([:positive])}")

    user =
      insert(:user, external_id: ext_id)
      |> tap(fn u ->
        insert(:user_limit_override, user: u, key: "vaults_cap", value: %{"v" => -1})
      end)

    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    user
  end

  describe "note_created" do
    test "fires on new note insert with vault_id property", %{bypass: bypass} do
      user = user_with_clerk_id()
      {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
      expect_capture(bypass)

      assert {:ok, _note} =
               Notes.upsert_note(user, vault, %{
                 "path" => "Hello.md",
                 "content" => "# Hello",
                 "mtime" => 1_000.0
               })

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "note_created"
      assert body["distinct_id"] == user.external_id
      assert body["properties"]["vault_id"] == vault.id
    end

    test "does NOT fire on an update to an existing note (idempotent re-push)",
         %{bypass: bypass} do
      user = user_with_clerk_id()
      {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})

      # First insert — burn the single Bypass expectation so a second emit
      # would fail the test (Bypass.expect_once raises on extra calls).
      expect_capture(bypass)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Hello.md",
          "content" => "# v1",
          "mtime" => 1_000.0
        })

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "note_created"

      # Second upsert at the same path — update branch (prev_hash != nil).
      # If the emitter mis-fires we'd see a second POST → Bypass.expect_once
      # raises "expected 1 request, got 2" on test exit.
      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Hello.md",
          "content" => "# v2",
          "mtime" => 2_000.0
        })

      # Give any errant fire-and-forget Task a beat to reach Bypass.
      refute_receive {:posthog_body, _}, 200
    end
  end

  describe "search_performed" do
    test "fires after Qdrant returns with result_count + latency_ms",
         %{bypass: bypass} do
      user = user_with_clerk_id()
      {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})

      # Re-route Qdrant to the same Bypass under a distinct path so we can
      # serve the search response inline.
      Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      parent = self()

      Bypass.expect(bypass, fn conn ->
        case conn.request_path do
          "/capture/" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(parent, {:posthog_body, Jason.decode!(body)})
            Plug.Conn.resp(conn, 200, "1")

          _ ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => []}))
        end
      end)

      assert {:ok, []} = Search.search(user, vault, "anything")

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "search_performed"
      assert body["distinct_id"] == user.external_id
      assert body["properties"]["result_count"] == 0
      assert is_integer(body["properties"]["latency_ms"])
      assert body["properties"]["cross_vault"] == false
    end
  end

  describe "vault_opened" do
    test "fires on GET /vaults/:id success", %{conn: conn, bypass: bypass} do
      user = user_with_clerk_id()
      {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
      expect_capture(bypass)

      conn = conn |> authenticate(user) |> get("/api/vaults/#{vault.id}")

      assert %{"vault" => %{"id" => _}} = json_response(conn, 200)

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "vault_opened"
      assert body["distinct_id"] == user.external_id
      assert body["properties"]["vault_id"] == vault.id
    end
  end

  describe "PostHogForwarder.forward_clerk_event/1" do
    test "user.created → user_signed_up keyed by data.id", %{bypass: bypass} do
      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_clerk_event(%{
          "type" => "user.created",
          "data" => %{"id" => "user_2nXyZclerk"}
        })

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "user_signed_up"
      assert body["distinct_id"] == "user_2nXyZclerk"
    end

    # The session.created key is `data.user_id`, NOT `data.id` — they're
    # different fields in Clerk's payload (session-vs-user resource). A
    # mismatched key here would silently break the funnel.
    test "session.created → user_signed_in keyed by data.user_id",
         %{bypass: bypass} do
      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_clerk_event(%{
          "type" => "session.created",
          "data" => %{"id" => "sess_xyz", "user_id" => "user_2nXyZclerk"}
        })

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "user_signed_in"
      assert body["distinct_id"] == "user_2nXyZclerk"
    end

    test "unhandled event type is a no-op" do
      # No Bypass.expect — any POST would fail the test on exit.
      :ok =
        PostHogForwarder.forward_clerk_event(%{
          "type" => "user.deleted",
          "data" => %{"id" => "user_x"}
        })

      refute_receive {:posthog_body, _}, 100
    end
  end

  describe "PostHogForwarder.forward_paddle_event/2" do
    test "subscription.activated resolves the user via Subscription.user_id and emits with tier + price_id",
         %{bypass: bypass} do
      user = user_with_clerk_id(external_id: "user_paddle_resolve")
      sub = insert(:subscription, user: user, tier: "starter", paddle_subscription_id: "sub_ABC")

      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_paddle_event(
          %{
            "event_type" => "subscription.activated",
            "data" => %{
              "items" => [%{"price" => %{"id" => "pri_starter_monthly"}}]
            }
          },
          sub
        )

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "subscription_started"
      assert body["distinct_id"] == "user_paddle_resolve"
      assert body["properties"]["tier"] == "starter"
      assert body["properties"]["price_id"] == "pri_starter_monthly"
      assert body["properties"]["paddle_subscription_id"] == "sub_ABC"
    end

    test "user without external_id is dropped silently (self-host path)" do
      user = insert(:user, external_id: nil)
      sub = insert(:subscription, user: user, tier: "starter")

      :ok =
        PostHogForwarder.forward_paddle_event(
          %{
            "event_type" => "subscription.activated",
            "data" => %{"items" => [%{"price" => %{"id" => "pri_x"}}]}
          },
          sub
        )

      refute_receive {:posthog_body, _}, 100
    end

    test "non-activated event types no-op (subscription.updated, subscription.canceled, ignored)" do
      user = user_with_clerk_id()
      sub = insert(:subscription, user: user)

      for event_type <- ~w(subscription.updated subscription.canceled subscription.past_due) do
        :ok =
          PostHogForwarder.forward_paddle_event(
            %{"event_type" => event_type, "data" => %{"items" => []}},
            sub
          )
      end

      :ok = PostHogForwarder.forward_paddle_event(%{"event_type" => "transaction.paid"}, :ignored)

      refute_receive {:posthog_body, _}, 100
    end
  end
end
