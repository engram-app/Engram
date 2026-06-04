# Paddle Webhook Reliability Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship four observability layers on the Paddle webhook + daily Paddle↔DB reconciliation so silent money-loss drift surfaces within 24 h.

**Architecture:** Wrap webhook handler in `:telemetry.span/3` + structured logs; add Sentry capture wired via LoggerBackend with PII scrubber; add a Paddle-list-subscriptions client callback feeding a daily reconciliation Oban cron that diffs Paddle state against the local `subscriptions` table and logs/Sentry-captures any drift. PromEx/Prometheus deferred to follow-up infra ticket.

**Tech Stack:** Elixir 1.17+, Phoenix 1.8+, Oban, `:telemetry`, `sentry-elixir ~> 10.0`, ExUnit + Mox.

**Spec:** `docs/superpowers/specs/2026-05-31-paddle-webhook-monitoring-design.md`

**Ticket:** engram-app/Engram#244

**Worktree:** `/home/open-claw/documents/code-projects/engram/.worktrees/paddle-webhook-monitoring` on branch `feat/paddle-webhook-monitoring` (branched from `origin/main`).

---

## File Map

### New files

- `lib/engram/paddle/client/mock.ex` — extend existing Mox mock if needed (verify state during implementation; if mock already defined inline in `test_helper.exs` no new file required).
- `lib/engram/billing/reconciliation.ex` — drift detection logic.
- `lib/engram/billing/workers/paddle_reconcile.ex` — Oban worker.
- `lib/engram/sentry/scrubber.ex` — PII before_send callback.
- `lib/mix/tasks/engram.billing.reconcile.ex` — Mix task wrapper.
- `lib/mix/tasks/engram.sentry.smoke.ex` — Sentry pipeline smoke test.
- `test/engram/billing/reconciliation_test.exs` — drift kinds.
- `test/engram/billing/workers/paddle_reconcile_test.exs` — Oban worker.
- `test/engram/sentry/scrubber_test.exs` — scrubber unit tests.

### Modified files

- `lib/engram_web/controllers/webhook_controller.ex` — wrap in `:telemetry.span/3`; bump swallowed-error log to `:error`; structured log on entry/exit; add `Logger.metadata`.
- `lib/engram_web/telemetry.ex` — declare new metric names for forward-compat.
- `lib/engram/paddle/client.ex` — add `@callback list_subscriptions/1`.
- `lib/engram/paddle/client/http.ex` — implement `list_subscriptions/1` with `updated_at[GTE]` filter + pagination.
- `lib/engram/application.ex` — attach `Sentry.LoggerBackend`.
- `mix.exs` — add `{:sentry, "~> 10.0"}`.
- `config/config.exs` — Sentry block; add Logger metadata keys (`:duration_ms`, `:drift_kind`, `:paddle_subscription_id`, `:result`); add crontab entry for `PaddleReconcile`.
- `config/runtime.exs` — wire `SENTRY_DSN` from env.
- `test/engram_web/controllers/webhook_controller_test.exs` — add telemetry + log assertions.
- `test/test_helper.exs` — extend Paddle ClientMock if needed.
- `docs/context/paddle-integration.md` — add "Monitoring" section linking layers.

### Paired workspace PR (separate)

- `docs/context/paddle-v2-launch-runbook.md` (workspace repo) — add "Reconciliation drift response" + manual replay procedure.

---

## Task 1: Structured logs + `:telemetry` span on webhook handler

**Files:**
- Modify: `lib/engram_web/controllers/webhook_controller.ex:28-53`
- Modify: `config/config.exs:78-104` (Logger metadata list)
- Test: `test/engram_web/controllers/webhook_controller_test.exs`

- [ ] **Step 1.1: Add new Logger metadata keys to config**

Edit `config/config.exs` Logger metadata list (alphabetical position). Add:

```elixir
    :drift_kind,
    :duration_ms,
    :paddle_subscription_id,
    :result,
```

Place each in alphabetical order within the existing list (`drift_kind` after `column`, `duration_ms` after `drift_kind`, `paddle_subscription_id` after `normalized_email_hash`, `result` after `request_query`).

- [ ] **Step 1.2: Write failing telemetry-event test**

Add to `test/engram_web/controllers/webhook_controller_test.exs` inside the `describe "POST /webhooks/paddle"` block:

```elixir
test "emits :telemetry.span events on success", %{conn: conn} do
  user = insert(:user)
  ref = :telemetry_test.attach_event_handlers(
    self(),
    [
      [:engram, :paddle, :webhook, :start],
      [:engram, :paddle, :webhook, :stop]
    ]
  )

  payload =
    Jason.encode!(%{
      "event_type" => "subscription.created",
      "event_id" => "ntf_wh_telemetry",
      "data" => %{
        "id" => "sub_wh_telemetry",
        "status" => "trialing",
        "customer_id" => "ctm_wh_telemetry",
        "items" => [%{"price" => %{"id" => "pri_starter_test"}}],
        "current_billing_period" => %{"ends_at" => "2026-05-20T00:00:00Z"},
        "custom_data" => %{"user_id" => user.id}
      }
    })

  ts = System.system_time(:second)
  sig_header = "ts=#{ts};h1=#{sign(ts, payload)}"

  conn
  |> put_req_header("content-type", "application/json")
  |> put_req_header("paddle-signature", sig_header)
  |> post("/webhooks/paddle", payload)

  assert_received {[:engram, :paddle, :webhook, :start], ^ref, _measurements,
                   %{event_type: "subscription.created", event_id: "ntf_wh_telemetry"}}

  assert_received {[:engram, :paddle, :webhook, :stop], ^ref, %{duration: _},
                   %{event_type: "subscription.created", event_id: "ntf_wh_telemetry",
                     result: :ok}}
end
```

- [ ] **Step 1.3: Run test to verify failure**

