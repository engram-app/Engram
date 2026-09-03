# OAuth Consent Multi-Vault Grants Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user grant an OAuth client access to an arbitrary subset of their vaults (A and C but not B) from a `/oauth/consent` screen that shows enough about each vault to choose confidently.

**Architecture:** Widen the single `vault_id` binding to a `vault_ids uuid[]` array at every layer — authorization code, refresh token, JWT claim, scope plug, MCP filter. `NULL` keeps meaning "all vaults, including future ones". A one-line widening of the shared Qdrant tenant filter (`match: %{any: ids}`) makes subset search work, which in turn lets us delete the "pass vault_id to choose one" dead end. Separately, mount the scope plug on the vault-scoped REST pipeline so the grant is actually enforced outside MCP.

**Tech Stack:** Elixir 1.17 / Phoenix 1.8, Ecto + Postgres (RLS), Qdrant, React 19 + TypeScript + Vite + Vitest + Tailwind + shadcn/ui, Bun.

**Spec:** Engram vault → `50 Engineering/_Superpowers Specs/2026-09-02-oauth-consent-multi-vault-design.md`

## Global Constraints

- **One PR.** Branch `feat/oauth-consent-multi-vault`, worktree `.worktrees/feat-oauth-consent-multi-vault`, based on `origin/main` at `a9bb6982`.
- **Migration label `phase/expand`.** The PR MUST carry exactly one `phase/*` label or CI hard-fails. Nullable column add only — no `DROP COLUMN`, no `ALTER COLUMN TYPE`, no rename, no `NOT NULL` without default.
- **`vault_id` is NOT dropped in this PR.** It is dual-written for single-vault grants and read as a fallback. Dropping it is a later `phase/contract` release.
- **`NULL` means all vaults, including ones created later.** `[]` is never a valid stored value — reject at mint.
- **Never modify a test to make bad code pass.** If a test goes red, fix the implementation.
- **No version bumps.** `release-please` owns `mix.exs` / `package.json` versions. Do not touch them.
- **Pre-push gates, run locally from the worktree:** `mix format`, `mix credo`, `mix dialyzer` (dialyzer is local-only, not in CI), and for the frontend `bun run build` plus `./node_modules/.bin/biome check` — NOT `bunx biome`, which resolves the wrong version.
- **Never pipe a gate command** into `tail`/`head` — the pipeline returns the pager's exit code and a failure reads as green.
- **Conventional commits**, subject < 50 chars.
- All paths below are relative to the worktree root `.worktrees/feat-oauth-consent-multi-vault/`.

---

## File Structure

**Backend — modified**
- `priv/repo/migrations/20260902120000_add_oauth_vault_ids_expand.exs` (create)
- `lib/engram/oauth/authorization_code.ex` — add `vault_ids` field
- `lib/engram/oauth/refresh_token.ex` — add `vault_ids` field
- `lib/engram/oauth.ex` — `resolve_vaults/2`, `mint_authorization_code/3`, `issue_access_token/3`, code→token and refresh-rotation carry-through
- `lib/engram_web/controllers/oauth_authorize_controller.ex` — accept `vault_ids`
- `lib/engram_web/plugs/oauth_scope_enforce.ex` — emit `oauth_scope_vault_ids`
- `lib/engram_web/controllers/mcp_controller.ex` — set membership; delete the subset dead end
- `lib/engram/vector/qdrant.ex` — `build_tenant_filter/1` accepts a list
- `lib/engram/search.ex` — `vault_ids` opt
- `lib/engram/vaults.ex` — `check_oauth_scope/2`
- `lib/engram_web/plugs/vault_plug.ex` — enforce the grant
- `lib/engram_web/router.ex` — mount `OAuthScopeEnforce` on the vault-scoped pipeline
- `lib/engram_web/controllers/vaults_controller.ex` — filter the list under a bound token
- `lib/engram/connections.ex` — array-aware revoke + one row per grant

**Frontend — modified**
- `frontend/src/api/oauth.ts` — `vault_ids` on the consent params
- `frontend/src/oauth/oauth-authorize-page.tsx` — checkbox picker
- `frontend/src/api/queries.ts` — `Connection.vault_ids`/`vault_names`; delete dead encryption fields

**Tests — created**
- `test/engram_web/plugs/vault_plug_oauth_scope_test.exs`

**Tests — modified**
- `test/engram/vector/qdrant_filter_test.exs`
- `test/engram_web/controllers/oauth_authorize_controller_test.exs`
- `test/engram_web/controllers/oauth_token_controller_test.exs`
- `test/engram_web/controllers/mcp_controller_test.exs`
- `test/engram_web/controllers/mcp_oauth_scope_test.exs`
- `test/engram_web/controllers/vaults_controller_test.exs`
- `test/engram/connections_test.exs`
- `frontend/src/oauth/oauth-authorize-page.test.tsx`

---

### Task 1: Schema — `vault_ids` column on both OAuth tables

**Files:**
- Create: `priv/repo/migrations/20260902120000_add_oauth_vault_ids_expand.exs`
- Modify: `lib/engram/oauth/authorization_code.ex:20`
- Modify: `lib/engram/oauth/refresh_token.ex:21`

**Interfaces:**
- Consumes: nothing.
- Produces: `Engram.OAuth.AuthorizationCode` and `Engram.OAuth.RefreshToken` both gain `field :vault_ids, {:array, Ecto.UUID}`, castable via their existing `changeset/2`.

- [ ] **Step 1: Write the failing test**

Append to `test/engram/oauth_single_use_test.exs`:

```elixir
  test "authorization code and refresh token both accept a vault_ids array" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    cs =
      Engram.OAuth.AuthorizationCode.changeset(
        %Engram.OAuth.AuthorizationCode{},
        %{vault_ids: [a, b]}
      )

    assert Ecto.Changeset.get_change(cs, :vault_ids) == [a, b]

    rt =
      Engram.OAuth.RefreshToken.changeset(
        %Engram.OAuth.RefreshToken{},
        %{vault_ids: [a, b]}
      )

    assert Ecto.Changeset.get_change(rt, :vault_ids) == [a, b]
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/oauth_single_use_test.exs`
Expected: FAIL — `vault_ids` is not a castable field, so `get_change/2` returns `nil`.

- [ ] **Step 3: Write the migration**

Create `priv/repo/migrations/20260902120000_add_oauth_vault_ids_expand.exs`:

```elixir
defmodule Engram.Repo.Migrations.AddOauthVaultIdsExpand do
  use Ecto.Migration

  # phase/expand — nullable array add, no default, no backfill. Safe under
  # Squawk: no table rewrite, no lock beyond the catalog update.
  #
  # NULL keeps its existing meaning ("all vaults"), so rows written before
  # this migration need no data migration — Engram.OAuth reads vault_ids
  # first and falls back to the scalar vault_id, which is retained until a
  # later phase/contract release drops it.
  def change do
    alter table(:oauth_authorization_codes) do
      add :vault_ids, {:array, :uuid}
    end

    alter table(:oauth_refresh_tokens) do
      add :vault_ids, {:array, :uuid}
    end
  end
end
```

- [ ] **Step 4: Add the schema fields**

In `lib/engram/oauth/authorization_code.ex`, after `field :vault_id, Ecto.UUID`:

```elixir
    field :vault_id, Ecto.UUID
    # Multi-vault grants. NULL = all vaults (including ones created later).
    # A non-empty list = exactly that set. `vault_id` is dual-written for
    # single-vault grants until the phase/contract release drops it.
    field :vault_ids, {:array, Ecto.UUID}
```

Update `@cast_fields` to include `vault_ids`:

```elixir
  @cast_fields ~w(code_hash client_id user_id redirect_uri code_challenge
                  code_challenge_method scope vault_id vault_ids state expires_at)a
```

In `lib/engram/oauth/refresh_token.ex`, add the same field after `field :vault_id, Ecto.UUID` and add `vault_ids` to `@cast`:

```elixir
  @cast ~w(token_hash family_id client_id user_id vault_id vault_ids scope
           expires_at last_used_at last_used_ip redirect_uri)a
```

- [ ] **Step 5: Run the migration and the test**

Run: `mix ecto.migrate && mix test test/engram/oauth_single_use_test.exs`
Expected: PASS

- [ ] **Step 6: Verify the migration linters pass**

Run: `bash priv/repo/lint_migrations.sh`
Expected: exit 0, no Squawk findings on the new file.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations/20260902120000_add_oauth_vault_ids_expand.exs \
        lib/engram/oauth/authorization_code.ex \
        lib/engram/oauth/refresh_token.ex \
        test/engram/oauth_single_use_test.exs
