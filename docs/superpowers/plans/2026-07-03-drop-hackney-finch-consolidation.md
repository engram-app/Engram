# Drop hackney: consolidate the backend HTTP stack on Finch/Req — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove hackney from the engram backend entirely so the stock `opentelemetry_exporter` will build without the `h2`/`ts_chatterbox` duplicate-module conflict, by routing every hackney consumer onto the Finch/Mint/Req stack already in the tree.

**Architecture:** Three consumers use hackney: ex_aws (S3+KMS), Sentry, and joken_jwks/Tesla. Point ex_aws at its first-party `ExAws.Request.Req` adapter, give Sentry a small Finch-backed `Sentry.HTTPClient`, and pin the Tesla adapter to `httpc` in base config. Then delete the `ExAwsHackney` shim and drop the `hackney` override from `mix.exs`. This is Release 1: a pure-infrastructure change, no user-facing behavior. Release 2 (rebasing the tracing branch on the now-stock exporter) is out of scope.

**Tech Stack:** Elixir/Phoenix, ex_aws 2.7 (`ExAws.Request.Req`), Finch 0.23 / Mint 1.9 / Req 0.6 (already present), Sentry 10.10 (`Sentry.HTTPClient` behaviour), Tesla (`Tesla.Adapter.Httpc`), Bypass for unit tests.

## Global Constraints