```bash
mix test test/engram_web/controllers/webhook_controller_test.exs:NNN
```

Expected: FAIL — `assert_received` timeouts. No start/stop events emitted.

- [ ] **Step 1.4: Implement telemetry span in webhook handler**

Replace `webhook_controller.ex:28-53` (the `def paddle/2`) with:

```elixir
def paddle(conn, _params) do
  with {:ok, sig_header} <- get_signature(conn),
       {:ok, payload} <- read_body_once(conn),
       :ok <- verify_signature(payload, sig_header) do
    event = Jason.decode!(payload)
    event_type = event["event_type"]
    event_id = event["event_id"]

    Logger.metadata(
      category: :paddle_webhook,
      event_type: event_type,
      event_id: event_id
    )

    Logger.info("paddle_webhook_received")

    {response, result} =
      :telemetry.span(
        [:engram, :paddle, :webhook],
        %{event_type: event_type, event_id: event_id},
        fn ->
          case Billing.upsert_from_paddle_event(event) do
            {:ok, _} = ok ->
              {{:ok, :handled}, %{event_type: event_type, event_id: event_id, result: :ok}}

            {:error, reason} = err ->
              Logger.error("paddle_webhook_handler_error",
                reason: format_reason(reason)
              )

              {{:error, reason}, %{event_type: event_type, event_id: event_id, result: :error}}
          end
        end
      )

    _ = result

    case response do
      {:ok, _} ->
        Logger.info("paddle_webhook_ok")
        json(conn, %{status: "ok"})

      {:error, _} ->
        json(conn, %{status: "ok"})
    end
  else
    {:error, reason} ->
      conn
      |> put_status(400)
      |> json(%{error: to_string(reason)})
  end
end
```

Notes:
- `:telemetry.span/3` returns `{result, stop_metadata}` per its spec. We discard `stop_metadata` (already passed in) — kept only because the macro returns it.
- Swallowed-error path now `Logger.error` (was `Logger.warning`) so Sentry's logger backend will capture it in Task 3.
- Still returns 200 on swallowed error — reconciliation catches the drift.

- [ ] **Step 1.5: Run telemetry test to verify pass**

```bash
mix test test/engram_web/controllers/webhook_controller_test.exs
```

Expected: PASS, all tests in file.

- [ ] **Step 1.6: Write failing exception-event test**

Add another test asserting the `:exception` event fires when `Billing.upsert_from_paddle_event/1` raises. Note this requires arranging an event that breaks parsing — use a payload missing required fields that would crash. Practical pattern:

```elixir
test "emits :exception event when handler raises", %{conn: conn} do
  ref = :telemetry_test.attach_event_handlers(
    self(),
    [[:engram, :paddle, :webhook, :exception]]
  )

  # Payload structure Billing.upsert_from_paddle_event/1 will MatchError on:
  # missing `data` key.
  payload = ~s({"event_type":"subscription.created","event_id":"ntf_wh_raise"})

  ts = System.system_time(:second)
  sig_header = "ts=#{ts};h1=#{sign(ts, payload)}"

  assert_raise FunctionClauseError, fn ->
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("paddle-signature", sig_header)
    |> post("/webhooks/paddle", payload)
  end

  assert_received {[:engram, :paddle, :webhook, :exception], ^ref, %{duration: _},
                   %{event_type: "subscription.created", kind: :error}}
end
```

If `Billing.upsert_from_paddle_event/1` doesn't actually raise on missing data (returns `{:error, _}` instead) — change this test to use `Mox.expect(Engram.BillingMock, ...)` to inject a raise, or skip and document the gap.

**Verification step before continuing:** before writing this test, grep `Billing.upsert_from_paddle_event/1` to confirm whether it raises or returns `{:error, _}` on malformed input. Adjust test setup to actually trigger an exception path.

- [ ] **Step 1.7: Run + verify exception test passes**

If raise path not reachable in handler chain, **delete this test and proceed.** `:telemetry.span/3` documentation guarantees the `:exception` event fires on raise; if no raise path exists today, no test value.

- [ ] **Step 1.8: Commit**

```bash
git add config/config.exs lib/engram_web/controllers/webhook_controller.ex test/engram_web/controllers/webhook_controller_test.exs
git commit -m "feat(paddle): wrap webhook in telemetry span + structured logs

Wrap Billing.upsert_from_paddle_event/1 call in :telemetry.span/3 so
[:engram, :paddle, :webhook, :{start,stop,exception}] events fire on
every webhook. Bump swallowed-error log level from warning to error so
Sentry (next commit) captures the silent-200 path. Add Logger metadata
keys :duration_ms / :result / :drift_kind / :paddle_subscription_id.

Part of #244."
```

---

## Task 2: Declare metric names in `EngramWeb.Telemetry`

**Files:**
- Modify: `lib/engram_web/telemetry.ex`

- [ ] **Step 2.1: Open telemetry.ex and locate the `metrics/0` function**

```bash
grep -n "def metrics" lib/engram_web/telemetry.ex
```

- [ ] **Step 2.2: Add metric declarations**

In the `metrics/0` list, append (preserve existing entries):

```elixir
import Telemetry.Metrics

# Paddle webhook reliability (declared for future PromEx attach; emitted
# via :telemetry.span/3 in EngramWeb.WebhookController.paddle/2).
counter("engram.paddle.webhook.start.count",
  event_name: [:engram, :paddle, :webhook, :start],
  measurement: :system_time,
  tags: [:event_type]
),
summary("engram.paddle.webhook.stop.duration",
  event_name: [:engram, :paddle, :webhook, :stop],
  measurement: :duration,
  unit: {:native, :millisecond},
  tags: [:event_type, :result]
),
counter("engram.paddle.webhook.exception.count",
  event_name: [:engram, :paddle, :webhook, :exception],
  measurement: :duration,
  tags: [:event_type, :kind]
)
```