git commit -m "feat(oauth): add vault_ids array to grant tables"
```

---

### Task 2: Mint an authorization code from a list of vaults

**Files:**
- Modify: `lib/engram/oauth.ex:222` (`mint_authorization_code/3`), `lib/engram/oauth.ex:713` (`resolve_vault/2`)
- Test: `test/engram_web/controllers/oauth_authorize_controller_test.exs`

**Interfaces:**
- Consumes: `AuthorizationCode` `vault_ids` field from Task 1.
- Produces:
  - `Engram.OAuth.mint_authorization_code(user, validated, vault_selection)` where `vault_selection` is `:all | [String.t()]`. Returns `{:ok, redirect_url}` or `{:redirect_error, redirect_uri, "access_denied", state}`.
  - `Engram.OAuth.parse_vault_selection(params) :: :all | [String.t()] | :invalid` — reads `vault_ids` first, falls back to `vault_choice`.

- [ ] **Step 1: Write the failing tests**

Add to `test/engram_web/controllers/oauth_authorize_controller_test.exs`, in the same describe block as the existing `vault_choice` tests (line 287 onward). Follow that block's conventions exactly: each test builds its own `user`, vaults, and `client` via `register_client()`, composes params with `valid_params(client_id, redirect_uri)`, authenticates with `jwt_authed(user)`, and reads the minted row back with the public `OAuth.get_authorization_code_by_raw/1` — `hash_code/1` is private and cannot be called from a test.

```elixir
    test "mints a code carrying every granted vault id", %{conn: conn} do
      user = insert(:user)
      a = insert(:vault, user: user, slug: "sel-a")
      b = insert(:vault, user: user, slug: "sel-b")
      _c = insert(:vault, user: user, slug: "sel-c")
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_ids", [a.id, b.id])

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 200
      query = conn.resp_body |> Jason.decode!() |> Map.fetch!("redirect_uri")
              |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert {:ok, code_row} = OAuth.get_authorization_code_by_raw(query["code"])
      assert Enum.sort(code_row.vault_ids) == Enum.sort([a.id, b.id])
      # >1 vault: the scalar column stays NULL, because no single id means "A and B".
      assert is_nil(code_row.vault_id)
    end

    test "single-vault grant dual-writes the scalar vault_id", %{conn: conn} do
      user = insert(:user)
      a = insert(:vault, user: user, slug: "solo")
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id |> valid_params(redirect_uri) |> Map.put("vault_ids", [a.id])

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      query = conn.resp_body |> Jason.decode!() |> Map.fetch!("redirect_uri")
              |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert {:ok, code_row} = OAuth.get_authorization_code_by_raw(query["code"])
      assert code_row.vault_ids == [a.id]
      assert code_row.vault_id == a.id
    end

    test "one unowned id rejects the WHOLE grant", %{conn: conn} do
      user = insert(:user)
      a = insert(:vault, user: user, slug: "mine")
      stranger = insert(:vault, user: insert(:user), slug: "theirs")
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_ids", [a.id, stranger.id])

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 200
      uri = conn.resp_body |> Jason.decode!() |> Map.fetch!("redirect_uri")
      assert uri =~ "error=access_denied"

      # Not a partial grant — nothing was minted at all.
      assert Engram.Repo.aggregate(Engram.OAuth.AuthorizationCode, :count,
               skip_tenant_check: true) == 0
    end

    test "an empty vault_ids array is rejected, never widened to all", %{conn: conn} do
      user = insert(:user)
      _vault = insert(:vault, user: user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params = client.client_id |> valid_params(redirect_uri) |> Map.put("vault_ids", [])
      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      uri = conn.resp_body |> Jason.decode!() |> Map.fetch!("redirect_uri")
      assert uri =~ "error=access_denied"
    end

    test "vault_ids wins when both it and vault_choice are sent", %{conn: conn} do
      user = insert(:user)
      a = insert(:vault, user: user, slug: "wins")
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_ids", [a.id])
        |> Map.put("vault_choice", "vault:*")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      query = conn.resp_body |> Jason.decode!() |> Map.fetch!("redirect_uri")
              |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert {:ok, code_row} = OAuth.get_authorization_code_by_raw(query["code"])
      assert code_row.vault_ids == [a.id]
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/engram_web/controllers/oauth_authorize_controller_test.exs`
Expected: FAIL — `vault_ids` is ignored, so every grant resolves via `vault_choice` and defaults to all-vaults.

- [ ] **Step 3: Replace `resolve_vault/2` with `resolve_vaults/2`**

In `lib/engram/oauth.ex`, delete the three `resolve_vault/2` clauses at line 713 and add:

```elixir
  # Resolves a vault selection to the id list stored on the grant.
  #
  # `:all` → {:ok, nil} — NULL keeps its existing meaning, including vaults
  # created after the grant. An explicit list is verified in ONE query; if
  # any id is unowned, deleted, or unknown, the WHOLE grant fails. Partially
  # honouring a selection would silently hand out a scope the user never
  # confirmed on the consent screen.
  defp resolve_vaults(_user, :all), do: {:ok, nil}

  defp resolve_vaults(_user, []), do: :error

  defp resolve_vaults(user, ids) when is_list(ids) do
    casted = Enum.map(ids, &Ecto.UUID.cast/1)

    if Enum.any?(casted, &(&1 == :error)) do
      :error
    else
      wanted = casted |> Enum.map(fn {:ok, id} -> id end) |> Enum.uniq()

      query =
        from(v in Engram.Vaults.Vault,
          where: v.id in ^wanted and v.user_id == ^user.id and is_nil(v.deleted_at),
          select: v.id
        )

      case Repo.all(query, skip_tenant_check: true) do
        found when length(found) == length(wanted) -> {:ok, Enum.sort(found)}
        _ -> :error
      end
    end
  end

  defp resolve_vaults(_user, _), do: :error
```

`verify_vault_ownership/2` (line 724) is now unused — delete it. Leaving it would trip Credo's unused-private-function check.

- [ ] **Step 4: Add the param parser**

Add to `lib/engram/oauth.ex` as a public function (the controller calls it):

```elixir
  @doc """
  Reads a vault selection off consent params.

  `vault_ids` is the current shape. `vault_choice` ("vault:<id>" | "vault:*")
  is the pre-multi-vault shape and is still accepted for one release so an
  SPA cached across the deploy keeps working; `vault_ids` wins when both are
  present. Absent params default to `:all`, matching the previous
  `params["vault_choice"] || "vault:*"` behaviour.
  """
  @spec parse_vault_selection(map()) :: :all | [String.t()] | :invalid
  def parse_vault_selection(%{"vault_ids" => ids}) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1), do: ids, else: :invalid
  end

  def parse_vault_selection(%{"vault_ids" => _}), do: :invalid
  def parse_vault_selection(%{"vault_choice" => "vault:*"}), do: :all
  def parse_vault_selection(%{"vault_choice" => "vault:" <> id}), do: [id]
  def parse_vault_selection(%{"vault_choice" => _}), do: :invalid
  def parse_vault_selection(_), do: :all
```

- [ ] **Step 5: Rewrite `mint_authorization_code/3`**

Replace the head and the `attrs` map in `lib/engram/oauth.ex:222`:

```elixir
  @doc """
  Mints an authorization code for a validated request + a vault selection.

  `vault_selection` is `:all` or a list of vault id strings. Ownership is
  verified for every id — a user cannot grant an OAuth client access to a
  vault they do not own, and one bad id rejects the whole grant.

  Returns `{:ok, redirect_url}` (caller 302s) or
  `{:redirect_error, redirect_uri, error_code, state}`.
  """
  def mint_authorization_code(user, validated, vault_selection) do
    case resolve_vaults(user, vault_selection) do
      {:ok, vault_ids} ->
```

and inside, replace `vault_id: vault_id,` with:

```elixir
          vault_id: scalar_vault_id(vault_ids),
          vault_ids: vault_ids,
```

Add the helper next to `maybe_put/3`:

```elixir
  # Dual-write for the expand phase: a single-vault grant also populates the
  # legacy scalar column so a rollback to the previous release still reads a
  # correct binding. Multi-vault grants leave it NULL — there is no correct
  # scalar answer, and NULL there means "all vaults" to old code, which is
  # why multi-vault grants must not be rolled back into.
  defp scalar_vault_id([only]), do: only
  defp scalar_vault_id(_), do: nil
```

- [ ] **Step 6: Wire the controller**

In `lib/engram_web/controllers/oauth_authorize_controller.ex:51`, replace:

```elixir
        vault_choice = params["vault_choice"] || "vault:*"

        case OAuth.mint_authorization_code(user, validated, vault_choice) do
```

with:

```elixir
        case OAuth.mint_authorization_code(user, validated, OAuth.parse_vault_selection(params)) do
```

`:invalid` flows into `resolve_vaults/2`'s catch-all clause and becomes the same `access_denied` redirect as an unowned id — no extra branch needed.

- [ ] **Step 7: Run the tests**

Run: `mix test test/engram_web/controllers/oauth_authorize_controller_test.exs test/engram/oauth_single_use_test.exs`
Expected: PASS, including the pre-existing `vault_choice` tests at lines 287-491.

- [ ] **Step 8: Commit**

```bash
git add lib/engram/oauth.ex lib/engram_web/controllers/oauth_authorize_controller.ex \
        test/engram_web/controllers/oauth_authorize_controller_test.exs
