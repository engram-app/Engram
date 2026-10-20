defmodule Engram.Observability.EmittersTest do
  @moduledoc """
  Per-emitter Bypass tests for PR8. Each test exercises the production
  code path (Notes context, Search context, controller, or forwarder
  module) and asserts the PostHog capture body landed with the expected
  event name + distinct_id + properties.

  These tests are NOT a contract on the wire format (PostHog accepts a
  range of shapes — see Engram.Observability.PostHogTest); they pin the
  funnel-join invariant: `distinct_id` MUST be the keyed analytics id
  (`PostHog.analytics_id/1`), not a raw Clerk id, so the server-emitted
  events join with the frontend's `posthog.identify` call.

  `async: false` because every test mutates the global Application env
  (:posthog_key, :posthog_host) — Bypass setup is per-test but the env
  is process-global.
  """

  use EngramWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Engram.Notes
  alias Engram.Observability.PostHog
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

  # For requests that legitimately emit more than one event (an authenticated
  # SPA request also sends a throttled `surface_active`), so `expect_once` would
  # fail the second POST. Tests then match the event they care about by name.
  defp expect_captures(bypass) do
    parent = self()

    Bypass.expect(bypass, "POST", "/capture/", fn conn ->
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
      {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
      expect_capture(bypass)

      assert {:ok, _note} =
               Notes.upsert_note(
                 user,
                 vault,
                 %{
                   "path" => "Hello.md",
                   "content" => "# Hello",
                   "mtime" => 1_000.0
                 },
                 actor: "api"
               )

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "note_created"
      assert body["distinct_id"] == PostHog.analytics_id(user.email)
      assert body["properties"]["vault_id"] == vault.id
      assert body["properties"]["surface"] == "api"
    end

    for {actor, opts, surface} <- [
          {"mcp", [], "mcp"},
          {"api:key-1", [], "api"},
          {"system", [announce_vault_populated: false], "welcome"},
          {"sync", [surface: "web"], "web"},
          {"sync", [surface: "obsidian_sync"], "obsidian_sync"},
          {"sync", [], "other"}
        ] do
      test "surface is #{surface} for actor #{actor} #{inspect(opts)}", %{bypass: bypass} do
        user = user_with_clerk_id()
        {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
        expect_capture(bypass)

        {:ok, _} =
          Notes.upsert_note(
            user,
            vault,
            %{"path" => "S.md", "content" => "x", "mtime" => 1_000.0},
            [actor: unquote(actor)] ++ unquote(opts)
          )

        assert_receive {:posthog_body, body}, 1_500
        assert body["event"] == "note_created"
        assert body["properties"]["surface"] == unquote(surface)
      end
    end

    test "does NOT fire on an update to an existing note (idempotent re-push)",
         %{bypass: bypass} do
      user = user_with_clerk_id()
      {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())

      # First insert — burn the single Bypass expectation so a second emit
      # would fail the test (Bypass.expect_once raises on extra calls).
      expect_capture(bypass)

      {:ok, _} =
        Notes.upsert_note(
          user,
          vault,
          %{
            "path" => "Hello.md",
            "content" => "# v1",
            "mtime" => 1_000.0
          },
          actor: "api"
        )

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "note_created"

      # Second upsert at the same path — update branch (prev_hash != nil).
      # If the emitter mis-fires we'd see a second POST → Bypass.expect_once
      # raises "expected 1 request, got 2" on test exit.
      {:ok, _} =
        Notes.upsert_note(
          user,
          vault,
          %{
            "path" => "Hello.md",
            "content" => "# v2",
            "mtime" => 2_000.0
          },
          actor: "api"
        )

      # Give any errant fire-and-forget Task a beat to reach Bypass.
      refute_receive {:posthog_body, _}, 200
    end
  end

  describe "search_performed" do
    test "fires after Qdrant returns with result_count + latency_ms",
         %{bypass: bypass} do
      user = user_with_clerk_id()
      {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())

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
      assert body["distinct_id"] == PostHog.analytics_id(user.email)
      assert body["properties"]["result_count"] == 0
      assert is_integer(body["properties"]["latency_ms"])
      assert body["properties"]["cross_vault"] == false
    end
  end

  describe "vault_opened" do
    test "fires on GET /vaults/:id success", %{conn: conn, bypass: bypass} do
      user = user_with_clerk_id()
      {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
      expect_captures(bypass)

      conn = conn |> authenticate(user) |> get("/api/vaults/#{vault.id}")

      assert %{"vault" => %{"id" => _}} = json_response(conn, 200)

      assert_receive {:posthog_body, %{"event" => "vault_opened"} = body}, 1_500
      assert body["distinct_id"] == PostHog.analytics_id(user.email)
      assert body["properties"]["vault_id"] == vault.id
    end
  end

  describe "PostHogForwarder.forward_clerk_event/1" do
    # PostHog.capture spawns Task.start — assert_receive needs the bypass to
    # send to this process. Wraps a single forward_clerk_event/1 call for
    # "user.created" keyed by `user.external_id` and returns the distinct_id
    # PostHog actually received.
    defp captured_distinct_id_for(user, bypass) do
      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_clerk_event(%{
          "type" => "user.created",
          "data" => %{"id" => user.external_id}
        })

      assert_receive {:posthog_body, body}, 1_500
      body["distinct_id"]
    end

    test "user.created → user_signed_up keyed by data.id", %{bypass: bypass} do
      user = insert_user(email: "clerk-created@example.com", external_id: "user_2nXyZclerk")
      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_clerk_event(%{
          "type" => "user.created",
          "data" => %{"id" => user.external_id}
        })

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "user_signed_up"
      assert body["distinct_id"] == PostHog.analytics_id(user.email)
    end

    # The session.created key is `data.user_id`, NOT `data.id` — they're
    # different fields in Clerk's payload (session-vs-user resource). A
    # mismatched key here would silently break the funnel.
    test "session.created → user_signed_in keyed by data.user_id",
         %{bypass: bypass} do
      user = insert_user(email: "clerk-session@example.com", external_id: "user_2nXyZclerk")
      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_clerk_event(%{
          "type" => "session.created",
          "data" => %{"id" => "sess_xyz", "user_id" => user.external_id}
        })

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "user_signed_in"
      assert body["distinct_id"] == PostHog.analytics_id(user.email)
    end

    test "user_signed_up is keyed by the analytics id, not the clerk id", %{bypass: bypass} do
      user = insert_user(email: "sabio@web.de", external_id: "user_3J50JyLu")

      distinct_id = captured_distinct_id_for(user, bypass)

      assert distinct_id == PostHog.analytics_id(user.email)
      refute distinct_id == user.external_id
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

    test "user.created with no matching local user is dropped silently", %{bypass: _bypass} do
      # No Bypass.expect — any POST would fail the test on exit. Simulates a
      # webhook arriving before (or without) a corresponding local user row.
      :ok =
        PostHogForwarder.forward_clerk_event(%{
          "type" => "user.created",
          "data" => %{"id" => "user_never_provisioned"}
        })

      refute_receive {:posthog_body, _}, 100
    end
  end

  describe "limit_hit" do
    setup do
      EngramWeb.RateLimiter.reset_buckets!()
      :ok
    end

    for {name, assigns, surface} <- [
          {"a Clerk session", %{}, "web"},
          {"an API key", %{current_api_key: %{id: "k"}}, "api"},
          {"a device or OAuth token", %{current_auth_method: :internal_jwt}, "obsidian_sync"}
        ] do
      test "a 402 for #{name} is limit_hit{surface: #{surface}}", %{bypass: bypass} do
        user = user_with_clerk_id()
        expect_capture(bypass)

        conn =
          Enum.reduce(unquote(Macro.escape(assigns)), build_conn(), fn {k, v}, c ->
            assign(c, k, v)
          end)
          |> assign(:current_user, user)

        EngramWeb.LimitResponse.halt(conn, "vaults_cap_exceeded", :vaults_cap, 1, 1)

        assert_receive {:posthog_body, body}, 1_500
        assert body["event"] == "limit_hit"
        assert body["properties"]["limit_key"] == "vaults_cap"
        assert body["properties"]["surface"] == unquote(surface)
      end
    end

    test "a 402 with no limit key names the reason instead", %{bypass: bypass} do
      expect_capture(bypass)
      conn = assign(build_conn(), :current_user, user_with_clerk_id())
      EngramWeb.LimitResponse.halt(conn, "account_suspended", nil, nil, nil)

      assert_receive {:posthog_body, body}, 1_500
      assert body["properties"]["limit_key"] == "account_suspended"
    end

    test "a spent ai_searches_per_day budget is limit_hit", %{bypass: bypass} do
      user = user_with_clerk_id()
      insert(:user_limit_override, user: user, key: "ai_searches_per_day", value: %{"v" => 0})
      {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
      expect_capture(bypass)

      assert {:error, :search_cap_exceeded, 0} = Search.search(user, vault, "anything")

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "limit_hit"
      assert body["properties"]["limit_key"] == "ai_searches_per_day"
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
      assert body["distinct_id"] == PostHog.analytics_id(user.email)
      refute body["distinct_id"] == user.external_id
      assert body["properties"]["tier"] == "starter"
      assert body["properties"]["price_id"] == "pri_starter_monthly"
      assert body["properties"]["paddle_subscription_id"] == "sub_ABC"
    end

    test "user with no email is dropped silently (nothing to hash into an analytics id)" do
      # `email` is NOT NULL at the DB level (structure.sql), so an empty
      # string — not nil — is the reachable "no email" shape for a real row.
      user = insert(:user, email: "")
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

    # The distinct_id used to BE the Clerk external_id, so a user without one
    # (self-host, pre-Clerk legacy rows) had nothing to key the event on and
    # the guard dropped it. After the rekey to analytics_id(email), the
    # external_id is never read — a missing external_id is no longer a
    # reason to drop the event, only a missing email is (see the test
    # above). This pins that behavior change on purpose: it is not
    # self-host-safe by itself, only :posthog_key being unset makes
    # self-host a no-op (Engram.Observability.PostHog.capture/3 short-
    # circuits before any network call when :posthog_key is unset — see
    # config().
    test "user with an email but no external_id now emits subscription_started", %{bypass: bypass} do
      user = insert(:user, external_id: nil)

      sub =
        insert(:subscription, user: user, tier: "starter", paddle_subscription_id: "sub_no_ext")

      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_paddle_event(
          %{
            "event_type" => "subscription.activated",
            "data" => %{"items" => [%{"price" => %{"id" => "pri_x"}}]}
          },
          sub
        )

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "subscription_started"
      assert body["distinct_id"] == PostHog.analytics_id(user.email)
    end

    test "subscription_started carries interval and discounted so comps can be excluded",
         %{bypass: bypass} do
      sub = insert(:subscription, user: user_with_clerk_id(), tier: "pro")
      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_paddle_event(
          %{
            "event_type" => "subscription.activated",
            "data" => %{
              "status" => "active",
              "billing_cycle" => %{"interval" => "year", "frequency" => 1},
              "discount" => %{"id" => "dsc_comp"},
              "items" => [%{"price" => %{"id" => "pri_pro_annual_test"}}]
            }
          },
          sub
        )

      assert_receive {:posthog_body, body}, 1_500
      assert body["properties"]["interval"] == "year"
      assert body["properties"]["discounted"] == true
    end

    test "subscription.created while trialing is subscription_trial_started", %{bypass: bypass} do
      user = user_with_clerk_id()
      sub = insert(:subscription, user: user, tier: "starter", status: "trialing")
      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_paddle_event(
          %{
            "event_type" => "subscription.created",
            "data" => %{
              "status" => "trialing",
              "billing_cycle" => %{"interval" => "month", "frequency" => 1},
              "discount" => nil
            }
          },
          sub
        )

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "subscription_trial_started"
      assert body["distinct_id"] == PostHog.analytics_id(user.email)
      assert body["properties"]["tier"] == "starter"
      assert body["properties"]["interval"] == "month"
      assert body["properties"]["discounted"] == false
    end

    test "subscription.created that is not trialing sends nothing (activated covers it)" do
      sub = insert(:subscription, user: user_with_clerk_id(), status: "active")

      :ok =
        PostHogForwarder.forward_paddle_event(
          %{"event_type" => "subscription.created", "data" => %{"status" => "active"}},
          sub
        )

      refute_receive {:posthog_body, _}, 100
    end

    for {name, prev, now, data, kind} <- [
          {"a higher tier", %{tier: "starter", status: "active"}, {"pro", "active"}, %{},
           "upgrade"},
          {"a lower tier", %{tier: "pro", status: "active"}, {"starter", "active"}, %{},
           "downgrade"},
          {"a scheduled cancel", %{tier: "pro", status: "active"}, {"pro", "active"},
           %{"scheduled_change" => %{"action" => "cancel"}}, "cancel_scheduled"},
          {"a return to active", %{tier: "pro", status: "past_due"}, {"pro", "active"}, %{},
           "reactivated"}
        ] do
      test "subscription.updated to #{name} is subscription_changed{#{kind}}", %{bypass: bypass} do
        {tier, status} = unquote(Macro.escape(now))

        sub = %{
          insert(:subscription, user: user_with_clerk_id(), tier: tier, status: status)
          | previous: unquote(Macro.escape(prev))
        }

        expect_capture(bypass)

        :ok =
          PostHogForwarder.forward_paddle_event(
            %{"event_type" => "subscription.updated", "data" => unquote(Macro.escape(data))},
            sub
          )

        assert_receive {:posthog_body, body}, 1_500
        assert body["event"] == "subscription_changed"
        assert body["properties"]["kind"] == unquote(kind)
        assert body["properties"]["from_tier"] == unquote(prev.tier)
        assert body["properties"]["to_tier"] == tier
        assert body["properties"]["status"] == status
      end
    end

    test "subscription.updated with nothing a funnel cares about sends nothing" do
      sub = %{
        insert(:subscription, user: user_with_clerk_id(), tier: "pro", status: "active")
        | previous: %{tier: "pro", status: "active"}
      }

      # A renewal moves the billing period and nothing else.
      :ok =
        PostHogForwarder.forward_paddle_event(
          %{"event_type" => "subscription.updated", "data" => %{"scheduled_change" => nil}},
          sub
        )

      # Trial to active is subscription.activated's event, not a reactivation.
      :ok =
        PostHogForwarder.forward_paddle_event(
          %{"event_type" => "subscription.updated", "data" => %{}},
          %{sub | previous: %{tier: "pro", status: "trialing"}}
        )

      refute_receive {:posthog_body, _}, 100
    end

    test "subscription.canceled is subscription_canceled with the tier it left", %{bypass: bypass} do
      sub = %{
        insert(:subscription, user: user_with_clerk_id(), tier: "pro", status: "canceled")
        | previous: %{tier: "pro", status: "active"}
      }

      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_paddle_event(
          %{"event_type" => "subscription.canceled", "data" => %{}},
          sub
        )

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "subscription_canceled"
      assert body["properties"]["from_tier"] == "pro"
      assert body["properties"]["status"] == "canceled"
    end

    test "subscription.past_due is subscription_past_due", %{bypass: bypass} do
      sub = insert(:subscription, user: user_with_clerk_id(), tier: "starter", status: "past_due")
      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_paddle_event(
          %{"event_type" => "subscription.past_due", "data" => %{}},
          sub
        )

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "subscription_past_due"
      assert body["properties"]["tier"] == "starter"
    end

    test "transaction.completed is payment_completed with bounded amount props", %{bypass: bypass} do
      user = user_with_clerk_id()
      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_paddle_event(
          %{
            "event_type" => "transaction.completed",
            "data" => %{
              "custom_data" => %{"user_id" => user.id},
              "origin" => "subscription_recurring",
              "currency_code" => "USD",
              "discount_id" => nil,
              "details" => %{"totals" => %{"grand_total" => "1400"}},
              "items" => [%{"price" => %{"billing_cycle" => %{"interval" => "month"}}}]
            }
          },
          :ignored
        )

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "payment_completed"
      assert body["distinct_id"] == PostHog.analytics_id(user.email)
      props = body["properties"]
      assert props["amount_bucket"] == "10_25"
      assert props["currency"] == "USD"
      assert props["interval"] == "month"
      assert props["discounted"] == false
      assert props["origin"] == "subscription_recurring"
    end

    test "a fully comped payment buckets as 0 and is discounted", %{bypass: bypass} do
      user = user_with_clerk_id()
      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_paddle_event(
          %{
            "event_type" => "transaction.completed",
            "data" => %{
              "custom_data" => %{"user_id" => user.id},
              "origin" => "web",
              "currency_code" => "EUR",
              "discount_id" => "dsc_comp",
              "details" => %{"totals" => %{"grand_total" => "0"}}
            }
          },
          :ignored
        )

      assert_receive {:posthog_body, body}, 1_500
      assert body["properties"]["amount_bucket"] == "0"
      assert body["properties"]["discounted"] == true
      assert body["properties"]["interval"] == nil
    end

    test "a payment with no resolvable user sends nothing" do
      for custom <- [%{}, %{"user_id" => "not-a-uuid"}, %{"user_id" => Ecto.UUID.generate()}] do
        :ok =
          PostHogForwarder.forward_paddle_event(
            %{
              "event_type" => "transaction.completed",
              "data" => %{"custom_data" => custom, "currency_code" => "USD"}
            },
            :ignored
          )
      end

      refute_receive {:posthog_body, _}, 100
    end

    test "$set of plan waits for the privacy policy that announces traits", %{bypass: bypass} do
      Engram.Legal.Seeder.seed()
      sub = insert(:subscription, user: user_with_clerk_id(), tier: "pro", status: "past_due")

      set_policy_effective = fn date ->
        Engram.Repo.update_all(
          from(v in Engram.Legal.TermsVersion,
            where: v.document == "privacy_policy" and v.version == "2026-10-12"
          ),
          [set: [effective_date: date]],
          skip_tenant_check: true
        )
      end

      event = %{"event_type" => "subscription.past_due", "data" => %{}}

      expect_captures(bypass)
      set_policy_effective.(Date.add(Date.utc_today(), 1))
      :ok = PostHogForwarder.forward_paddle_event(event, sub)
      assert_receive {:posthog_body, before}, 1_500
      refute Map.has_key?(before["properties"], "$set")

      set_policy_effective.(Date.add(Date.utc_today(), -1))
      :ok = PostHogForwarder.forward_paddle_event(event, sub)
      assert_receive {:posthog_body, after_}, 1_500
      # Dunning is still entitled (`Billing.entitled_statuses/0`).
      assert after_["properties"]["$set"] == %{
               "plan" => "pro",
               "subscription_status" => "past_due"
             }
    end

    test "an approved refund or chargeback is refund_issued", %{bypass: bypass} do
      user = user_with_clerk_id()
      sub = insert(:subscription, user: user, tier: "pro")
      expect_capture(bypass)

      :ok =
        PostHogForwarder.forward_paddle_event(
          %{
            "event_type" => "adjustment.updated",
            "data" => %{
              "action" => "refund",
              "status" => "approved",
              "currency_code" => "USD",
              "totals" => %{"total" => "1400"}
            }
          },
          sub
        )

      assert_receive {:posthog_body, body}, 1_500
      assert body["event"] == "refund_issued"
      assert body["distinct_id"] == PostHog.analytics_id(user.email)
      assert body["properties"]["action"] == "refund"
      assert body["properties"]["amount_bucket"] == "10_25"
      assert body["properties"]["currency"] == "USD"
      assert body["properties"]["tier"] == "pro"
    end

    # A chargeback is created approved and then updated (evidence, status
    # detail) while it stays approved: one refund per adjustment, not per event.
    test "refund_issued is sent once per adjustment id", %{bypass: bypass} do
      sub = insert(:subscription, user: user_with_clerk_id(), tier: "pro")
      expect_captures(bypass)

      for {type, id} <- [
            {"adjustment.created", "adj_cb_1"},
            {"adjustment.updated", "adj_cb_1"},
            {"adjustment.updated", "adj_cb_1"},
            {"adjustment.updated", "adj_cb_2"}
          ] do
        :ok =
          PostHogForwarder.forward_paddle_event(
            %{
              "event_type" => type,
              "data" => %{
                "id" => id,
                "action" => "chargeback",
                "status" => "approved",
                "currency_code" => "USD",
                "totals" => %{"total" => "1400"}
              }
            },
            sub
          )
      end

      assert_receive {:posthog_body, %{"event" => "refund_issued"}}, 1_500
      assert_receive {:posthog_body, %{"event" => "refund_issued"}}, 1_500
      refute_receive {:posthog_body, %{"event" => "refund_issued"}}, 300
    end

    test "pending, rejected and credit adjustments send nothing" do
      sub = insert(:subscription, user: user_with_clerk_id())

      for data <- [
            %{"action" => "refund", "status" => "pending_approval"},
            %{"action" => "refund", "status" => "rejected"},
            %{"action" => "credit", "status" => "approved"}
          ] do
        :ok =
          PostHogForwarder.forward_paddle_event(
            %{"event_type" => "adjustment.created", "data" => data},
            sub
          )
      end

      refute_receive {:posthog_body, _}, 100
    end

    test "unhandled event types no-op" do
      :ok = PostHogForwarder.forward_paddle_event(%{"event_type" => "transaction.paid"}, :ignored)
      :ok = PostHogForwarder.forward_paddle_event(%{"event_type" => "subscription.paused"}, :ok)

      refute_receive {:posthog_body, _}, 100
    end
  end
end