If `import Telemetry.Metrics` is already at the top, omit duplicate import.

- [ ] **Step 2.3: Run mix compile to verify no warnings**

```bash
mix compile --warnings-as-errors
```

Expected: clean compile.

- [ ] **Step 2.4: Commit**

```bash
git add lib/engram_web/telemetry.ex
git commit -m "feat(paddle): declare paddle webhook metrics for PromEx attach

Forward-compat: when PromEx lands (engram-infra follow-up ticket) it
finds these declarations and attaches automatically.

Part of #244."
```

---

## Task 3: Add Sentry dep + base configuration

**Files:**
- Modify: `mix.exs`
- Modify: `config/config.exs`
- Modify: `config/runtime.exs`
- Modify: `lib/engram/application.ex`

- [ ] **Step 3.1: Add Sentry dep to mix.exs**

In the `deps/0` list:

```elixir
{:sentry, "~> 10.0"},
```

- [ ] **Step 3.2: Fetch deps**

```bash
mix deps.get
```

Expected: `sentry` + transitive deps downloaded; lockfile updated.

- [ ] **Step 3.3: Add Sentry config block to config/config.exs**

Append after the existing `config :engram, EngramWeb.RateLimiter, …` block (before `import_config`):

```elixir
# Paddle webhook + general exception capture. DSN comes from env at
# runtime; unset DSN disables capture (safe for self-host + dev).
config :sentry,
  environment_name: Mix.env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  context_lines: 5,
  included_environments: [:prod, :staging],
  before_send: {Engram.Sentry.Scrubber, :scrub}
```

- [ ] **Step 3.4: Wire DSN in config/runtime.exs**

Inside the `if config_env() == :prod do` block (and any staging branch), add:

```elixir
config :sentry, dsn: System.get_env("SENTRY_DSN")
```

If the file separates prod and staging via env var rather than block, locate the right spot — search for `config :engram,` blocks in runtime.exs and place near the bottom of the matching block.

- [ ] **Step 3.5: Attach Sentry.LoggerBackend in Application.start/2**

In `lib/engram/application.ex`, locate `def start/2`. Before the `Supervisor.start_link(...)` call, add:

```elixir
:logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
  config: %{
    metadata: [:category, :event_type, :event_id, :paddle_subscription_id, :drift_kind, :reason]
  }
})
```

Note: Sentry 10.x uses `Sentry.LoggerHandler` (`:logger` handler, not Backend). Verify name vs version after `mix deps.get`.

- [ ] **Step 3.6: Compile + verify**

```bash
mix compile --warnings-as-errors
```

Expected: clean.

- [ ] **Step 3.7: Commit**

```bash
git add mix.exs mix.lock config/config.exs config/runtime.exs lib/engram/application.ex
git commit -m "feat(sentry): add sentry-elixir dep + base config + logger handler

DSN unset → captures disabled (self-host + dev). before_send scrubber
in next commit. Part of #244."
```

---

## Task 4: Sentry PII scrubber

**Files:**
- Create: `lib/engram/sentry/scrubber.ex`
- Create: `test/engram/sentry/scrubber_test.exs`

- [ ] **Step 4.1: Write failing scrubber test**

Create `test/engram/sentry/scrubber_test.exs`:

```elixir
defmodule Engram.Sentry.ScrubberTest do
  use ExUnit.Case, async: true

  alias Engram.Sentry.Scrubber

  describe "scrub/1" do
    test "drops request body" do
      event = %Sentry.Event{request: %{data: "secret"}}
      assert %Sentry.Event{request: %{data: nil}} = Scrubber.scrub(event)
    end

    test "redacts email/phone/address fields in extra map" do
      event = %Sentry.Event{
        extra: %{
          customer_email: "u@example.com",
          billing_phone: "+15551234",
          address_line1: "1 Main St",
          unrelated: "keep"
        }
      }

      scrubbed = Scrubber.scrub(event)

      assert scrubbed.extra.customer_email == "[redacted]"
      assert scrubbed.extra.billing_phone == "[redacted]"
      assert scrubbed.extra.address_line1 == "[redacted]"
      assert scrubbed.extra.unrelated == "keep"
    end

    test "redacts nested maps recursively" do
      event = %Sentry.Event{
        extra: %{customer: %{email: "u@example.com", id: "cus_1"}}
      }

      scrubbed = Scrubber.scrub(event)
      assert scrubbed.extra.customer.email == "[redacted]"
      assert scrubbed.extra.customer.id == "cus_1"
    end

    test "returns event unchanged when no scrubbable fields present" do
      event = %Sentry.Event{extra: %{just_ids: "ok"}}
      assert Scrubber.scrub(event) == event
    end
  end
end
```

- [ ] **Step 4.2: Run scrubber test to verify failure**

```bash
mix test test/engram/sentry/scrubber_test.exs
```

Expected: FAIL — `Engram.Sentry.Scrubber` not defined.

- [ ] **Step 4.3: Implement scrubber**

Create `lib/engram/sentry/scrubber.ex`:

```elixir
defmodule Engram.Sentry.Scrubber do
  @moduledoc """
  Sentry `:before_send` callback. Strips PII from event payloads before
  they leave the process for Sentry's API.

  Paddle webhooks echo customer email/address/phone — make sure none of
  that reaches Sentry. The conservative default is to drop the raw request
  body entirely; structured logger metadata supplies the actionable
  context.
  """

  @pii_substrings ~w(email phone address card iban pan ssn)

  @spec scrub(Sentry.Event.t()) :: Sentry.Event.t()
  def scrub(%Sentry.Event{} = event) do
    event
    |> drop_request_data()
    |> redact_extra()
  end

  defp drop_request_data(%Sentry.Event{request: %{data: _} = req} = event) do
    %{event | request: %{req | data: nil}}
  end

  defp drop_request_data(event), do: event

  defp redact_extra(%Sentry.Event{extra: extra} = event) when is_map(extra) do
    %{event | extra: redact_map(extra)}
  end

  defp redact_extra(event), do: event

  defp redact_map(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      cond do
        pii_key?(k) -> {k, "[redacted]"}
        is_map(v) -> {k, redact_map(v)}
        is_list(v) -> {k, redact_list(v)}
        true -> {k, v}
      end
    end)
  end

  defp redact_list(list) when is_list(list) do
    Enum.map(list, fn
      v when is_map(v) -> redact_map(v)
      v when is_list(v) -> redact_list(v)
      v -> v
    end)
  end

  defp pii_key?(key) when is_atom(key), do: pii_key?(Atom.to_string(key))

  defp pii_key?(key) when is_binary(key) do
    downcased = String.downcase(key)
    Enum.any?(@pii_substrings, &String.contains?(downcased, &1))
  end

  defp pii_key?(_), do: false
end
```

- [ ] **Step 4.4: Run scrubber test to verify pass**

```bash
mix test test/engram/sentry/scrubber_test.exs
```

Expected: PASS, 4 tests.

- [ ] **Step 4.5: Commit**

```bash
git add lib/engram/sentry/scrubber.ex test/engram/sentry/scrubber_test.exs
git commit -m "feat(sentry): add PII before_send scrubber

Drops request body, redacts any extra key matching email/phone/address/
card/iban/pan/ssn (atom or string), recurses into maps + lists.

Part of #244."
```

---

## Task 5: `mix engram.sentry.smoke` task

**Files:**
- Create: `lib/mix/tasks/engram.sentry.smoke.ex`

- [ ] **Step 5.1: Implement smoke task (no test — staging verification only)**

Create `lib/mix/tasks/engram.sentry.smoke.ex`:

```elixir
defmodule Mix.Tasks.Engram.Sentry.Smoke do
  @moduledoc """
  Smoke-test the Sentry pipeline end-to-end. Captures one event with a
  known marker so an operator can confirm the project ID + DSN + scrubber
  + ingestion all work.

  Run on staging:

      mix engram.sentry.smoke

  Then check the Sentry project for an event with
  `tags.smoke_marker = "engram.sentry.smoke"`.
  """
  use Mix.Task

  @shortdoc "Send one synthetic Sentry capture to verify the pipeline"

  @impl true
  def run(_argv) do
    Mix.Task.run("app.start")

    Sentry.capture_message(
      "engram.sentry.smoke — pipeline test",
      level: :error,
      tags: %{smoke_marker: "engram.sentry.smoke"}
    )

    Process.sleep(1_500)
    IO.puts("Sentry smoke event dispatched. Check the project for tag smoke_marker=engram.sentry.smoke.")
  end
end
```

- [ ] **Step 5.2: Compile + verify**

```bash
mix compile --warnings-as-errors
mix help engram.sentry.smoke
```

Expected: clean compile, `mix help` shows the task.

- [ ] **Step 5.3: Commit**

```bash
git add lib/mix/tasks/engram.sentry.smoke.ex
git commit -m "feat(sentry): add mix engram.sentry.smoke task

One-shot capture with smoke_marker tag — operator runs on staging after
deploy to confirm DSN + scrubber + Sentry ingestion all work.

Part of #244."
```

---

## Task 6: Add `list_subscriptions/1` callback to Paddle Client

**Files:**
- Modify: `lib/engram/paddle/client.ex`
- Modify: `lib/engram/paddle/client/http.ex`
- Modify: `test/support/mocks.ex` (or wherever `Engram.Paddle.ClientMock` is defined — verify)

- [ ] **Step 6.1: Locate ClientMock definition**

```bash
grep -rn "Engram.Paddle.ClientMock\|defmock.*Paddle" test/ lib/
```

Confirm whether mock is generated via `Mox.defmock` in `test/test_helper.exs` or a support file. The mock auto-picks up new callbacks from the behaviour, so no manual edit usually required.

- [ ] **Step 6.2: Add behaviour callback to client.ex**

In `lib/engram/paddle/client.ex`, after the existing callbacks:

```elixir
@doc """
List subscriptions updated since the given DateTime, paginated.

Paddle endpoint: `GET /subscriptions?updated_at[GTE]={iso}&per_page=200`.
Follows pagination via `meta.pagination.next` until exhausted. Returns
the flattened list of decoded subscription `data` maps.
"""
@callback list_subscriptions(since :: DateTime.t()) ::
            {:ok, [map()]} | {:error, term()}
```

- [ ] **Step 6.3: Write failing test for HTTP impl**

Add to `test/engram/paddle/client/http_test.exs` (or matching file — confirm naming):

```elixir
test "list_subscriptions paginates updated_at[GTE] filter" do
  # Stub Req to return two pages then a terminator.
  bypass = Bypass.open()
  # ... configure base_url to bypass + assert URL contains `updated_at[GTE]`
  # Implementation detail: stub two responses with meta.pagination.next set,
  # then nil. Assert flattened return.
end
```

**Pragmatic note:** if the codebase already has a pattern for stubbing Req (Bypass, Req.Test, Plug-based mock), follow that pattern verbatim — look at existing `*_test.exs` files for `Engram.Paddle.Client.HTTP` and copy the harness setup. Do NOT invent a new mocking style.

- [ ] **Step 6.4: Implement list_subscriptions in HTTP impl**

Add to `lib/engram/paddle/client/http.ex` (signature must match callback):