git commit -m "feat(oauth): mint grants over a vault id list"
```

---

### Task 3: Carry `vault_ids` through token exchange and refresh rotation

**Files:**
- Modify: `lib/engram/oauth.ex:299` (code → refresh token), `:379` (rotation), `:392`, `:499` (`issue_access_token/3`), `:581`
- Test: `test/engram_web/controllers/oauth_token_controller_test.exs`

**Interfaces:**
- Consumes: `AuthorizationCode.vault_ids`, `RefreshToken.vault_ids` (Task 1); `mint_authorization_code/3` (Task 2).
- Produces: access-token JWTs carry a `vault_ids` claim (list of strings) whenever the grant is scoped; `vault_id` is still emitted for single-vault grants.

- [ ] **Step 1: Write the failing tests**

Add to `test/engram_web/controllers/oauth_token_controller_test.exs`. This file already has the helpers you need — `register_client/1` (line 24), `pkce_pair/0` (line 12), and `mint_code/5` (line 34), whose `opts` currently carries `:vault_choice`. First extend `mint_code/5` to accept `:vault_ids`, keeping `:vault_choice` working:

```elixir
  defp mint_code(user, client, redirect_uri, challenge, opts \\ []) do
    state = Keyword.get(opts, :state, "xyz")

    selection =
      case Keyword.fetch(opts, :vault_ids) do
        {:ok, ids} -> ids
        :error -> OAuth.parse_vault_selection(%{
                    "vault_choice" => Keyword.get(opts, :vault_choice, "vault:*")})
      end

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => state,
        "scope" => "mcp"
      })

    {:ok, redirect_url} = OAuth.mint_authorization_code(user, validated, selection)

    %{query: query} = URI.parse(redirect_url)
    URI.decode_query(query)["code"]
  end
```

Then add the tests, following the exchange/refresh shape the existing tests in this file already use (`post(conn, "/oauth/token", %{...})`) — read one of them first and mirror it exactly:

```elixir
    test "a multi-vault grant round-trips vault_ids through exchange and refresh",
         %{conn: conn} do
      user = insert(:user)
      a = insert(:vault, user: user, slug: "tok-a")
      b = insert(:vault, user: user, slug: "tok-b")
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()

      code = mint_code(user, client, redirect_uri, challenge, vault_ids: [a.id, b.id])

      body =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => redirect_uri,
          "client_id" => client.client_id,
          "code_verifier" => verifier
        })
        |> json_response(200)

      {:ok, claims} = Engram.Accounts.verify_jwt(body["access_token"])
      assert Enum.sort(claims["vault_ids"]) == Enum.sort([a.id, b.id])
      # No single id means "A and B" — must not claim a scalar binding.
      refute Map.has_key?(claims, "vault_id")

      refreshed =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => body["refresh_token"],
          "client_id" => client.client_id
        })
        |> json_response(200)

      {:ok, claims2} = Engram.Accounts.verify_jwt(refreshed["access_token"])
      assert Enum.sort(claims2["vault_ids"]) == Enum.sort([a.id, b.id])
    end

    test "a legacy refresh token with only vault_id still mints a scoped access token",
         %{conn: conn} do
      user = insert(:user)
      a = insert(:vault, user: user, slug: "tok-legacy")
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()

      code = mint_code(user, client, redirect_uri, challenge, vault_ids: [a.id])

      body =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => redirect_uri,
          "client_id" => client.client_id,
          "code_verifier" => verifier
        })
        |> json_response(200)

      # Simulate a row written before this release: scalar set, array NULL.
      Engram.Repo.update_all(Engram.OAuth.RefreshToken,
        [set: [vault_ids: nil]], skip_tenant_check: true)

      refreshed =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => body["refresh_token"],
          "client_id" => client.client_id
        })
        |> json_response(200)

      {:ok, claims} = Engram.Accounts.verify_jwt(refreshed["access_token"])
      assert claims["vault_ids"] == [a.id]
    end
```

Place both inside the existing `describe "POST /oauth/token — authorization_code grant"` block (line 55) so they inherit its `conn` setup.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/engram_web/controllers/oauth_token_controller_test.exs`
Expected: FAIL — no `vault_ids` claim is emitted.

- [ ] **Step 3: Carry the array across each hop**

In `lib/engram/oauth.ex` at line 299 (building the refresh token from the code row), add alongside `vault_id: code_row.vault_id`:

```elixir
             vault_id: code_row.vault_id,
             vault_ids: code_row.vault_ids,
```

At line 379 (rotation building the successor token), add alongside `vault_id: rt.vault_id`:

```elixir
        vault_id: rt.vault_id,
        vault_ids: rt.vault_ids,
```

At line 392 and line 581, change the `issue_access_token/3` calls to pass the effective id list:

```elixir
           access_token: issue_access_token(user, rt.scope, grant_vault_ids(rt)),
```

```elixir
      access_token: issue_access_token(user, code_row.scope, grant_vault_ids(code_row)),
```

- [ ] **Step 4: Emit the claim**

Replace `issue_access_token/3` at line 499:

```elixir
  # Reads the grant's effective vault scope, tolerating rows written before
  # the vault_ids column existed (scalar set, array NULL).
  defp grant_vault_ids(%{vault_ids: ids}) when is_list(ids) and ids != [], do: ids
  defp grant_vault_ids(%{vault_id: id}) when is_binary(id), do: [id]
  defp grant_vault_ids(_), do: nil

  defp issue_access_token(user, scope, vault_ids) do
    extras =
      %{}
      |> maybe_put("scope", scope)
      |> maybe_put("vault_ids", vault_ids)
      # Single-vault grants keep emitting the legacy scalar claim so a token
      # minted here stays readable by a rolled-back release. Multi-vault
      # grants omit it — there is no scalar that means "A and C", and the old
      # reader treats a missing claim as unrestricted, so it must never see
      # one it would misread as narrower than it is.
      |> then(fn m ->
        case vault_ids do
          [only] -> Map.put(m, "vault_id", only)
          _ -> m
        end
      end)

    Accounts.generate_jwt(user, extras)
  end
```

- [ ] **Step 5: Run the tests**

Run: `mix test test/engram_web/controllers/oauth_token_controller_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/engram/oauth.ex test/engram_web/controllers/oauth_token_controller_test.exs
git commit -m "feat(oauth): carry vault_ids into access tokens"
```

---

### Task 4: Scope plug emits a list; MCP enforces set membership

**Files:**
- Modify: `lib/engram_web/plugs/oauth_scope_enforce.ex`
- Modify: `lib/engram_web/controllers/mcp_controller.ex:411,417,421,436,466,485`
- Test: `test/engram_web/controllers/mcp_oauth_scope_test.exs`

**Interfaces:**
- Consumes: the `vault_ids` JWT claim from Task 3.
- Produces: `conn.assigns.oauth_scope_vault_ids :: [String.t()] | nil`. The old `oauth_scope_vault_id` assign is **removed** — leaving both invites a caller to check the wrong one.

- [ ] **Step 1: Write the failing tests**

In `test/engram_web/controllers/mcp_oauth_scope_test.exs`, add a list-taking auth helper next to `oauth_authed/3` (line 43):

```elixir
  defp oauth_authed_multi(conn, user, vault_ids) do
    user = ensure_external_id(user)
    token = Engram.Accounts.generate_jwt(user, %{"scope" => "mcp", "vault_ids" => vault_ids})
    put_req_header(conn, "authorization", "Bearer #{token}")
  end
```

and these tests:

```elixir
  test "a granted vault in a multi-vault grant routes", %{conn: conn, user: user,
                                                          vault_a: a, vault_b: b} do
    conn =
      conn
      |> oauth_authed_multi(user, [a.id, b.id])
      |> call_tool("list_folders", %{"vault_id" => b.id})

    body = json_response(conn, 200)
    refute Map.has_key?(body, "error")
    refute body["result"]["isError"] == true
  end

  test "a vault outside the grant is refused and not echoed as valid",
       %{conn: conn, user: user, vault_a: a, vault_b: b} do
    outside = insert(:vault, user: user, slug: "vault-c")

    conn =
      conn
      |> oauth_authed_multi(user, [a.id, b.id])
      |> call_tool("set_vault", %{"vault_id" => outside.id})

    body = json_response(conn, 200)
    text = body["result"]["content"] |> Kernel.||([]) |> Enum.map_join(" ", & &1["text"])

    assert body["result"]["isError"] == true
    refute text =~ "is valid"
  end

  test "list_vaults under a multi-vault grant shows exactly the granted set",
       %{conn: conn, user: user, vault_a: a} do
    _outside = insert(:vault, user: user, slug: "vault-hidden")

    conn = conn |> oauth_authed_multi(user, [a.id]) |> call_tool("list_vaults", %{})
    text = conn |> json_response(200) |> get_in(["result", "content"])
           |> Enum.map_join(" ", & &1["text"])

    assert text =~ a.name
    refute text =~ "vault-hidden"
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/engram_web/controllers/mcp_oauth_scope_test.exs`
Expected: FAIL — the `vault_ids` claim is ignored, so the grant reads as unrestricted and the outside vault resolves.

- [ ] **Step 3: Update the plug**

Replace the body of `lib/engram_web/plugs/oauth_scope_enforce.ex`:

```elixir
  @moduledoc """
  Surfaces OAuth scope claims (`vault_ids`, `scope`) from an Engram-issued
  internal HS256 JWT (the kind minted by `/oauth/token`) so downstream
  callers can enforce the grant's vault scope on the bearer token.

  Mounted on `/api/mcp` and on the vault-scoped REST pipeline, AFTER
  `EngramWeb.Plugs.Auth`. Auth has already validated the token, so this
  plug re-parses to extract the OAuth-specific claims without a second DB
  hit.

  Sets `conn.assigns.oauth_scope_vault_ids` (a list of vault id strings, or
  nil for an unrestricted grant) and `conn.assigns.oauth_scope` (string or
  nil). Never halts — absence of OAuth claims is the normal case for
  API-key / Clerk JWT auth, and means unrestricted.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Engram.Accounts.verify_jwt(token) do
      conn
      |> assign(:oauth_scope_vault_ids, scope_ids(claims))
      |> assign(:oauth_scope, claims["scope"])
    else
      _ -> conn
    end
  end

  # Reads the list claim, falling back to the scalar one so refresh tokens
  # minted before multi-vault grants shipped keep their binding. An empty
  # list is treated as unrestricted rather than "no vaults": it is never
  # written (mint rejects it), so encountering one means a malformed token,
  # and the surrounding API-key and ownership checks still apply.
  defp scope_ids(%{"vault_ids" => ids}) when is_list(ids) and ids != [],
    do: Enum.map(ids, &to_string/1)

  defp scope_ids(%{"vault_id" => id}) when is_binary(id), do: [id]
  defp scope_ids(_), do: nil
```

- [ ] **Step 4: Switch MCP to set membership**

In `lib/engram_web/controllers/mcp_controller.ex`, replace `scope_vaults/2` and `maybe_filter_oauth/2` (lines 411-424):

```elixir
  defp scope_vaults(vaults, conn) do
    oauth_bound = conn.assigns[:oauth_scope_vault_ids]
    # One query for the API key's restricted set, then filter in memory — not a
    # per-vault DB round-trip.
    allowed = Engram.Vaults.accessible_vault_ids(conn.assigns[:current_api_key])

    vaults
    |> maybe_filter_oauth(oauth_bound)
    |> filter_api_key(allowed)
  end

  defp maybe_filter_oauth(vaults, nil), do: vaults

  defp maybe_filter_oauth(vaults, bound) when is_list(bound) do
    set = MapSet.new(bound, &to_string/1)
    Enum.filter(vaults, &MapSet.member?(set, to_string(&1.id)))
  end
```

Replace `resolve_requested_vault/3` (line 466):

```elixir
  defp resolve_requested_vault(user, requested, conn) do
    if granted?(conn.assigns[:oauth_scope_vault_ids], requested) do
      with {:ok, vault} <- Engram.Vaults.get_vault(user, requested),
           :ok <- Engram.Vaults.check_api_key_access(conn.assigns[:current_api_key], vault) do
        {:ok, vault}
      else
        _ -> {:error, vault_denied_message(user, requested, conn)}
      end
    else
      {:error, vault_denied_message(user, requested, conn)}
    end
  end

  defp granted?(nil, _requested), do: true

  defp granted?(bound, requested) when is_list(bound),
    do: Enum.any?(bound, &(to_string(&1) == to_string(requested)))
```

Replace the first `cond` arm of `vault_denied_message/3` (line 485):

```elixir
      is_list(conn.assigns[:oauth_scope_vault_ids]) ->
        "This connection is authorized for #{length(conn.assigns.oauth_scope_vault_ids)} " <>
          "vault(s) and cannot access vault #{requested}. Call list_vaults to see which " <>
          "ones it can reach, or reconnect with a grant that includes this vault."
```

- [ ] **Step 5: Fix the bare-call message**

In `resolve_mcp_vault/3` (line 455-458), the `_many` branch says "You own multiple vaults", which is wrong for a 2-of-3 grant. Replace it:

```elixir
          _many ->
            {:error,
             "This connection can reach more than one vault — specify which. Call " <>
               "list_vaults to see the IDs, then pass vault_id on this tool call."}
```

Update the corresponding assertion in `test/engram_web/controllers/mcp_oauth_scope_test.exs:136` from `assert text =~ "multiple vaults"` to `assert text =~ "more than one vault"`. That test covers an unscoped token and its *behaviour* is unchanged — only the wording moves.

- [ ] **Step 6: Run the tests**

Run: `mix test test/engram_web/controllers/mcp_oauth_scope_test.exs test/engram_web/controllers/mcp_controller_test.exs`
Expected: PASS, all of it. The subset-search test at `mcp_controller_test.exs:1058` is driven by a restricted API KEY, not an OAuth grant, so `oauth_scope_vault_ids` is nil there and `maybe_filter_oauth/2` takes its passthrough clause — this task must not change that test's result. If it goes red here, the new membership filter is wrongly catching the nil case; fix that before continuing.

- [ ] **Step 7: Commit**

```bash
git add lib/engram_web/plugs/oauth_scope_enforce.ex \
        lib/engram_web/controllers/mcp_controller.ex \
        test/engram_web/controllers/mcp_oauth_scope_test.exs
git commit -m "feat(mcp): enforce grants as a vault set"
```

---

### Task 5: Multi-vault Qdrant filter

**Files:**
- Modify: `lib/engram/vector/qdrant.ex:651-657` (`build_tenant_filter/1`)
- Modify: `lib/engram/search.ex:276`, `:105-110`, `:166-174`, `:502-513`
- Test: `test/engram/vector/qdrant_filter_test.exs`

**Interfaces:**
- Consumes: nothing from earlier tasks — this is independent.
- Produces:
  - `Qdrant.build_tenant_filter/1` accepts `:vault_id` as a binary **or** a list; a list emits `%{key: "vault_id", match: %{any: ids}}`.
  - `Engram.Search.search(user, vault, query, opts)` accepts `opts[:vault_ids]` — a list that searches exactly that set.

- [ ] **Step 1: Write the failing tests**

Add to `test/engram/vector/qdrant_filter_test.exs`:

```elixir
  test "a vault_id list emits an any-match clause" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    %{must: must} =
      Engram.Vector.Qdrant.build_tenant_filter(user_id: "u1", vault_id: [a, b])

    assert %{key: "vault_id", match: %{any: [^a, ^b]}} =
             Enum.find(must, &(&1[:key] == "vault_id"))
  end

  test "a single vault_id binary still emits an exact-value clause" do
    a = Ecto.UUID.generate()

    %{must: must} = Engram.Vector.Qdrant.build_tenant_filter(user_id: "u1", vault_id: a)

    assert %{key: "vault_id", match: %{value: ^a}} =
             Enum.find(must, &(&1[:key] == "vault_id"))
  end

  test "no vault_id emits no vault clause" do
    %{must: must} = Engram.Vector.Qdrant.build_tenant_filter(user_id: "u1")
    refute Enum.any?(must, &(&1[:key] == "vault_id"))
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/engram/vector/qdrant_filter_test.exs`
Expected: FAIL on the list case — a list falls into the truthy branch and emits `match: %{value: [a, b]}`, which Qdrant would reject.

- [ ] **Step 3: Widen the filter**

In `lib/engram/vector/qdrant.ex`, replace line 657:

```elixir
    must = if vault_id, do: must ++ [%{key: "vault_id", match: %{value: vault_id}}], else: must
```

with:

```elixir
    # `vault_id` accepts one id or a set. The set form is what a multi-vault
    # OAuth grant (and a subset-restricted API key) needs: without it the only
    # options were one query per vault or dropping the filter entirely, and
    # dropping it leaks every vault the credential was scoped away from (#729).
    # `vault_id` is already a keyword payload index (@payload_index_fields), so
    # `any` needs no new index — same shape as tags_hmac below.
    must =
      case vault_id do
        nil -> must
        id when is_binary(id) -> must ++ [%{key: "vault_id", match: %{value: id}}]
        ids when is_list(ids) -> must ++ [%{key: "vault_id", match: %{any: ids}}]
      end
```

- [ ] **Step 4: Thread `vault_ids` through Search**

In `lib/engram/search.ex`, replace the `vault` filter line at 276:

```elixir
          |> then(&if(vault, do: Keyword.put(&1, :vault_id, to_string(vault.id)), else: &1))
```

with:

```elixir
          |> then(&put_vault_filter(&1, vault, opts))
```

and add near the other private helpers:

```elixir
  # A concrete vault narrows to one id; `vault_ids` narrows to a set (a
  # multi-vault OAuth grant or a subset-restricted API key); neither means an
  # unfiltered cross-vault search over everything the user owns.
  defp put_vault_filter(search_opts, %Engram.Vaults.Vault{} = vault, _opts),
    do: Keyword.put(search_opts, :vault_id, to_string(vault.id))

  defp put_vault_filter(search_opts, nil, opts) do
    case Keyword.get(opts, :vault_ids) do
      ids when is_list(ids) and ids != [] ->
        Keyword.put(search_opts, :vault_id, Enum.map(ids, &to_string/1))

      _ ->
        search_opts
    end
  end
```

In `load_candidate_vaults/3` (line 502), the `nil` clause already batch-loads from the candidates, which is correct for the subset case — no change needed.

Update the `cross_vault_allowed/2` comment at line 166, which no longer states the truth:

```elixir
  # Cross-vault is a Pro billing feature on the web/API path. The MCP server
  # makes multi-vault search the default for every tier (product decision
  # 2026-07-10), so it passes `allow_cross_vault: true` to bypass the gate.
  # The MCP caller is responsible for narrowing to the credential's ACCESSIBLE
  # set — either by passing a concrete `vault` or, for a subset, by passing
  # `vault_ids`, which becomes an any-match Qdrant filter. Neither widens
  # beyond what the caller may see.
```

- [ ] **Step 5: Run the tests**

Run: `mix test test/engram/vector/qdrant_filter_test.exs test/engram/search_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/engram/vector/qdrant.ex lib/engram/search.ex \
        test/engram/vector/qdrant_filter_test.exs
git commit -m "feat(search): filter Qdrant on a vault set"
```