- No em dashes in any code, comment, doc, or commit copy. Use period, comma, or colon.
- Version bump exactly once for the whole branch: `0.5.618` to `0.5.619` in `mix.exs` (done in Task 4, nowhere else).
- Stay on `sentry 10.10`. Do NOT bump Sentry.
- No forks of any dependency.
- Backend pre-push gate must pass: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix sobelow --exit low`.
- Do NOT add `opentelemetry_exporter` or any OTel dep. That is Release 2.
- Run every `mix` command in the FOREGROUND (the shared `_build` lock stalls if a background `mix` holds it).
- After the branch is complete, `mix deps.tree` must contain no `hackney` and no `h2`.

## File Structure

- `lib/engram/observability/sentry_finch_client.ex` (create) — `Sentry.HTTPClient` implementation over Finch.
- `test/engram/observability/sentry_finch_client_test.exs` (create) — unit tests for the Sentry client.
- `lib/engram/storage/ex_aws_hackney.ex` (delete) — the hackney shim, obsolete once ex_aws uses Req.
- `test/engram/storage/s3_test.exs` (modify) — add multipart + head coverage that also characterizes the adapter swap.
- `config/config.exs` (modify) — swap `:ex_aws, :http_client` to Req, add Sentry `client:`, pin Tesla adapter.
- `mix.exs` (modify) — remove the `hackney` override, add explicit `finch`, bump version.
- `.githooks/pre-push` (modify) — add a `mix release` smoke gate guarded on dependency changes.

---

### Task 1: Sentry HTTP client over Finch

**Files:**
- Create: `lib/engram/observability/sentry_finch_client.ex`
- Create: `test/engram/observability/sentry_finch_client_test.exs`
- Modify: `config/config.exs:202-204` (add `client:` to the existing `config :sentry` block)

**Interfaces:**
- Consumes: `Finch` (already available transitively via Req; made an explicit dep in Task 4). `Sentry.HTTPClient` behaviour from sentry 10.10: `child_spec() :: :supervisor.child_spec()` and `post(url :: String.t(), headers, body) :: {:ok, status, headers, body} | {:error, term}`.
- Produces: module `Engram.Observability.SentryFinchClient` with `child_spec/0` and `post/3`. Sentry starts the client via `child_spec/0` when `config :sentry, client:` names it.

- [ ] **Step 1: Write the failing tests**

Create `test/engram/observability/sentry_finch_client_test.exs`:

```elixir
defmodule Engram.Observability.SentryFinchClientTest do
  # async: false — the client's Finch pool is registered under a fixed global
  # name (the module), which the running app may already have started because
  # config.exs names this module as the Sentry client.
  use ExUnit.Case, async: false

  alias Engram.Observability.SentryFinchClient

  setup do
    # The app may already run this Finch pool (config.exs sets it as the Sentry
    # client). Start it under the test supervisor only if it is not already up.
    unless Process.whereis(SentryFinchClient) do
      start_supervised!(SentryFinchClient.child_spec())
    end

    :ok
  end

  test "child_spec/0 returns a supervisable Finch spec" do
    assert %{id: Engram.Observability.SentryFinchClient, start: {Finch, :start_link, _}} =
             SentryFinchClient.child_spec()
  end

  test "post/3 sends the body and returns {:ok, status, headers, body}" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == "payload"
      Plug.Conn.resp(conn, 200, ~s({"id":"abc"}))
    end)

    url = "http://localhost:#{bypass.port}/api/1/envelope/"

    assert {:ok, 200, resp_headers, resp_body} =
             SentryFinchClient.post(url, [{"content-type", "application/json"}], "payload")

    assert is_list(resp_headers)
    assert resp_body == ~s({"id":"abc"})
  end

  test "post/3 returns {:error, reason} when the endpoint is unreachable" do
    # Nothing listens on port 1.
    assert {:error, _reason} =
             SentryFinchClient.post("http://localhost:1/api/1/envelope/", [], "payload")
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/engram/observability/sentry_finch_client_test.exs`
Expected: FAIL with `Engram.Observability.SentryFinchClient.child_spec/0 is undefined (module Engram.Observability.SentryFinchClient is not available)`.

- [ ] **Step 3: Implement the client**

Create `lib/engram/observability/sentry_finch_client.ex`:

```elixir
defmodule Engram.Observability.SentryFinchClient do
  @moduledoc """
  Sentry HTTP client backed by Finch. Replaces Sentry's default hackney client
  so the backend carries no hackney dependency. Implements `Sentry.HTTPClient`:
  Sentry starts the named Finch pool via `child_spec/0` and calls `post/3` to
  ship events.
  """
  @behaviour Sentry.HTTPClient

  @impl true
  def child_spec do
    Supervisor.child_spec({Finch, name: __MODULE__}, id: __MODULE__)
  end

  @impl true
  def post(url, headers, body) do
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, __MODULE__) do
      {:ok, %Finch.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/engram/observability/sentry_finch_client_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Wire Sentry to the client**

In `config/config.exs`, extend the existing `config :sentry` block (currently lines 202-204) so it reads:

```elixir
config :sentry,
  context_lines: 5,
  before_send: {Engram.Sentry.Scrubber, :scrub},
  client: Engram.Observability.SentryFinchClient
```

- [ ] **Step 6: Verify compile + format**

Run: `mix compile --warnings-as-errors && mix format --check-formatted`
Expected: clean compile, no format diff.

- [ ] **Step 7: Commit**

```bash
git add lib/engram/observability/sentry_finch_client.ex \
        test/engram/observability/sentry_finch_client_test.exs config/config.exs
git commit -m "feat(sentry): ship events via a Finch client, off hackney"
```

---

### Task 2: Route ex_aws (S3 + KMS) through ExAws.Request.Req

**Files:**
- Modify: `test/engram/storage/s3_test.exs` (add multipart + start/abort coverage)
- Modify: `config/config.exs:219-221` (swap `:ex_aws, :http_client`, add `:req_opts`)
- Delete: `lib/engram/storage/ex_aws_hackney.ex`

**Interfaces:**
- Consumes: `ExAws.Request.Req` (first-party in ex_aws 2.7.0; guarded by `Code.ensure_loaded?(Req)`, and Req is present). It reads `config :ex_aws, :req_opts` (default `receive_timeout: 30_000`) and returns `{:ok, %{status_code, headers, body}}` or `{:error, %{reason}}`, using Req's default `Req.Finch` pool. No supervision child is needed.
- Produces: no new module. `Engram.Storage.S3` is unchanged; only the HTTP client under it changes.

The existing `s3_test.exs` drives the CONFIGURED `:http_client` against a Bypass server, so it is the characterization net for this swap. Steps 1 and 2 add the multipart and start/abort cases (currently untested) BEFORE the swap, proving they pass on the current hackney adapter; the swap must then keep them green.

- [ ] **Step 1: Add multipart + start/abort tests (characterize current behavior)**

In `test/engram/storage/s3_test.exs`, add these describe blocks after the existing `describe "exists?/1"` block (before the final `render_msg/1` helpers):

```elixir
  describe "start_multipart/1" do
    test "returns the upload id parsed from the XML body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/#{@bucket}/#{@key}", fn conn ->
        assert conn.query_string =~ "uploads"

        xml =
          ~s(<?xml version="1.0"?><InitiateMultipartUploadResult>) <>
            ~s(<Bucket>#{@bucket}</Bucket><Key>#{@key}</Key><UploadId>UP123</UploadId>) <>
            ~s(</InitiateMultipartUploadResult>)

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      assert {:ok, "UP123"} = S3.start_multipart(@key)
    end
  end

  describe "upload_part/4" do
    test "returns the etag from the response headers", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/#{@bucket}/#{@key}", fn conn ->
        assert conn.query_string =~ "partNumber=1"
        assert conn.query_string =~ "uploadId=UP123"

        conn
        |> Plug.Conn.put_resp_header("etag", ~s("etag-1"))
        |> Plug.Conn.resp(200, "")
      end)

      assert {:ok, ~s("etag-1")} = S3.upload_part(@key, "UP123", 1, <<1, 2, 3>>)
    end
  end

  describe "complete_multipart_upload/3" do
    test "returns :ok on success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/#{@bucket}/#{@key}", fn conn ->
        assert conn.query_string =~ "uploadId=UP123"

        xml =
          ~s(<?xml version="1.0"?><CompleteMultipartUploadResult>) <>
            ~s(<Location>loc</Location><Bucket>#{@bucket}</Bucket><Key>#{@key}</Key>) <>
            ~s(<ETag>"final"</ETag></CompleteMultipartUploadResult>)

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      assert :ok =
               S3.complete_multipart_upload(@key, "UP123", [
                 %{part_number: 1, etag: ~s("etag-1")}
               ])
    end
  end

  describe "abort_multipart_upload/2" do
    test "returns :ok on success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/#{@bucket}/#{@key}", fn conn ->
        assert conn.query_string =~ "uploadId=UP123"
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = S3.abort_multipart_upload(@key, "UP123")
    end
  end
```

- [ ] **Step 2: Run the S3 suite to verify the new tests pass on the CURRENT adapter**

Run: `mix test test/engram/storage/s3_test.exs`
Expected: PASS (existing tests plus the 4 new ones). This proves the new tests correctly characterize behavior before the swap.

- [ ] **Step 3: Swap the ex_aws HTTP client to Req and delete the shim**

In `config/config.exs`, replace the current block (lines 219-221):

```elixir
# ex_aws HTTP client. We override the stock `ExAws.Request.Hackney` adapter
# because it only matches hackney's 4-tuple reply; hackney 4.x returns a
# 3-tuple for body-less responses (HEAD), which breaks S3.head_object/exists?.
# Engram.Storage.ExAwsHackney is the stock adapter plus that missing clause.
config :ex_aws, :http_client, Engram.Storage.ExAwsHackney
```

with:

```elixir
# ex_aws HTTP client: Req (first-party in ex_aws 2.7). Req uses its own default
# Finch pool, so the backend carries no hackney dependency. :req_opts sets the
# per-request timeout, mirroring the old adapter's 30s recv_timeout. Req handles
# body-less (HEAD) responses natively, so no shim is needed for S3.exists?.
config :ex_aws, :http_client, ExAws.Request.Req
config :ex_aws, :req_opts, receive_timeout: 30_000
```

Then delete the shim module:

```bash
git rm lib/engram/storage/ex_aws_hackney.ex
```

- [ ] **Step 4: Run the S3 suite to verify it stays green on Req**

Run: `mix test test/engram/storage/s3_test.exs`
Expected: PASS (all tests, now exercising `ExAws.Request.Req` against Bypass, including the HEAD 200/404/500 cases and the 4 multipart/start/abort cases).

- [ ] **Step 5: Verify KMS still compiles against the generic path**

The KMS module (`lib/engram/aws_kms/ex_aws.ex`) calls `ExAws.request/1`, which routes through the configured client independent of adapter, and matches `{:error, {type_string, message_string}}`, which ex_aws produces regardless of adapter. Confirm no reference to the deleted shim remains:

Run: `grep -rn "ExAwsHackney" lib config test`
Expected: no output.

- [ ] **Step 6: Compile + format**

Run: `mix compile --warnings-as-errors && mix format --check-formatted`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add test/engram/storage/s3_test.exs config/config.exs
git commit -m "feat(storage): route ex_aws S3/KMS through Req, drop hackney shim"
```

---

### Task 3: Pin the joken_jwks Tesla adapter to httpc in base config

**Files:**
- Modify: `config/config.exs` (add a `config :tesla` line near the ex_aws config)

**Interfaces:**
- Consumes: nothing new.
- Produces: `config :tesla, JokenJwks.HttpFetcher, adapter: Tesla.Adapter.Httpc` in base config so prod does not fall through to Tesla's default adapter. `dev.exs` and `test.exs` already set this; base config makes it hold in prod too.

**No bespoke test (intentional):** a unit test would run in the test env, where `test.exs` already sets this adapter, so the assertion would pass before and after the change. It is tautological and would characterize nothing. The real safety net is Task 4: after hackney is removed, the full `mix test` run exercises the Clerk/JWKS auth path, which would fail if JWKS depended on hackney, and `mix deps.tree` asserts hackney is absent globally. State this in the task-review dispatch so the reviewer does not flag the missing test.

- [ ] **Step 1: Add the base config**

In `config/config.exs`, immediately after the `config :ex_aws, :req_opts` line from Task 2, add:

```elixir
# joken_jwks drives its Tesla client with Erlang's built-in httpc adapter, so
# the JWKS verification path needs no hackney. dev.exs and test.exs set this
# too; pinning it in base config keeps prod off Tesla's default adapter.
config :tesla, JokenJwks.HttpFetcher, adapter: Tesla.Adapter.Httpc
```

- [ ] **Step 2: Verify compile + format**

Run: `mix compile --warnings-as-errors && mix format --check-formatted`
Expected: clean compile, no format diff.

- [ ] **Step 3: Commit**

```bash
git add config/config.exs
git commit -m "chore(auth): pin joken_jwks Tesla adapter to httpc in base config"
```

---

### Task 4: Remove hackney, add explicit Finch, bump version

**Files:**
- Modify: `mix.exs` (deps: remove hackney block, add finch; version bump)

**Interfaces:**
- Consumes: the three prior tasks moved every consumer off hackney.
- Produces: a dependency tree with no `hackney` and no `h2`. `finch` is now a direct, explicit dep (used by `SentryFinchClient`).

- [ ] **Step 1: Edit mix.exs**

In `mix.exs`, delete the entire hackney comment block and its dep line (currently lines 104-120, the `# HTTP transport...` comment through `{:hackney, "~> 4.4", override: true},`).

In its place, add an explicit Finch dep (Finch was only transitive via Req; the Sentry client now uses it directly):

```elixir
      # Finch: the HTTP/2-capable client (Mint-based) that Req rides on. Used
      # directly by Engram.Observability.SentryFinchClient and by ex_aws via
      # ExAws.Request.Req. This is the backend's single HTTP stack: no hackney.
      {:finch, "~> 0.23"},
```

Bump the version line (line 7) from `version: "0.5.618",` to `version: "0.5.619",`.

- [ ] **Step 2: Resolve deps and assert hackney is gone**

Run:

```bash
mix deps.unlock --unused && mix deps.get && mix deps.tree | grep -iE 'hackney|h2 ' || echo "NO hackney/h2 in tree"
```

Expected: prints `NO hackney/h2 in tree` (the `grep` finds nothing, so the `||` branch runs). If it prints a `hackney` or `h2` line instead, a consumer still pulls hackney: re-check Tasks 1 to 3.

- [ ] **Step 3: Full compile + test + quality gate**

Run:

```bash
mix compile --warnings-as-errors && mix test && mix credo --strict && mix sobelow --exit low && mix format --check-formatted
```

Expected: clean compile, full suite green, credo 0, sobelow exit 0, no format diff.

- [ ] **Step 4: Release-assembly smoke (proves removal is clean)**

Run: `MIX_ENV=prod mix release --overwrite`
Expected: assembles a release with no "Duplicated modules" error. (With hackney gone there is only one HTTP/2 module set in the tree; this also pre-verifies the ground R2 stands on.)

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock
git commit -m "chore(deps): drop hackney, make Finch explicit, bump 0.5.619"
```

---

### Task 5: Add a mix release smoke to the pre-push gate (dependency changes only)

**Files:**
- Modify: `.githooks/pre-push` (append a release smoke before the final exit)

**Interfaces:**
- Consumes: the hook's existing `$QUALITY_LOGDIR` and `$FAILED` variables.
- Produces: a gate that runs `MIX_ENV=prod mix release --overwrite` when `mix.exs` or `mix.lock` changed vs `origin/main`, catching duplicate-module failures that `mix test` never surfaces (it does not run `mix release`; only the Docker prebuild did, which is why the original blocker slipped through).

- [ ] **Step 1: Insert the smoke block**

In `.githooks/pre-push`, the file currently ends with the Stage B report followed by:

```bash
[ "$FAILED" = "0" ] || exit 1
```

Replace that final line with:

```bash
# ── Release smoke (dependency changes only) ──────────────────────────────
# `mix release` assembly runs a duplicate-module check that `mix test` never
# does. Two deps vendoring the same module names (for example hackney's h2 and
# grpcbox's ts_chatterbox) only blow up here. Run it when mix.exs/mix.lock
# changed vs origin/main, so normal pushes stay fast.
if git diff --name-only origin/main...HEAD 2>/dev/null | grep -qE '^mix\.(exs|lock)$'; then
  echo "▸ Release smoke: mix.exs/mix.lock changed — MIX_ENV=prod mix release --overwrite"
  if MIX_ENV=prod mix release --overwrite >"$QUALITY_LOGDIR/release.log" 2>&1; then
    echo "  ✓ mix release"
  else
    echo "  ✖ mix release failed (duplicate modules? boot config?); bypass: git push --no-verify" >&2
    cat "$QUALITY_LOGDIR/release.log" >&2
    FAILED=1
  fi
fi

[ "$FAILED" = "0" ] || exit 1
```

- [ ] **Step 2: Verify the hook parses and the guard triggers**

Run:

```bash
bash -n .githooks/pre-push && echo "syntax ok"
git diff --name-only origin/main...HEAD | grep -qE '^mix\.(exs|lock)$' && echo "guard would fire on this branch"
```

Expected: `syntax ok`, and `guard would fire on this branch` (Task 4 changed `mix.exs`/`mix.lock`).

- [ ] **Step 3: Commit**

```bash
git add .githooks/pre-push
git commit -m "chore(ci): mix release smoke in pre-push on dependency changes"
```

---

## Post-plan verification (not a code task)

- The full E2E suite is the real safety net for the S3/KMS swap: attachment sync, binary attachment sync, encryption-at-rest proof, and account-export multipart upload all exercise S3 through the new Req adapter. It runs in CI on the PR. Do not merge until it is green.
- Sentry has no dev/test coverage (SENTRY_DSN is unset, so Sentry is a no-op). Validate delivery with a prod canary after deploy: trigger a test event and confirm it lands. This is a manual rollout step, tracked in the spec, not a task here.
- Release 2 (rebase `feat/otel-tracing` on the stock exporter and ship tracing) is out of scope for this plan.