```elixir
@impl Engram.Paddle.Client
def list_subscriptions(%DateTime{} = since) do
  iso = DateTime.to_iso8601(since)
  list_page("/subscriptions?updated_at[GTE]=#{URI.encode(iso)}&per_page=200", [])
end

defp list_page(path, acc) do
  case request(:get, path) do
    {:ok, %{"data" => data, "meta" => %{"pagination" => %{"next" => nil}}}} ->
      {:ok, Enum.reverse([data | acc] |> List.flatten())}

    {:ok, %{"data" => data, "meta" => %{"pagination" => %{"next" => next_url}}}} ->
      next_path = next_url |> URI.parse() |> Map.get(:path)
      next_query = next_url |> URI.parse() |> Map.get(:query)
      list_page("#{next_path}?#{next_query}", [data | acc])

    {:ok, %{"data" => data}} ->
      {:ok, List.flatten([data | acc])}

    {:error, _} = err ->
      err
  end
end
```

If existing `Engram.Paddle.Client.HTTP` exposes a private `request/2` use it; otherwise mirror the helper pattern used by sibling functions in that file.

- [ ] **Step 6.5: Run HTTP impl test to verify pass**

```bash
mix test test/engram/paddle/client/http_test.exs
```

- [ ] **Step 6.6: Commit**

```bash
git add lib/engram/paddle/client.ex lib/engram/paddle/client/http.ex test/engram/paddle/client/http_test.exs
git commit -m "feat(paddle): list_subscriptions/1 callback with pagination

Returns every subscription updated since the given DateTime, flattened
across pages. Feeds Engram.Billing.Reconciliation in next commit.

Part of #244."
```

---

## Task 7: Reconciliation drift detection

**Files:**
- Create: `lib/engram/billing/reconciliation.ex`
- Create: `test/engram/billing/reconciliation_test.exs`

- [ ] **Step 7.1: Write failing tests for each drift kind**

Create `test/engram/billing/reconciliation_test.exs`:

```elixir
defmodule Engram.Billing.ReconciliationTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Billing.Reconciliation

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "run/1" do
    test "no drift when Paddle and local match" do
      user = insert(:user)
      _sub = insert(:subscription,
        user_id: user.id,
        paddle_subscription_id: "sub_ok",
        paddle_customer_id: "ctm_ok",
        tier: "starter",
        status: "active",
        current_period_end: ~U[2026-06-30 00:00:00Z]
      )

      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok,
         [
           %{
             "id" => "sub_ok",
             "status" => "active",
             "customer_id" => "ctm_ok",
             "items" => [%{"price" => %{"id" => "pri_starter_test"}}],
             "current_billing_period" => %{"ends_at" => "2026-06-30T00:00:00Z"}
           }
         ]}
      end)

      assert %{drift: []} = Reconciliation.run(7)
    end

    test "detects :missing_local when Paddle has a subscription we don't" do
      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok,
         [
           %{
             "id" => "sub_ghost",
             "status" => "active",
             "customer_id" => "ctm_ghost",
             "items" => [%{"price" => %{"id" => "pri_starter_test"}}],
             "current_billing_period" => %{"ends_at" => "2026-06-30T00:00:00Z"}
           }
         ]}
      end)

      assert %{drift: [%{kind: :missing_local, subscription_id: "sub_ghost"}]} =
               Reconciliation.run(7)
    end

    test "detects :status_mismatch" do
      user = insert(:user)
      insert(:subscription,
        user_id: user.id,
        paddle_subscription_id: "sub_status",
        paddle_customer_id: "ctm_status",
        tier: "starter",
        status: "active",
        current_period_end: ~U[2026-06-30 00:00:00Z]
      )

      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok,
         [
           %{
             "id" => "sub_status",
             "status" => "past_due",
             "customer_id" => "ctm_status",
             "items" => [%{"price" => %{"id" => "pri_starter_test"}}],
             "current_billing_period" => %{"ends_at" => "2026-06-30T00:00:00Z"}
           }
         ]}
      end)

      assert %{drift: [%{kind: :status_mismatch, subscription_id: "sub_status"}]} =
               Reconciliation.run(7)
    end

    test "detects :tier_mismatch" do
      user = insert(:user)
      insert(:subscription,
        user_id: user.id,
        paddle_subscription_id: "sub_tier",
        paddle_customer_id: "ctm_tier",
        tier: "starter",
        status: "active",
        current_period_end: ~U[2026-06-30 00:00:00Z]
      )

      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok,
         [
           %{
             "id" => "sub_tier",
             "status" => "active",
             "customer_id" => "ctm_tier",
             "items" => [%{"price" => %{"id" => "pri_pro_test"}}],
             "current_billing_period" => %{"ends_at" => "2026-06-30T00:00:00Z"}
           }
         ]}
      end)

      assert %{drift: [%{kind: :tier_mismatch, subscription_id: "sub_tier"}]} =
               Reconciliation.run(7)
    end

    test "detects :period_mismatch beyond 2-minute skew" do
      user = insert(:user)
      insert(:subscription,
        user_id: user.id,
        paddle_subscription_id: "sub_period",
        paddle_customer_id: "ctm_period",
        tier: "starter",
        status: "active",
        current_period_end: ~U[2026-06-30 00:00:00Z]
      )

      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok,
         [
           %{
             "id" => "sub_period",
             "status" => "active",
             "customer_id" => "ctm_period",
             "items" => [%{"price" => %{"id" => "pri_starter_test"}}],
             "current_billing_period" => %{"ends_at" => "2026-07-31T00:00:00Z"}
           }
         ]}
      end)

      assert %{drift: [%{kind: :period_mismatch, subscription_id: "sub_period"}]} =
               Reconciliation.run(7)
    end

    test "no-ops when paddle disabled (PADDLE_API_KEY unset)" do
      original = Application.get_env(:engram, :billing_enabled)
      Application.put_env(:engram, :billing_enabled, false)
      on_exit(fn -> Application.put_env(:engram, :billing_enabled, original) end)

      assert %{drift: [], paddle_total: 0, local_total: 0, skipped: :billing_disabled} =
               Reconciliation.run(7)
    end
  end
end
```