---

### Task 6: Delete the subset-search dead end

**Files:**
- Modify: `lib/engram_web/controllers/mcp_controller.ex:362-394` (`search_across_accessible/4`)
- Test: `test/engram_web/controllers/mcp_controller_test.exs:1030-1067`

**Interfaces:**
- Consumes: `opts[:vault_ids]` from Task 5; `scope_vaults/2` from Task 4.
- Produces: a bare `search_notes` on a >1 subset returns merged results instead of an error.

> **This task must not be split from Task 5.** Removing the guard without the
> filter drops the vault clause entirely and leaks every vault the credential
> was scoped away from (#729). They land together or not at all.

- [ ] **Step 1: Rewrite the existing test**

In `test/engram_web/controllers/mcp_controller_test.exs`, replace the comment block at line 1030 and the test at line 1058. Keep the describe's `setup` exactly as it is — it builds a key permitted to A and B out of three vaults, which is the case under test:

```elixir
  # =========================================================================
  # Cross-vault search over a >1 SUBSET returns results from exactly that
  # subset — never a vault the credential was scoped away from (#729). The
  # any-match Qdrant vault filter is what makes this safe; before it existed
  # the only correct answer was to refuse.
  # =========================================================================

  describe "cross-vault search for a subset-restricted key" do
    setup do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, va, _} = Engram.Vaults.register_vault(user, "A", Ecto.UUID.generate())
      {:ok, vb, _} = Engram.Vaults.register_vault(user, "B", Ecto.UUID.generate())
      {:ok, vc, _} = Engram.Vaults.register_vault(user, "C", Ecto.UUID.generate())

      {:ok, api_key, key_rec} = Engram.Accounts.create_api_key(user, "subset-key")
      grant_api_write!(user)

      # Permit the key to A and B only — NOT C. accessible = 2, total = 3.
      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(key_rec.id), vault_id: Ecto.UUID.dump!(va.id)},
        %{api_key_id: Ecto.UUID.dump!(key_rec.id), vault_id: Ecto.UUID.dump!(vb.id)}
      ])

      # One matching note per vault, so the assertion has something to find and
      # C has something it COULD leak if the filter were dropped.
      for {v, body} <- [{va, "findme in A"}, {vb, "findme in B"}, {vc, "findme in C"}] do
        {:ok, _} =
          Engram.Notes.upsert_note(user, v, %{
            "path" => "#{v.slug}.md",
            "content" => body,
            "mtime" => 1.0
          })
      end

      %{
        conn: build_conn() |> put_req_header("authorization", "Bearer #{api_key}"),
        va: va,
        vb: vb,
        vc: vc
      }
    end

    test "bare search on a >1 vault subset searches exactly that subset",
         %{conn: conn, va: va, vb: vb, vc: vc} do
      conn = call_tool(conn, "search_notes", %{"query" => "findme"})
      resp = json_response(conn, 200)
      text = resp["result"]["content"] |> Enum.map_join(" ", & &1["text"])

      refute resp["result"]["isError"] == true
      assert text =~ to_string(va.id)
      assert text =~ to_string(vb.id)
      # C was never granted — it must not appear, even as a label.
      refute text =~ to_string(vc.id)
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/engram_web/controllers/mcp_controller_test.exs -k "subset-restricted"`
Expected: FAIL — the guard still returns `isError: true` with "limited to specific vaults".

- [ ] **Step 3: Delete the guard and pass the set**

In `lib/engram_web/controllers/mcp_controller.ex`, replace `search_across_accessible/4`:

```elixir
  # Picks the vault context for a bare (no vault_id) search. A credential that
  # reaches exactly one vault searches it directly; anything wider goes through
  # one Qdrant query carrying an any-match filter over the accessible set, so
  # the result set can never include a vault the credential was scoped away
  # from (#729).
  defp search_across_accessible(tool, user, args, conn) do
    # Fetch the vault list ONCE; derive both the accessible set and the total
    # from it (no double query).
    all = Engram.Vaults.list_vaults(user)
    accessible = scope_vaults(all, conn)

    case accessible do
      [] ->
        error_result(no_vault_message_for(all))

      [only] ->
        call_tool(tool, user, only, args)

      many ->
        call_tool(tool, user, {:cross_vault, many}, args)
    end
  end
```

- [ ] **Step 4: Pass `vault_ids` where `{:cross_vault, _}` is handled**

Find the `call_tool/4` clause that destructures `{:cross_vault, vaults}` and forwards to `Engram.Search`. Where it currently relies on `vault: nil` alone, add the narrowing opt:

```elixir
      vault_ids: Enum.map(vaults, &to_string(&1.id)),
```

Run `grep -n "cross_vault" lib/engram/mcp/handlers.ex lib/engram_web/controllers/mcp_controller.ex` to locate every site; each one that builds Search opts needs it. A site that only labels results by vault (`handlers.ex:667`) does not.

- [ ] **Step 5: Run the tests**

Run: `mix test test/engram_web/controllers/mcp_controller_test.exs test/engram_web/controllers/mcp_oauth_scope_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/engram_web/controllers/mcp_controller.ex lib/engram/mcp/handlers.ex \
        test/engram_web/controllers/mcp_controller_test.exs
git commit -m "feat(mcp): search a granted vault subset"
```

---

### Task 7: Enforce the grant on the REST pipeline

**Files:**
- Modify: `lib/engram/vaults.ex` (add `check_oauth_scope/2` next to `check_api_key_access/2` at line 689)
- Modify: `lib/engram_web/plugs/vault_plug.ex:26-34`
- Modify: `lib/engram_web/router.ex` (vault-scoped pipeline)
- Create: `test/engram_web/plugs/vault_plug_oauth_scope_test.exs`

**Interfaces:**
- Consumes: `conn.assigns.oauth_scope_vault_ids` from Task 4.
- Produces: `Engram.Vaults.check_oauth_scope(scope_ids, vault) :: :ok | :forbidden`.

> This is the widest-blast-radius task in the plan: it changes enforcement for
> every route behind `VaultPlug`, not just the OAuth ones. If CI goes broadly
> red, start here.

- [ ] **Step 1: Write the failing test**

Create `test/engram_web/plugs/vault_plug_oauth_scope_test.exs`:

```elixir
defmodule EngramWeb.VaultPlugOAuthScopeTest do
  use EngramWeb.ConnCase, async: true

  # An OAuth access token is an ordinary user JWT with extra claims, so before
  # this it authenticated against every vault-scoped REST route with no vault
  # filter at all — the "bound to one vault" grant was enforced on /api/mcp
  # only. These lock the REST half.

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    granted = insert(:vault, user: user, slug: "granted", is_default: true)
    other = insert(:vault, user: user, slug: "other")
    %{user: user, granted: granted, other: other}
  end

  defp scoped(conn, user, vault_ids) do
    user = ensure_external_id(user)
    token = Engram.Accounts.generate_jwt(user, %{"scope" => "mcp", "vault_ids" => vault_ids})
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp ensure_external_id(%{external_id: ext} = user) when is_binary(ext) and ext != "", do: user

  defp ensure_external_id(user) do
    {:ok, updated} =
      user
      |> Ecto.Changeset.change(external_id: "test-#{user.id}")
      |> Engram.Repo.update(skip_tenant_check: true)

    updated
  end

  test "a granted vault passes", %{conn: conn, user: user, granted: granted} do
    conn =
      conn
      |> scoped(user, [granted.id])
      |> put_req_header("x-vault-id", granted.id)
      |> get("/api/folders")

    assert conn.status == 200
  end

  test "a vault outside the grant is 403", %{conn: conn, user: user,
                                             granted: granted, other: other} do
    conn =
      conn
      |> scoped(user, [granted.id])
      |> put_req_header("x-vault-id", other.id)
      |> get("/api/folders")

    assert conn.status == 403
  end

  test "the default-vault fallback is also gated", %{conn: conn, user: user, other: other} do
    # granted is the DEFAULT vault; a grant for `other` alone must not let a
    # header-less request fall back into the default.
    conn = conn |> scoped(user, [other.id]) |> get("/api/folders")
    assert conn.status == 403
  end

  test "an unscoped grant reaches every vault", %{conn: conn, user: user, other: other} do
    user = ensure_external_id(user)
    token = Engram.Accounts.generate_jwt(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("x-vault-id", other.id)
      |> get("/api/folders")

    assert conn.status == 200
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/engram_web/plugs/vault_plug_oauth_scope_test.exs`
Expected: FAIL — the two 403 assertions get 200; the grant is not enforced on REST.

- [ ] **Step 3: Add the check function**

In `lib/engram/vaults.ex`, after `check_api_key_access/2` (line 694):

```elixir
  @doc """
  Checks a vault against an OAuth grant's vault scope.

  `nil` (no OAuth claims, or an unrestricted grant) permits every vault —
  API-key and Clerk-JWT auth take this path. A list permits only its members.
  Mirrors `check_api_key_access/2` so VaultPlug applies both the same way.
  """
  @spec check_oauth_scope([String.t()] | nil, map()) :: :ok | :forbidden
  def check_oauth_scope(nil, _vault), do: :ok

  def check_oauth_scope(scope_ids, vault) when is_list(scope_ids) do
    if Enum.any?(scope_ids, &(to_string(&1) == to_string(vault.id))),
      do: :ok,
      else: :forbidden
  end
```

- [ ] **Step 4: Enforce it in VaultPlug**

In `lib/engram_web/plugs/vault_plug.ex`, replace the `{:ok, vault}` arm of `call/2`:

```elixir
      {:ok, vault} ->
        api_key = conn.assigns[:current_api_key]

        with :ok <- Vaults.check_api_key_access(api_key, vault),
             :ok <- Vaults.check_oauth_scope(conn.assigns[:oauth_scope_vault_ids], vault) do
          assign(conn, :current_vault, vault)
        else
          :forbidden ->
            Halt.json(conn, 403, %{error: "Not authorized for this vault"})
        end
```

Note the message is now shared by both rejections. That is deliberate: telling an unauthorized caller *which* of the two checks failed distinguishes "this vault exists but your key lacks it" from "your grant excludes it", and neither is theirs to know. Update the moduledoc:

```elixir
  - If an API key is present in assigns, checks api_key_vaults for vault restrictions.
  - If the bearer token is an OAuth grant scoped to specific vaults
    (`oauth_scope_vault_ids`, set by OAuthScopeEnforce), checks membership.
```

- [ ] **Step 5: Mount the plug on the vault-scoped pipeline**

In `lib/engram_web/router.ex`, find the vault-scoped pipeline (the one ending in `EngramWeb.Plugs.VaultPlug`, near the `RequireOnboarding` mount at line 307) and insert `OAuthScopeEnforce` immediately BEFORE `VaultPlug`:

```elixir
      # Surfaces the OAuth grant's vault scope so VaultPlug can enforce it.
      # MUST precede VaultPlug — VaultPlug reads the assign it sets. An OAuth
      # access token is an ordinary user JWT, so without this the grant is
      # enforced on /api/mcp only and ignored on every REST route.
      EngramWeb.Plugs.OAuthScopeEnforce,
      EngramWeb.Plugs.VaultPlug
```

- [ ] **Step 6: Run the new test plus the full plug and controller suites**

Run: `mix test test/engram_web/plugs/ test/engram_web/controllers/`
Expected: PASS. Any failure here is a route that was silently relying on an OAuth token reaching a vault outside its grant — fix the caller, do not weaken the check.

- [ ] **Step 7: Commit**

```bash
git add lib/engram/vaults.ex lib/engram_web/plugs/vault_plug.ex lib/engram_web/router.ex \
        test/engram_web/plugs/vault_plug_oauth_scope_test.exs
git commit -m "fix(auth): enforce OAuth vault grants on REST"
```

---

### Task 8: Filter the vault list under a bound token

**Files:**
- Modify: `lib/engram_web/controllers/vaults_controller.ex:82` (`index_payload/1`)
- Test: `test/engram_web/controllers/vaults_controller_test.exs`

**Interfaces:**
- Consumes: `Engram.Vaults.check_oauth_scope/2` (Task 7); `oauth_scope_vault_ids` (Task 4).
- Produces: `index_payload/2` — a second arity taking the scope list. The existing `index_payload/1` stays as `index_payload(user, nil)` so `/api/bootstrap` keeps compiling.

- [ ] **Step 1: Write the failing test**

Add to `test/engram_web/controllers/vaults_controller_test.exs`:

```elixir
  test "GET /api/vaults under a scoped grant lists only granted vaults", %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    granted = insert(:vault, user: user, slug: "granted", is_default: true)
    _hidden = insert(:vault, user: user, slug: "hidden")

    user = ensure_external_id(user)
    token = Engram.Accounts.generate_jwt(user, %{"scope" => "mcp", "vault_ids" => [granted.id]})

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/vaults")

    slugs = conn |> json_response(200) |> Map.fetch!("vaults") |> Enum.map(& &1["slug"])
    assert slugs == ["granted"]
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/engram_web/controllers/vaults_controller_test.exs`
Expected: FAIL — both slugs come back; `/api/vaults` sits on the user-scoped pipeline and never saw the grant.

- [ ] **Step 3: Mount the plug on the user-scoped pipeline**

In `lib/engram_web/router.ex`, add `EngramWeb.Plugs.OAuthScopeEnforce` to the user-scoped `scope "/api"` pipeline (the one at line 311 with `TraceUserAttrs`, `AccountLifecycle`, `RotationLockCheck`), after `EngramWeb.Plugs.Auth`.

- [ ] **Step 4: Filter the payload**

In `lib/engram_web/controllers/vaults_controller.ex`, change `index/2` (line 50-52) to pass the scope:

```elixir
    payload = index_payload(user, conn.assigns[:oauth_scope_vault_ids])
```

and replace `index_payload/1`:

```elixir
  @doc """
  Builds the base `GET /api/vaults` JSON map (`%{vaults: [...]}`) for a user.
  Public so the consolidated `GET /api/bootstrap` endpoint serves the identical
  list shape without the device-link `user_code` extension.

  `scope_ids` narrows the list to an OAuth grant's vaults. Without it a
  token scoped to one vault could still enumerate the names of every other
  vault the user owns — the same leak the MCP list path closed in #729.
  """
  def index_payload(user, scope_ids \\ nil) do
    vaults =
      user
      |> Vaults.list_vaults()
      |> Enum.filter(&(Vaults.check_oauth_scope(scope_ids, &1) == :ok))

    counts = Vaults.content_counts_for(user, vaults)
    %{vaults: Enum.map(vaults, &vault_json(&1, Map.get(counts, &1.id, @zero_counts)))}
  end
```

Keep the rest of the original body if it does more than the above — only the `list_vaults` result changes.

- [ ] **Step 5: Update the bootstrap caller**

Run `grep -rn "index_payload" lib/` and pass the scope at the `/api/bootstrap` call site too:

```elixir
    VaultsController.index_payload(user, conn.assigns[:oauth_scope_vault_ids])
```

- [ ] **Step 6: Run the tests**

Run: `mix test test/engram_web/controllers/vaults_controller_test.exs test/engram_web/controllers/bootstrap_controller_test.exs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/engram_web/controllers/vaults_controller.ex lib/engram_web/router.ex \
        test/engram_web/controllers/vaults_controller_test.exs
git commit -m "fix(vaults): scope the vault list to the grant"
```

---

### Task 9: Array-aware revocation and one row per grant

**Files:**
- Modify: `lib/engram/connections.ex:105` (`revoke_oauth_family/3`), `:136` (`revoke_by_vault/2`), `:231` (list query), `:194` (typespec), `:253`, `:329`
- Test: `test/engram/connections_test.exs`

**Interfaces:**
- Consumes: `RefreshToken.vault_ids` (Task 1).
- Produces: the connections payload's `vault_id`/`vault_name` pair becomes `vault_ids :: [String.t()] | nil` and `vault_names :: [String.t()] | nil`. `nil` means all vaults.

- [ ] **Step 1: Write the failing tests**

Add to `test/engram/connections_test.exs`. First the shared helper the tests below use — it mints a grant directly through `OAuth.mint_authorization_code/3` and exchanges it, which is the smallest path to a real refresh-token row:

```elixir
  # Builds a user with three vaults and ONE refresh token whose grant covers
  # `selection` (`:all` or a list of vault ids).
  defp grant_over(selection_fn) do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    a = insert(:vault, user: user, slug: "grant-a", is_default: true)
    b = insert(:vault, user: user, slug: "grant-b")
    c = insert(:vault, user: user, slug: "grant-c")

    client = register_client()
    validated = validated_request(client)

    {:ok, redirect_url} =
      Engram.OAuth.mint_authorization_code(user, validated, selection_fn.(a, b, c))

    code =
      redirect_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("code")

    {:ok, _tokens} = Engram.OAuth.exchange_authorization_code(code, validated)

    %{user: user, a: a, b: b, c: c}
  end

  defp grant_over_three_vaults, do: grant_over(fn a, b, c -> [a.id, b.id, c.id] end)
  defp grant_over_one_vault, do: grant_over(fn a, _b, _c -> [a.id] end)
  defp grant_over_all_vaults, do: grant_over(fn _a, _b, _c -> :all end)
```

Reuse the file's existing `register_client/0` and code-exchange helpers if it already defines them under different names — check the top of the module before adding duplicates, and match `exchange_authorization_code`'s real arity (`grep -n "def exchange_authorization_code" lib/engram/oauth.ex`).

```elixir
  test "deleting one vault narrows a multi-vault grant instead of revoking it" do
    %{user: user, a: a, b: b, c: c} = grant_over_three_vaults()

    :ok = Connections.revoke_by_vault(user.id, b.id)

    token = Engram.Repo.one!(Engram.OAuth.RefreshToken, skip_tenant_check: true)
    assert is_nil(token.revoked_at)
    assert Enum.sort(token.vault_ids) == Enum.sort([a.id, c.id])
  end

  test "deleting the last granted vault revokes the token" do
    %{user: user, a: a} = grant_over_one_vault()

    :ok = Connections.revoke_by_vault(user.id, a.id)

    token = Engram.Repo.one!(Engram.OAuth.RefreshToken, skip_tenant_check: true)
    refute is_nil(token.revoked_at)
  end

  test "a legacy scalar-only row is still revoked outright" do
    %{user: user, a: a} = grant_over_one_vault()
    Engram.Repo.update_all(Engram.OAuth.RefreshToken,
      [set: [vault_ids: nil]], skip_tenant_check: true)

    :ok = Connections.revoke_by_vault(user.id, a.id)

    token = Engram.Repo.one!(Engram.OAuth.RefreshToken, skip_tenant_check: true)
    refute is_nil(token.revoked_at)
  end

  test "an all-vaults grant is untouched by a vault deletion" do
    %{user: user, a: a} = grant_over_all_vaults()

    :ok = Connections.revoke_by_vault(user.id, a.id)

    token = Engram.Repo.one!(Engram.OAuth.RefreshToken, skip_tenant_check: true)
    assert is_nil(token.revoked_at)
  end

  test "a multi-vault grant lists as ONE connection carrying every vault name" do
    %{user: user, a: a, b: b, c: c} = grant_over_three_vaults()

    assert [listed] = Connections.list_for_user(user)
    assert Enum.sort(listed.vault_names) == Enum.sort([a.name, b.name, c.name])
    assert Enum.sort(listed.vault_ids) == Enum.sort([a.id, b.id, c.id])
  end

  test "an all-vaults grant lists with nil vault_ids" do
    %{user: user} = grant_over_all_vaults()

    assert [listed] = Connections.list_for_user(user)
    assert is_nil(listed.vault_ids)
    assert is_nil(listed.vault_names)
  end
```

`Connections.list_for_user/1` (line 210) is the module's public list function — the one `ConnectionsController` calls.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/engram/connections_test.exs`
Expected: FAIL — `revoke_by_vault/2` matches only the scalar column, so a multi-vault grant is untouched (or wrongly revoked once the query is widened naively).

- [ ] **Step 3: Widen `revoke_oauth_family/3`**

In `lib/engram/connections.ex:115-120`, replace the narrowing:

```elixir
    query =
      if vault_id do
        # Matches both shapes: rows written before vault_ids existed carry
        # only the scalar column.
        from(t in query,
          where:
            fragment("(? = ANY(?) OR ? = ?)", ^vault_id, t.vault_ids, t.vault_id, ^vault_id)
        )
      else
        query
      end
```

- [ ] **Step 4: Rewrite `revoke_by_vault/2`**

Replace the OAuth half of `revoke_by_vault/2` (`lib/engram/connections.ex:139-146`):

```elixir
    # A multi-vault grant must NOT die because one of its vaults did — that
    # would cost the user access to vaults they never touched. Narrow the
    # array; revoke only when nothing is left. Legacy scalar-only rows have
    # nothing to narrow and are revoked outright, as before. Rows with both
    # columns NULL are "all vaults" and are deliberately untouched.
    Repo.update_all(
      from(t in RefreshToken,
        where: t.user_id == ^user_id,
        where: fragment("? = ANY(?)", ^vault_id, t.vault_ids),
        where: fragment("array_length(?, 1) > 1", t.vault_ids),
        where: is_nil(t.revoked_at)
      ),
      set: [vault_ids: fragment("array_remove(?, ?)", :vault_ids, ^vault_id)]
    )

    Repo.update_all(
      from(t in RefreshToken,
        where: t.user_id == ^user_id,
        where:
          fragment(
            "((? = ANY(?) AND array_length(?, 1) = 1) OR (? IS NULL AND ? = ?))",
            ^vault_id,
            t.vault_ids,
            t.vault_ids,
            t.vault_ids,
            t.vault_id,
            ^vault_id
          ),
        where: is_nil(t.revoked_at)
      ),
      set: [revoked_at: now]
    )
```

`Ecto.Query.update_all` cannot express `array_remove` through `set:` directly — if the compiler rejects the fragment there, use `update: [set: [vault_ids: fragment("array_remove(vault_ids, ?)", ^vault_id)]]` on the query instead, which is the supported form.

The `DeviceRefreshToken` half below it is unchanged — the device flow stays one vault per device.

- [ ] **Step 5: One row per grant in the list**

At `lib/engram/connections.ex:231`, change `distinct: [t.client_id, t.vault_id]` to `distinct: [t.client_id, t.vault_ids]`, and at line 253 select the array instead of the scalar:

```elixir
        vault_ids: coalesce(t.vault_ids, fragment("CASE WHEN ? IS NULL THEN NULL ELSE ARRAY[?] END", t.vault_id, t.vault_id)),
```

At line 217, map names over the list:

```elixir
    |> Enum.map(fn c ->
      Map.put(c, :vault_names, c.vault_ids && Enum.map(c.vault_ids, &Map.get(vault_names, &1)))
    end)
```

At line 290 and 329 (the device and API-key branches), replace `vault_id: nil` / `vault_id: rt.vault_id` with `vault_ids: nil` / `vault_ids: [rt.vault_id]` so every branch produces the same shape.

Update the typespec at line 194 — note the existing one says `integer() | nil`, which was already wrong (these are UUIDs):

```elixir
          vault_ids: [String.t()] | nil,
          vault_names: [String.t()] | nil,
```

- [ ] **Step 6: Run the tests**

Run: `mix test test/engram/connections_test.exs test/engram_web/controllers/connections_controller_test.exs`
Expected: PASS

- [ ] **Step 7: Confirm the cap math is unchanged**

Run: `mix test test/engram_web/plugs/enforce_connection_cap_test.exs`
Expected: PASS with no edits. `count_active/2` counts `count(DISTINCT client_id)` (line 59), not `(client_id, vault_id)`, so one client reaching N vaults has always been one connection. If this suite goes red, the counting query was changed by mistake — revert that, do not adjust the cap.

- [ ] **Step 8: Commit**

```bash
git add lib/engram/connections.ex test/engram/connections_test.exs
git commit -m "fix(connections): narrow multi-vault grants on delete"
```

---

### Task 10: Consent page — multi-select vault picker

**Files:**
- Modify: `frontend/src/api/oauth.ts:13-24`
- Modify: `frontend/src/oauth/oauth-authorize-page.tsx:106-118,176-190,262-296`
- Test: `frontend/src/oauth/oauth-authorize-page.test.tsx`

**Interfaces:**
- Consumes: the `vault_ids` consent param from Task 2.
- Produces: `OAuthConsentParams.vault_ids?: string[]` replaces `vault_choice: string`.

- [ ] **Step 1: Write the failing tests**

In `frontend/src/oauth/oauth-authorize-page.test.tsx`, first fix the `useVaults` mock — it currently returns numeric ids (`{ id: 1 }`), but real ids are UUID strings and the component compares with `String(v.id)`:

```typescript
	useVaults: () => ({
		data: [
			{
				id: "11111111-1111-1111-1111-111111111111",
				name: "Personal",
				description: null,
				is_default: true,
				note_count: 1204,
				attachment_count: 18,
			},
			{
				id: "22222222-2222-2222-2222-222222222222",
				name: "Work",
				description: "day job",
				is_default: false,
				note_count: 312,
				attachment_count: 0,
			},
		],
		isLoading: false,
	}),
```

Then add:

```typescript
	it("submits only the checked vaults", async () => {
		postOAuthConsent.mockResolvedValue({ redirect_uri: "https://client.example/cb?code=x" });
		renderPage();

		fireEvent.click(await screen.findByRole("checkbox", { name: /Personal/ }));
		fireEvent.click(screen.getByRole("button", { name: "Approve" }));

		await waitFor(() => expect(postOAuthConsent).toHaveBeenCalled());
		expect(postOAuthConsent.mock.calls[0][0].vault_ids).toEqual([
			"11111111-1111-1111-1111-111111111111",
		]);
	});

	it("omits vault_ids entirely when All vaults is chosen", async () => {
		postOAuthConsent.mockResolvedValue({ redirect_uri: "https://client.example/cb?code=x" });
		renderPage();

		fireEvent.click(await screen.findByRole("checkbox", { name: /Personal/ }));
		fireEvent.click(screen.getByRole("radio", { name: /All vaults/ }));
		fireEvent.click(screen.getByRole("button", { name: "Approve" }));

		await waitFor(() => expect(postOAuthConsent).toHaveBeenCalled());
		expect(postOAuthConsent.mock.calls[0][0].vault_ids).toBeUndefined();
	});

	it("disables Approve until something is selected", async () => {
		renderPage();
		expect(await screen.findByRole("button", { name: "Approve" })).toBeDisabled();

		fireEvent.click(screen.getByRole("checkbox", { name: /Work/ }));
		expect(screen.getByRole("button", { name: "Approve" })).toBeEnabled();
	});

	it("shows counts and the default badge", async () => {
		renderPage();
		expect(await screen.findByText("1,204 notes · 18 files")).toBeInTheDocument();
		expect(screen.getByText("default")).toBeInTheDocument();
		expect(screen.getByText("day job")).toBeInTheDocument();
	});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd frontend && bun run test oauth-authorize-page`
Expected: FAIL — there are no checkboxes, only radios; `vault_choice` is still sent.

- [ ] **Step 3: Update the API types**

In `frontend/src/api/oauth.ts`, replace `vault_choice: string;` in `OAuthConsentParams`:

```typescript
	// Absent = all vaults, including ones created later. A non-empty array =
	// exactly those vaults. Never send an empty array — the backend rejects it
	// rather than widening it to "all".
	vault_ids?: string[];
```

- [ ] **Step 4: Replace the selection state**

In `frontend/src/oauth/oauth-authorize-page.tsx`, replace the `pickedVault` / `vaultChoice` block (lines 106-118):

```typescript
	// `null` = the explicit "All vaults" choice, which stays all-vaults as new
	// ones are created. A Set = exactly those ids. These are different grants,
	// so the UI keeps them as different controls rather than inferring one
	// from "every box happens to be checked".
	const [picked, setPicked] = useState<Set<string> | null>(null);

	// Ids that no longer exist in the fetched list are dropped. That is a
	// function of the current list, so it is computed here rather than written
	// back into state from an effect one paint later.
	const live = vaultsQuery.data;
	const selected =
		picked && live
			? new Set([...picked].filter((id) => live.some((v) => String(v.id) === id)))
			: picked;

	const toggle = (id: string) => {
		setPicked((prev) => {
			const next = new Set(prev ?? []);
			next.has(id) ? next.delete(id) : next.add(id);
			return next;
		});
	};
```

- [ ] **Step 5: Send the new param**

In `runSubmit`, replace `vault_choice: vaultChoice,` in the `body` literal with nothing, and after the literal add:

```typescript
		if (selected && selected.size > 0) {
			body.vault_ids = [...selected];
		}
```

- [ ] **Step 6: Render the picker**

Replace the `<fieldset>` at lines 262-296:

```tsx
						<fieldset className="flex flex-col gap-2">
							<legend className="mb-1 font-medium text-foreground text-sm">
								Which vaults can {clientName} access?
							</legend>
							{vaultsQuery.data?.map((v) => {
								const id = String(v.id);
								const active = Boolean(selected?.has(id));
								return (
									<label key={id} className={selectableRow(active)}>
										<input
											type="checkbox"
											checked={active}
											onChange={() => toggle(id)}
											className="accent-primary"
										/>
										<span className="flex min-w-0 flex-1 items-baseline gap-2">
											<span className="font-medium text-foreground text-sm">{v.name}</span>
											{v.is_default && (
												<span className="text-muted-foreground text-xs">default</span>
											)}
											{v.description && (
												<span className="truncate text-muted-foreground text-xs">
													{v.description}
												</span>
											)}
										</span>
										<span className="shrink-0 text-muted-foreground text-xs">
											{countLabel(v.note_count, v.attachment_count)}
										</span>
									</label>
								);
							})}
							<label className={selectableRow(selected === null)}>
								<input
									type="radio"
									name="all_vaults"
									checked={selected === null}
									onChange={() => setPicked(null)}
									className="accent-primary"
								/>
								<span className="font-medium text-foreground text-sm">
									All vaults
									<span className="ml-2 font-normal text-muted-foreground text-xs">
										including any you create later
									</span>
								</span>
							</label>
						</fieldset>
```

Add above the component:

```tsx
function countLabel(notes?: number, files?: number): string {
	const parts = [`${(notes ?? 0).toLocaleString()} notes`];
	if (files) parts.push(`${files.toLocaleString()} files`);
	return parts.join(" · ");
}
```

- [ ] **Step 7: Gate Approve**

Change the Approve button's `disabled` prop:

```tsx
								disabled={submitting || (selected !== null && selected.size === 0)}
```

- [ ] **Step 8: Run the tests**

Run: `cd frontend && bun run test oauth-authorize-page`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add frontend/src/api/oauth.ts frontend/src/oauth/oauth-authorize-page.tsx \
        frontend/src/oauth/oauth-authorize-page.test.tsx
git commit -m "feat(consent): multi-select vault picker"
```

---

### Task 11: Frontend type cleanup

**Files:**
- Modify: `frontend/src/api/queries.ts:1497-1498,1578-1592`

**Interfaces:**
- Consumes: the connections payload shape from Task 9.
- Produces: `Connection.vault_ids`/`vault_names`; six dead fields removed from `Vault`.

- [ ] **Step 1: Confirm the dead fields have no readers**

Run:

```bash
cd frontend && grep -rn "encryption_status\|encrypted_at\|decrypt_requested_at\|cooldown_days\|last_toggle_at\|EncryptionStatus" src/ | grep -v "api/queries.ts"
```

Expected: no output. If anything appears, it reads a field the backend stopped sending — fix that call site first and note it in the PR body.

- [ ] **Step 2: Update the Connection interface**

In `frontend/src/api/queries.ts`, replace lines 1497-1498:

```typescript
	/** The vaults this grant reaches. `null` means all of them, including any
	 *  created later. */
	vault_ids: string[] | null;
	vault_names: string[] | null;
```

- [ ] **Step 3: Delete the dead encryption fields**

In the `Vault` interface, remove `encrypted`, `encryption_status`, `encrypted_at`, `decrypt_requested_at`, `last_toggle_at` and `cooldown_days`, and delete the `EncryptionStatus` type alias at line 1578. Leave `EncryptionProgress` alone unless Step 1 proved it unread too.

Encryption has been mandatory and one-way since Phase B.4 — `vaults_controller.ex:380` hardcodes `encrypted: true` and `encryption_status` appears nowhere in `lib/`.

- [ ] **Step 4: Fix the fallout**

Run: `cd frontend && bun run build`
Expected: PASS. Any type error points at a real reader Step 1 missed — fix it rather than restoring the field.

- [ ] **Step 5: Update the connections UI**

Run `grep -rn "vault_name" frontend/src/` and update each site to render the list (`conn.vault_names?.join(", ") ?? "All vaults"`).

- [ ] **Step 6: Run the frontend suite**

Run: `cd frontend && bun run test`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add frontend/src/api/queries.ts frontend/src/
git commit -m "refactor(web): drop dead vault encryption fields"
```

---

### Task 12: Full gauntlet, OpenAPI, and the PR

**Files:**
- Modify: `openapi.json` (regenerated, not hand-edited)

- [ ] **Step 1: Regenerate the OpenAPI spec**

Run: `mix openapi.spec.json --spec EngramWeb.ApiSpec --pretty=true openapi.json`

That exact command is what the CI drift gate re-runs and diffs against the committed file (`.github/workflows/verify.yml:2434`). CI fails on a stale `openapi.json`.

- [ ] **Step 2: Sweep for missed `vault_id` callers**

Run:

```bash
grep -rn "oauth_scope_vault_id\b" lib/ test/
grep -rn "vault_choice" lib/ frontend/src/ e2e/ frontend/e2e/
```

Expected: `oauth_scope_vault_id` (singular) returns nothing — the assign was renamed. `vault_choice` should appear only in the back-compat clause of `parse_vault_selection/1` and its tests. A hit under `frontend/e2e/` is the sweep-gap class that has bitten before; fix it here.

- [ ] **Step 3: Run the backend gauntlet**

Run each separately, never piped:

```bash
mix format --check-formatted
mix credo
mix dialyzer
mix test
```

Expected: all clean. Dialyzer is local-only — CI will not catch what you skip here.

- [ ] **Step 4: Run the frontend gauntlet**

```bash
cd frontend
./node_modules/.bin/biome check .
bun run build
bun run test
```

Expected: all clean. Use the local biome binary — `bunx biome` resolves a different version and reports different findings.

- [ ] **Step 5: Push and open the PR**

```bash
git push -u origin feat/oauth-consent-multi-vault
gh pr create --title "feat(oauth): multi-vault consent grants" --body "$(cat <<'EOF'
## Summary

Grants an OAuth client access to an arbitrary subset of a user's vaults, and
redesigns `/oauth/consent` so the choice is legible.

- `vault_ids uuid[]` on `oauth_authorization_codes` and `oauth_refresh_tokens`
  (`phase/expand`; the scalar `vault_id` is dual-written and dropped later).
- A `vault_ids` JWT claim; `OAuthScopeEnforce` normalizes it and the legacy
  scalar into one assign.
- The shared Qdrant tenant filter takes an id set (`match: %{any: …}`), which
  lets a subset-scoped credential cross-vault search instead of being told to
  pick one. This also fixes the same limitation for subset-restricted API
  keys, which has been there since #729.
- **Fixes a scope hole:** `OAuthScopeEnforce` was mounted on `/api/mcp` only,
  so an OAuth token ignored its vault binding on every REST route. Now
  enforced in `VaultPlug` and on the vault list.
- Vault deletion narrows a multi-vault grant instead of revoking it outright.
- Consent screen shows note/attachment counts, the default badge, and
  descriptions; drops six dead encryption fields from the `Vault` type.

## Testing

`mix format --check-formatted`, `mix credo`, `mix dialyzer`, `mix test`,
`biome check`, `bun run build`, `bun run test` — all green locally.

EOF
)"
gh pr edit --add-label phase/expand
```

- [ ] **Step 6: Verify the label took**

Run: `gh pr view --json labels`
Expected: exactly one `phase/*` label, `phase/expand`. CI hard-fails on zero or more than one.

---

## Notes for the executor

- **Tasks 5 and 6 are one unit.** Task 6 deletes a privacy guard that only Task 5's filter makes safe to delete. Do not commit 6 without 5.
- **Task 7 has the widest blast radius.** It changes enforcement for every route behind `VaultPlug`. Broad CI red starts there.
- **`main` in the parent checkout has an unresolved stash-pop conflict** in `frontend/src/onboarding/onboard-billing-page.tsx` (`stash@{0}: autostash`). It predates this work and is not yours to resolve. This worktree branches off `origin/main` and is unaffected.
- **Never merge on red**, including diagnosed flakes. No admin bypass.