- [ ] **Step 7.2: Run tests to verify failure**

```bash
mix test test/engram/billing/reconciliation_test.exs
```

Expected: FAIL — `Engram.Billing.Reconciliation` undefined.

- [ ] **Step 7.3: Implement Reconciliation**

Create `lib/engram/billing/reconciliation.ex`:

```elixir
defmodule Engram.Billing.Reconciliation do
  @moduledoc """
  Diff Paddle subscription state against the local `subscriptions` table.

  Ground truth: Paddle. Anything we have that Paddle doesn't, or vice
  versa, is drift. Drift gets logged at `:error` level so Sentry's
  LoggerHandler captures it. Returns a summary map; does not raise.

  Self-host (`:billing_enabled` config false) short-circuits to a no-op.
  """

  require Logger

  alias Engram.Repo
  alias Engram.Billing.Subscription

  import Ecto.Query

  @period_skew_seconds 120

  @type drift_entry :: %{
          subscription_id: String.t(),
          kind: :missing_local | :status_mismatch | :tier_mismatch | :period_mismatch,
          paddle: term(),
          local: term() | nil
        }

  @type result :: %{
          paddle_total: non_neg_integer(),
          local_total: non_neg_integer(),
          drift: [drift_entry()],
          skipped: nil | :billing_disabled
        }

  @spec run(pos_integer()) :: result()
  def run(days_back) when is_integer(days_back) and days_back > 0 do
    if Application.get_env(:engram, :billing_enabled, false) do
      do_run(days_back)
    else
      Logger.info("paddle_reconcile_skipped", reason: "billing_disabled")
      %{paddle_total: 0, local_total: 0, drift: [], skipped: :billing_disabled}
    end
  end

  defp do_run(days_back) do
    since = DateTime.utc_now() |> DateTime.add(-days_back * 86_400, :second)

    case Engram.Paddle.Client.impl().list_subscriptions(since) do
      {:ok, paddle_subs} ->
        local_subs = recent_local_subscriptions(since)
        local_by_paddle_id = Map.new(local_subs, &{&1.paddle_subscription_id, &1})
        drift = Enum.flat_map(paddle_subs, &classify(&1, local_by_paddle_id))

        log_summary(paddle_subs, local_subs, drift)

        Enum.each(drift, &Logger.error("paddle_reconciliation_drift",
          category: :paddle_reconcile,
          drift_kind: &1.kind,
          paddle_subscription_id: &1.subscription_id
        ))

        %{
          paddle_total: length(paddle_subs),
          local_total: length(local_subs),
          drift: drift,
          skipped: nil
        }

      {:error, reason} ->
        Logger.error("paddle_reconcile_fetch_failed", reason: inspect(reason))
        %{paddle_total: 0, local_total: 0, drift: [], skipped: nil}
    end
  end

  defp recent_local_subscriptions(since) do
    from(s in Subscription, where: s.updated_at >= ^since)
    |> Repo.all()
  end

  defp classify(paddle_sub, local_by_id) do
    id = paddle_sub["id"]
    local = Map.get(local_by_id, id)

    cond do
      is_nil(local) ->
        [%{subscription_id: id, kind: :missing_local, paddle: paddle_sub, local: nil}]

      paddle_sub["status"] != local.status ->
        [%{
          subscription_id: id,
          kind: :status_mismatch,
          paddle: paddle_sub["status"],
          local: local.status
        }]

      paddle_tier(paddle_sub) != local.tier ->
        [%{
          subscription_id: id,
          kind: :tier_mismatch,
          paddle: paddle_tier(paddle_sub),
          local: local.tier
        }]

      period_mismatch?(paddle_sub, local) ->
        [%{
          subscription_id: id,
          kind: :period_mismatch,
          paddle: paddle_sub["current_billing_period"]["ends_at"],
          local: local.current_period_end
        }]

      true ->
        []
    end
  end

  defp paddle_tier(paddle_sub) do
    price_id =
      paddle_sub
      |> Map.get("items", [])
      |> List.first()
      |> case do
        %{"price" => %{"id" => id}} -> id
        _ -> nil
      end

    Engram.Billing.tier_from_price_id(price_id)
  end

  defp period_mismatch?(paddle_sub, local) do
    with %{"ends_at" => paddle_ends_at} <- paddle_sub["current_billing_period"],
         {:ok, paddle_dt, _} <- DateTime.from_iso8601(paddle_ends_at),
         %DateTime{} = local_dt <- local.current_period_end do
      abs(DateTime.diff(paddle_dt, local_dt, :second)) > @period_skew_seconds
    else
      _ -> false
    end
  end

  defp log_summary(paddle, local, drift) do
    Logger.info("paddle_reconcile_summary",
      category: :paddle_reconcile,
      reason: "summary",
      message:
        "paddle=#{length(paddle)} local=#{length(local)} drift=#{length(drift)}"
    )
  end
end
```

**Dependency:** the implementation calls `Engram.Billing.tier_from_price_id/1`. Verify this function exists by `grep tier_from_price_id lib/engram/billing.ex`. If it doesn't but a different price-id → tier mapper does (e.g. `Engram.Billing.Plan.from_price_id/1`), update the call site accordingly. If no such function exists, add a thin one inside `Engram.Billing` first.

- [ ] **Step 7.4: Run tests to verify pass**

```bash
mix test test/engram/billing/reconciliation_test.exs
```

Expected: PASS, 6 tests.

- [ ] **Step 7.5: Commit**

```bash
git add lib/engram/billing/reconciliation.ex test/engram/billing/reconciliation_test.exs
git commit -m "feat(billing): reconciliation module — paddle vs local diff

Returns {paddle_total, local_total, drift, skipped}. Detects four drift
kinds: missing_local, status_mismatch, tier_mismatch, period_mismatch
(2-minute skew tolerance). Each drift entry logged at error so Sentry
captures. Self-host no-ops when :billing_enabled is false.

Part of #244."
```

---

## Task 8: `mix engram.billing.reconcile` task

**Files:**
- Create: `lib/mix/tasks/engram.billing.reconcile.ex`

- [ ] **Step 8.1: Implement Mix task**

Create `lib/mix/tasks/engram.billing.reconcile.ex`:

```elixir
defmodule Mix.Tasks.Engram.Billing.Reconcile do
  @moduledoc """
  Reconcile the local `subscriptions` table against Paddle.

      mix engram.billing.reconcile          # 7 days
      mix engram.billing.reconcile --days 30

  Prints a summary map. Drift entries are also written to the structured
  log at `:error` level so Sentry captures them.
  """
  use Mix.Task

  @shortdoc "Reconcile local subscriptions against Paddle"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [days: :integer])
    days = Keyword.get(opts, :days, 7)

    Mix.Task.run("app.start")

    days
    |> Engram.Billing.Reconciliation.run()
    |> IO.inspect(label: "reconciliation result")
  end
end
```

Per `feedback_mix_task_in_release`: when invoking from a release shell, do **not** call `Mix.Tasks.Engram.Billing.Reconcile.run/1` — inline the body. The Oban worker in Task 9 is the production path.

- [ ] **Step 8.2: Compile + verify task registered**

```bash
mix compile --warnings-as-errors
mix help engram.billing.reconcile
```

- [ ] **Step 8.3: Commit**

```bash
git add lib/mix/tasks/engram.billing.reconcile.ex
git commit -m "feat(billing): mix engram.billing.reconcile task

Local + dev-shell entrypoint to Reconciliation.run/1. Oban worker (next
commit) is the production path.

Part of #244."
```

---

## Task 9: Oban worker + crontab entry

**Files:**
- Create: `lib/engram/billing/workers/paddle_reconcile.ex`
- Create: `test/engram/billing/workers/paddle_reconcile_test.exs`
- Modify: `config/config.exs` (crontab block)

- [ ] **Step 9.1: Write failing worker test**

Create `test/engram/billing/workers/paddle_reconcile_test.exs`:

```elixir
defmodule Engram.Billing.Workers.PaddleReconcileTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "perform/1 calls Reconciliation.run/1 with 7-day default" do
    original = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, original) end)

    Engram.Paddle.ClientMock
    |> expect(:list_subscriptions, fn _since -> {:ok, []} end)

    assert :ok = perform_job(Engram.Billing.Workers.PaddleReconcile, %{})
  end
end
```

- [ ] **Step 9.2: Run test to verify failure**

```bash
mix test test/engram/billing/workers/paddle_reconcile_test.exs
```

Expected: FAIL — module undefined.

- [ ] **Step 9.3: Implement worker**

Create `lib/engram/billing/workers/paddle_reconcile.ex`:

```elixir
defmodule Engram.Billing.Workers.PaddleReconcile do
  @moduledoc """
  Daily Oban cron worker. Calls `Engram.Billing.Reconciliation.run/1` with
  a 7-day window. Drift is logged at :error and captured by Sentry — the
  worker itself always returns :ok so Oban doesn't mark the job failed
  for data drift (which is signal, not job failure).
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = Engram.Billing.Reconciliation.run(7)
    :ok
  end
end
```

- [ ] **Step 9.4: Add crontab entry to config/config.exs**

In the `Oban.Plugins.Cron` crontab list (config/config.exs around line 45), append after `OverrideExpirySweep`:

```elixir
{"0 2 * * *", Engram.Billing.Workers.PaddleReconcile},
```

Place between `OverrideExpirySweep` (`"0 3 * * *"`) and the others, ordered by time.

- [ ] **Step 9.5: Run worker test to verify pass**

```bash
mix test test/engram/billing/workers/paddle_reconcile_test.exs
```

Expected: PASS.

- [ ] **Step 9.6: Commit**

```bash
git add lib/engram/billing/workers/paddle_reconcile.ex test/engram/billing/workers/paddle_reconcile_test.exs config/config.exs
git commit -m "feat(billing): Oban cron worker for daily paddle reconcile

Runs Reconciliation.run(7) daily at 02:00 UTC. Worker returns :ok
regardless of drift — Oban shouldn't mark drift as job failure. Drift
surfaces via Sentry from the Logger backend.

Part of #244."
```

---

## Task 10: Update backend docs/context with monitoring section

**Files:**
- Modify: `docs/context/paddle-integration.md`

- [ ] **Step 10.1: Locate paddle-integration.md and read existing structure**

```bash
head -40 docs/context/paddle-integration.md
```

- [ ] **Step 10.2: Append "Monitoring" section**

Append to `docs/context/paddle-integration.md`:

```markdown
## Monitoring (added 2026-05-31, PR #244)

Four observability layers on the webhook + a daily reconciliation:

1. **Structured logs** — `Logger.metadata(category: :paddle_webhook, event_type:, event_id:)` stamped on every webhook. Entry/success log `:info`; swallowed-error path bumped to `:error` so Sentry's LoggerHandler captures it. See `EngramWeb.WebhookController.paddle/2`.
2. **`:telemetry` span** — `[:engram, :paddle, :webhook, :{start,stop,exception}]` emitted by `:telemetry.span/3` wrap. Declared in `EngramWeb.Telemetry.metrics/0` for forward-compat with PromEx (see follow-up infra ticket).
3. **Sentry capture** — DSN from `SENTRY_DSN`; unset disables. `Engram.Sentry.Scrubber` strips email/phone/address/card/iban/pan/ssn fields from extra/request payloads before send. Smoke-test the pipeline: `mix engram.sentry.smoke`.
4. **Daily reconciliation** — `Engram.Billing.Workers.PaddleReconcile` runs at 02:00 UTC, calls `Engram.Billing.Reconciliation.run(7)`. Detects four drift kinds: `:missing_local`, `:status_mismatch`, `:tier_mismatch`, `:period_mismatch` (±2 min skew tolerance). Manual run: `mix engram.billing.reconcile --days N`.

### Drift response

When reconciliation logs `paddle_reconciliation_drift`:

1. Note `paddle_subscription_id` + `drift_kind` from Sentry/log.
2. `paddle get /subscriptions/<id>` to confirm current Paddle state.
3. Manually upsert the local row OR replay the webhook event:
   - Find the event in Paddle dashboard → Notifications → search by `subscription_id`.
   - Use Paddle's "Replay" button to re-send. Webhook handler is idempotent (`upsert_from_paddle_event/1`).
4. Re-run `mix engram.billing.reconcile` to confirm drift resolved.

### Self-host

Both Sentry (`SENTRY_DSN` unset) and reconciliation (`:billing_enabled` false) no-op cleanly on self-host.
```

- [ ] **Step 10.3: Commit**

```bash
git add docs/context/paddle-integration.md
git commit -m "docs(paddle): monitoring section + drift response procedure

Part of #244."
```

---

## Task 11: Final verification + push

- [ ] **Step 11.1: Run full mix test suite**

```bash
mix test
```

Expected: all tests pass. If any pre-existing test fails, surface to user — per `feedback_diagnose_flakes` don't accept silent reruns.

- [ ] **Step 11.2: Run mix compile with warnings-as-errors**

```bash
mix compile --warnings-as-errors
```

- [ ] **Step 11.3: Run credo + format check**

```bash
mix credo --strict
mix format --check-formatted
```

Fix any findings before pushing.

- [ ] **Step 11.4: Push branch**

```bash
git push -u origin feat/paddle-webhook-monitoring
```

- [ ] **Step 11.5: Open PR**

```bash
gh pr create --title "feat(billing): paddle webhook reliability monitoring (#244)" --body "$(cat <<'EOF'
Closes #244.

Ships four observability layers + daily Paddle↔DB reconciliation:

1. Structured logs on every webhook entry/exit/error
2. `:telemetry` span events (PromEx-ready)
3. Sentry capture with PII before_send scrubber + `mix engram.sentry.smoke` for pipeline verification
4. Daily reconciliation Oban cron (`Engram.Billing.Workers.PaddleReconcile`) that diffs Paddle subscriptions against the local table and logs/captures any drift

Drops Prometheus alert rules from ticket acceptance — moved to engram-infra follow-up (we have no Prometheus deployed; wiring PromEx alone would be a dead pipe). Spec: `docs/superpowers/specs/2026-05-31-paddle-webhook-monitoring-design.md`.

## Test plan

- [x] Unit tests pass: `mix test`
- [x] Compile clean: `mix compile --warnings-as-errors`
- [x] Lint clean: `mix credo --strict && mix format --check-formatted`
- [ ] Staging deploy: run `mix engram.sentry.smoke` and confirm Sentry receives the marker event
- [ ] Staging deploy: trigger a test webhook (Paddle dashboard) and confirm logs + telemetry events emit
- [ ] Staging deploy: take backend offline 5 min during a webhook delivery, verify Paddle retries land + reconciliation flags any persistent drift

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 11.6: Workspace PR for runbook update**

Switch to engram-workspace repo (different worktree — coordinate with user; this is OUT of the backend worktree). Create branch + edit `docs/context/paddle-v2-launch-runbook.md` adding a "Reconciliation drift response" section that links to `backend/docs/context/paddle-integration.md` for the procedure (avoid duplication — point to the backend doc).

- [ ] **Step 11.7: File follow-up issue on engram-infra**

```bash
gh issue create -R engram-app/engram-infra \
  --title "Deploy Prometheus/Grafana stack + wire PromEx for paddle webhook alerts" \
  --body "$(cat <<'EOF'
Follow-up to engram-app/Engram#244.

That ticket shipped structured logs + `:telemetry` events + Sentry + daily reconciliation, but left out the original "alert rules deployed (5xx rate, exception rate)" acceptance because we have no Prometheus deployment to wire PromEx into.

Scope:

- Deploy Prometheus on FastRaid (and later AWS, per #266) with scrape config pointed at engram backend `/metrics` (PromEx exposes once wired).
- Add `:prom_ex` Hex dep to engram + wire it into `EngramWeb.Telemetry`. The metric *declarations* for paddle webhook are already there.
- Alertmanager rules:
  - `engram_paddle_webhook_stop_count{result="error"}` rate > 0 over 5 min → page
  - `engram_paddle_webhook_exception_count` rate > 0 → page
  - HTTP 5xx rate on `/webhooks/paddle` > 1% over 5 min → page
- Grafana dashboard.
EOF
)"
```

---

## Self-review notes

Plan covers spec sections:
- §Goals 1-5 ✓ (Tasks 1-9)
- §Non-Goals respected (no Prometheus deploy in this PR; reconciliation table not added; no auto-heal)
- §Architecture all four layers ✓ (Tasks 1-9)
- §Schema changes "none" ✓
- §Config changes both env vars handled ✓
- §Acceptance items mapped to tasks ✓
- §Follow-up issues — Step 11.7 files the infra ticket
- §Open questions — left for user to resolve at PR review time (env-name decision is just a config-string choice; window-default is in code)

Type consistency: `Engram.Billing.tier_from_price_id/1` referenced in Task 7 must exist; flagged with verification step. `Engram.Paddle.Client.impl/0` used per existing pattern. Oban worker queue `:maintenance` matches existing config (`queues: [embed: 5, reindex: 1, maintenance: 2, crypto_backfill: 1]`).
