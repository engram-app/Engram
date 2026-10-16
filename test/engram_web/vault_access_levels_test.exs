defmodule EngramWeb.VaultAccessLevelsTest do
  @moduledoc """
  Per-vault access levels (#174 for OAuth grants, #332 for API keys). Both
  credential kinds share one representation in `Engram.Permissions`: a level
  per listed vault (none | read | write) and a "new vaults" policy for every
  vault the credential does not list, resolved at REQUEST time so a vault
  created after the credential needs no backfill.

  Every rule runs for both kinds, on the surfaces each reaches. OAuth
  credentials come out of the real consent -> /oauth/token chain; API keys
  out of `Accounts.create_api_key/3`. An OAuth access token is bound to the
  MCP server (#1997): beside `/api/mcp` it reaches only the attachment
  upload, and every other REST route answers it 401 (pinned in
  vault_access_attack_test.exs). So REST reads and vault lifecycle run for
  API keys, and the OAuth form of the same rule runs on MCP and the upload.
  """
  use EngramWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Engram.OAuthHelpers, only: [code_from_redirect: 1, legacy_audience: 2, pkce_pair: 0]

  alias Engram.{Accounts, OAuth, Vaults}
  alias Engram.Auth.Providers.Local

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    # API keys need a plan with API access; this file tests scoping, not tiers.
    insert(:user_limit_override, user: user, key: "api_rps_cap", value: %{"v" => 100})
    insert(:user_limit_override, user: user, key: "api_write_enabled", value: %{"v" => true})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    user = ensure_external_id(user)

    {:ok, w, _} = Vaults.register_vault(user, "Writable", Ecto.UUID.generate())
    {:ok, r, _} = Vaults.register_vault(user, "Readable", Ecto.UUID.generate())
    {:ok, n, _} = Vaults.register_vault(user, "Hidden", Ecto.UUID.generate())

    for v <- [w, r, n] do
      {:ok, _} =
        Engram.Notes.upsert_note(
          user,
          v,
          %{"path" => "a.md", "content" => "in #{v.name}", "mtime" => 1.0},
          actor: "api"
        )
    end

    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://muse.example/callback"],
        "client_name" => "Muse"
      })

    %{user: user, w: w, r: r, n: n, client: client}
  end

  defp levels(ctx, default) do
    {%{
       to_string(ctx.w.id) => "write",
       to_string(ctx.r.id) => "read",
       to_string(ctx.n.id) => "none"
     }, default}
  end

  # Returns a bearer token for `kind` holding `access` = {per-vault map, new-vaults policy}.
  defp credential(ctx, :api_key, access) do
    {:ok, raw, _key} = Accounts.create_api_key(ctx.user, "key", access)
    raw
  end

  defp credential(ctx, :oauth, {map, default}) do
    {verifier, challenge} = pkce_pair()
    redirect_uri = hd(ctx.client.redirect_uris)

    params = %{
      "client_id" => ctx.client.client_id,
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => "s",
      "scope" => "mcp",
      "vault_access" => map,
      "default_access" => default
    }

    {:ok, session} =
      Local.issue_access_token(ctx.user.external_id, ctx.user.email)

    code =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session}")
      |> post("/api/oauth/authorize/consent", params)
      |> json_response(200)
      |> Map.fetch!("redirect_uri")
      |> code_from_redirect()

    build_conn()
    |> post("/oauth/token", %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => ctx.client.client_id,
      "code_verifier" => verifier
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
  end

  defp as(token), do: put_req_header(build_conn(), "authorization", "Bearer #{token}")

  defp mcp(token, method, params \\ %{}) do
    token
    |> as()
    |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    |> json_response(200)
  end

  defp tool(token, name, args),
    do: mcp(token, "tools/call", %{"name" => name, "arguments" => args})

  defp listed_vault_ids(token) do
    token
    |> tool("list_vaults", %{})
    |> get_in(["result", "structuredContent", "vaults"])
    |> Enum.map(& &1["id"])
  end

  defp write_note(token, vault, path \\ "new.md"),
    do: tool(token, "write_note", %{"vault_id" => vault.id, "path" => path, "content" => "x"})

  # A refusal the model must see is a tool result with `isError`, not a
  # JSON-RPC protocol error (MCP spec, tool execution errors). Returns its text.
  defp refusal(body) do
    refute body["error"],
           "expected a tool result, got a protocol error: #{inspect(body["error"])}"

    assert body["result"]["isError"] == true
    body["result"]["content"] |> hd() |> Map.fetch!("text")
  end

  # A refused write is also a 200 with no "error" key, so success is asserted
  # positively.
  defp written?(body), do: body["result"]["isError"] == false

  defp note_exists?(ctx, vault, path),
    do: match?({:ok, _}, Engram.Notes.get_note(ctx.user, vault, path))

  defp rest_write(token, vault) do
    token
    |> as()
    |> put_req_header("x-vault-id", vault.id)
    |> post("/api/notes", %{"path" => "rest.md", "content" => "x", "mtime" => 1.0})
  end

  defp rest_read(token, vault),
    do: token |> as() |> put_req_header("x-vault-id", vault.id) |> get("/api/notes/a.md")

  defp upload(token, vault) do
    token
    |> as()
    |> put_req_header("x-vault-id", vault.id)
    |> post("/api/attachments", %{"path" => "f.txt", "content_base64" => "aGk="})
  end

  # Reading a vault's a.md the way each kind can: an API key over REST, an
  # OAuth token over MCP. `:ok`, or `:refused` for a vault out of reach
  # (REST 404, or the tool refusal that names the subset; a missing note or
  # any other refusal fails here, so `:refused` is never vacuous).
  defp reads(:api_key, token, vault) do
    case rest_read(token, vault) do
      %{status: 200} ->
        :ok

      %{status: 404} = conn ->
        refute conn.resp_body =~ "in #{vault.name}"
        :refused
    end
  end

  defp reads(:oauth, token, vault) do
    body = tool(token, "get_notes", %{"vault_id" => vault.id, "paths" => ["a.md"]})
    refute body["error"], inspect(body)
    text = body["result"]["content"] |> Enum.map_join(" ", & &1["text"])

    cond do
      body["result"]["isError"] != true ->
        :ok

      text =~ "restricted to a subset" ->
        refute text =~ "in #{vault.name}"
        :refused

      true ->
        flunk("unexpected refusal: #{text}")
    end
  end

  # The HTTP write each kind reaches beside MCP: an API key the REST API, an
  # OAuth token the attachment upload.
  defp http_write(:api_key, token, vault), do: rest_write(token, vault)
  defp http_write(:oauth, token, vault), do: upload(token, vault)

  # Stands in for Qdrant and records every query body, so a test can assert on
  # the vault filter that actually left the server (an empty result proves
  # nothing about which vaults were searched).
  defp capture_qdrant do
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Engram.ServiceConfig.put_override(:qdrant_search_timeout, 30_000)
    Mox.stub(Engram.MockEmbedder, :embed_texts, fn _texts, _opts -> {:ok, [[0.1, 0.2, 0.3]]} end)
    test_pid = self()

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:qdrant_body, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":{"points":[]}}))
    end)
  end

  # Every UUID in the query bodies sent so far (the vault filter, plus the
  # user id, which no assertion here confuses for a vault).
  defp qdrant_vault_ids do
    bodies = drain_qdrant([])
    assert bodies != [], "no Qdrant query was sent"

    ~r/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/
    |> Regex.scan(Enum.join(bodies, " "))
    |> List.flatten()
  end

  defp drain_qdrant(acc) do
    receive do
      {:qdrant_body, raw} -> drain_qdrant([raw | acc])
    after
      0 -> acc
    end
  end

  defp later_vault(ctx) do
    {:ok, v, _} = Vaults.register_vault(ctx.user, "Created Later", Ecto.UUID.generate())

    {:ok, _} =
      Engram.Notes.upsert_note(
        ctx.user,
        v,
        %{"path" => "a.md", "content" => "later", "mtime" => 1.0},
        actor: "api"
      )

    v
  end

  for kind <- [:oauth, :api_key] do
    describe "#{kind}: MCP" do
      test "list_vaults shows read and write vaults, never a no-access one", ctx do
        ids = ctx |> credential(unquote(kind), levels(ctx, "none")) |> listed_vault_ids()

        assert to_string(ctx.w.id) in ids
        assert to_string(ctx.r.id) in ids
        refute to_string(ctx.n.id) in ids
      end

      test "write tools stay listed when one vault is writable", ctx do
        names =
          ctx
          |> credential(unquote(kind), levels(ctx, "none"))
          |> mcp("tools/list")
          |> get_in(["result", "tools"])
          |> Enum.map(& &1["name"])

        assert "write_note" in names
      end

      test "a write to a read-level vault is refused, naming the vault", ctx do
        body = ctx |> credential(unquote(kind), levels(ctx, "none")) |> write_note(ctx.r)

        assert refusal(body) =~ "read-only"
        assert refusal(body) =~ "Readable"
        refute note_exists?(ctx, ctx.r, "new.md")
      end

      test "an upload target for a read-level vault is refused", ctx do
        body =
          ctx
          |> credential(unquote(kind), levels(ctx, "none"))
          |> tool("get_attachment_upload_target", %{"vault_id" => ctx.r.id})

        assert refusal(body) =~ "read-only"
      end

      test "a write to a write-level vault goes through", ctx do
        body = ctx |> credential(unquote(kind), levels(ctx, "none")) |> write_note(ctx.w)

        assert written?(body)
        assert note_exists?(ctx, ctx.w, "new.md")
      end

      # Counted by levels, never by the legacy `vault_ids` claim (write vaults
      # only on a leveled grant, or a sentinel).
      test "a refused vault's message counts what the levels reach", ctx do
        body =
          ctx
          |> credential(unquote(kind), levels(ctx, "none"))
          |> tool("get_notes", %{"vault_id" => ctx.n.id, "paths" => ["a.md"]})

        text = body |> get_in(["result", "content"]) |> Enum.map_join(" ", & &1["text"])
        assert text =~ "(it can reach 2)"
        refute text =~ "00000000-0000-0000-0000-000000000000"
      end

      test "a policy-only credential's refusal counts every vault it reads", ctx do
        body =
          ctx
          |> credential(unquote(kind), {%{to_string(ctx.n.id) => "none"}, "read"})
          |> tool("get_notes", %{"vault_id" => ctx.n.id, "paths" => ["a.md"]})

        text = body |> get_in(["result", "content"]) |> Enum.map_join(" ", & &1["text"])
        assert text =~ "(it can reach 2)"
      end

      test "a read-level vault is still readable", ctx do
        body =
          ctx
          |> credential(unquote(kind), levels(ctx, "none"))
          |> tool("get_notes", %{"vault_id" => ctx.r.id, "paths" => ["a.md"]})

        assert body |> get_in(["result", "content"]) |> Enum.map_join(" ", & &1["text"]) =~
                 "in Readable"
      end

      test "an all-read credential hides write tools", ctx do
        names =
          ctx
          |> credential(unquote(kind), {%{}, "read"})
          |> mcp("tools/list")
          |> get_in(["result", "tools"])
          |> Enum.map(& &1["name"])

        refute "write_note" in names
        assert "search_notes" in names
      end
    end

    describe "#{kind}: vaults created after the credential" do
      test "policy none: invisible everywhere", ctx do
        token = credential(ctx, unquote(kind), levels(ctx, "none"))
        later = later_vault(ctx)

        refute to_string(later.id) in listed_vault_ids(token)
        assert reads(unquote(kind), token, later) == :refused
        assert http_write(unquote(kind), token, later).status == 404

        assert tool(token, "get_notes", %{"vault_id" => later.id, "paths" => ["a.md"]})["result"][
                 "isError"
               ]

        capture_qdrant()
        refute tool(token, "search_notes", %{"query" => "later"})["error"]
        searched = qdrant_vault_ids()

        # The filter is there (both reachable vaults are in it), and the vault
        # created later is not: the policy is none.
        assert to_string(ctx.w.id) in searched and to_string(ctx.r.id) in searched
        refute to_string(later.id) in searched
        refute to_string(ctx.n.id) in searched
      end

      # Cross-vault search: REST `cross_vault` for a key, a bare MCP
      # search_notes (every reachable vault) for an OAuth token.
      test "cross-vault search filters to what the levels reach", ctx do
        insert(:user_limit_override,
          user: ctx.user,
          key: "cross_vault_search",
          value: %{"v" => true}
        )

        token = credential(ctx, unquote(kind), levels(ctx, "read"))
        later = later_vault(ctx)
        capture_qdrant()

        if unquote(kind) == :api_key do
          conn =
            token
            |> as()
            |> put_req_header("x-vault-id", ctx.w.id)
            |> post("/api/search", %{"query" => "x", "cross_vault" => true})

          assert conn.status == 200
        else
          refute tool(token, "search_notes", %{"query" => "x"})["error"]
        end

        searched = qdrant_vault_ids()

        for v <- [ctx.w, ctx.r, later], do: assert(to_string(v.id) in searched, v.name)
        refute to_string(ctx.n.id) in searched
      end

      test "policy read: readable, not writable", ctx do
        token = credential(ctx, unquote(kind), levels(ctx, "read"))
        later = later_vault(ctx)

        assert to_string(later.id) in listed_vault_ids(token)
        assert reads(unquote(kind), token, later) == :ok
        assert refusal(write_note(token, later)) =~ "read-only"

        assert json_response(http_write(unquote(kind), token, later), 403)["error"] ==
                 "read_only_vault"

        # Vault lifecycle is REST: refused by level for a key, by audience
        # (401) for an OAuth token.
        delete = token |> as() |> delete("/api/vaults/#{later.id}")
        assert delete.status == if(unquote(kind) == :api_key, do: 403, else: 401)
        assert {:ok, _} = Vaults.get_vault(ctx.user, later.id)
      end

      test "policy write: writable", ctx do
        token = credential(ctx, unquote(kind), levels(ctx, "write"))
        later = later_vault(ctx)

        assert written?(write_note(token, later))
        assert note_exists?(ctx, later, "new.md")
        assert http_write(unquote(kind), token, later).status in 200..201
      end
    end
  end

  # REST and vault lifecycle are API-key surfaces: an OAuth token gets 401 on
  # every one of these routes (vault_access_attack_test.exs), so its levels
  # are pinned on MCP above and on the upload ("vaults created after").
  describe "api_key: REST" do
    test "a write to a read-level vault is 403 read_only_vault", ctx do
      conn = ctx |> credential(:api_key, levels(ctx, "none")) |> rest_write(ctx.r)

      assert json_response(conn, 403)["error"] == "read_only_vault"
      refute note_exists?(ctx, ctx.r, "rest.md")
    end

    test "a write to a write-level vault succeeds", ctx do
      conn = ctx |> credential(:api_key, levels(ctx, "none")) |> rest_write(ctx.w)

      assert conn.status in 200..201
      assert note_exists?(ctx, ctx.w, "rest.md")
    end

    test "reads follow reachability: read ok, none refused", ctx do
      token = credential(ctx, :api_key, levels(ctx, "none"))

      assert rest_read(token, ctx.r).status == 200
      assert rest_read(token, ctx.n).status == 404
    end

    test "search (a read over POST) is allowed on a read-level vault", ctx do
      conn =
        ctx
        |> credential(:api_key, levels(ctx, "none"))
        |> as()
        |> put_req_header("x-vault-id", ctx.r.id)
        # An empty body fails validation INSIDE the controller, so any
        # status other than 403 proves the read-only guard let it through.
        |> post("/api/search", %{})

      refute conn.status == 403
    end
  end

  describe "api_key: vault lifecycle" do
    test "rename, delete and restore need write on that vault", ctx do
      token = credential(ctx, :api_key, levels(ctx, "none"))

      assert token
             |> as()
             |> patch("/api/vaults/#{ctx.r.id}", %{"name" => "x"})
             |> json_response(403)

      assert token |> as() |> delete("/api/vaults/#{ctx.r.id}") |> json_response(403)
      assert token |> as() |> post("/api/vaults/#{ctx.r.id}/restore") |> json_response(403)
      assert {:ok, _} = Vaults.get_vault(ctx.user, ctx.r.id)

      assert token
             |> as()
             |> patch("/api/vaults/#{ctx.w.id}", %{"name" => "Renamed"})
             |> json_response(200)
    end

    test "out-of-scope answers like a missing vault; read-only is a visible 403", ctx do
      token = credential(ctx, :api_key, levels(ctx, "none"))
      read_only = token |> as() |> delete("/api/vaults/#{ctx.r.id}") |> json_response(403)
      hidden = token |> as() |> delete("/api/vaults/#{ctx.n.id}") |> json_response(404)
      missing = token |> as() |> delete("/api/vaults/#{Ecto.UUID.generate()}")

      assert read_only == %{"error" => "Not authorized for this vault"}
      assert hidden == json_response(missing, 404)
    end

    test "index and show work at any level", ctx do
      token = credential(ctx, :api_key, levels(ctx, "none"))

      assert token |> as() |> get("/api/vaults/#{ctx.r.id}") |> json_response(200)
      assert token |> as() |> get("/api/vaults") |> json_response(200)
    end

    for {policy, allowed?} <- [{"none", false}, {"read", false}, {"write", true}] do
      test "creating a vault needs a write new-vaults policy (#{policy})", ctx do
        conn =
          ctx
          |> credential(:api_key, levels(ctx, unquote(policy)))
          |> as()
          |> post("/api/vaults/register", %{
            "name" => "Brand New",
            "client_id" => Ecto.UUID.generate()
          })

        if unquote(allowed?), do: assert(conn.status == 201), else: assert(conn.status == 403)
      end
    end
  end

  defp deleted_ids(token) do
    token
    |> as()
    |> get("/api/vaults?deleted=true")
    |> json_response(200)
    |> Map.fetch!("vaults")
    |> Enum.map(& &1["id"])
  end

  defp restore(token, vault), do: token |> as() |> post("/api/vaults/#{vault.id}/restore")

  # An unrestricted grant has no levels to record the trash in, so restore
  # compares the vault's deletion with the grant's creation instead. Such a
  # grant is minted only while nothing is in the trash (a trashed vault makes
  # the pick leveled, below), so this is a vault deleted after consent whose
  # `deleted_at` predates the grant: a skewed clock, or a row written by hand.
  #
  # Restore and the trash listing are REST, which a token minted now cannot
  # reach (401, asserted). The comparison runs for the grant's tokens minted
  # before #1997 (legacy `aud`, 15-minute life), so it is pinned with one.
  describe "oauth: an all-vaults grant and the trash" do
    test "cannot restore a vault deleted before it, can restore one deleted after", ctx do
      # Every vault at write, policy write, nothing in the trash: NULL grant.
      token = credential(ctx, :oauth, levels_all(ctx, "write"))
      assert Engram.Permissions.vault_scope(%{oauth_access: claims_scope(token)}) == :all
      legacy = legacy_audience(ctx.user, token)

      {:ok, _} = Vaults.delete_vault(ctx.user, ctx.n.id)

      # Recorded as deleted before the grant (`deleted_at` has second
      # precision, and the same second counts as after).
      n_id = ctx.n.id

      Engram.Repo.update_all(
        from(v in Engram.Vaults.Vault, where: v.id == ^n_id),
        [set: [deleted_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)]],
        skip_tenant_check: true
      )

      assert restore(token, ctx.n).status == 401
      assert restore(legacy, ctx.n).status == 403
      refute to_string(ctx.n.id) in deleted_ids(legacy)

      # Deleted after the grant: still its to restore.
      assert legacy |> as() |> delete("/api/vaults/#{ctx.w.id}") |> json_response(200)
      assert to_string(ctx.w.id) in deleted_ids(legacy)
      assert restore(token, ctx.w).status == 401
      assert restore(legacy, ctx.w).status == 200
    end

    test "every live vault at write while one is in the trash is a leveled grant", ctx do
      {:ok, _} = Vaults.delete_vault(ctx.user, ctx.n.id)

      token =
        credential(
          ctx,
          :oauth,
          {%{to_string(ctx.w.id) => "write", to_string(ctx.r.id) => "write"}, "write"}
        )

      refute Engram.Permissions.vault_scope(%{oauth_access: claims_scope(token)}) == :all
      assert restore(legacy_audience(ctx.user, token), ctx.n).status == 404
      {:ok, _} = Vaults.restore_vault(ctx.user, ctx.n.id)
      assert reads(:oauth, token, ctx.n) == :refused
    end
  end

  # Parity with the all-vaults OAuth grant above: a key created without
  # levels has none to record the trash in either, so restore compares the
  # vault's deletion with the key's creation.
  describe "api_key: an unrestricted key and the trash" do
    test "cannot restore or list a vault deleted before it, can one deleted after", ctx do
      {:ok, _} = Vaults.delete_vault(ctx.user, ctx.n.id)
      n_id = ctx.n.id

      Engram.Repo.update_all(
        from(v in Engram.Vaults.Vault, where: v.id == ^n_id),
        [set: [deleted_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)]],
        skip_tenant_check: true
      )

      {:ok, raw, _} = Accounts.create_api_key(ctx.user, "legacy")

      refute to_string(ctx.n.id) in deleted_ids(raw)
      assert restore(raw, ctx.n).status == 403

      assert raw |> as() |> delete("/api/vaults/#{ctx.w.id}") |> json_response(200)
      assert to_string(ctx.w.id) in deleted_ids(raw)
      assert restore(raw, ctx.w).status == 200
    end
  end

  defp levels_all(ctx, default),
    do: {Map.new([ctx.w, ctx.r, ctx.n], &{to_string(&1.id), "write"}), default}

  defp claims_scope(token) do
    {:ok, claims} = Accounts.grant_claims(token)
    Engram.Permissions.from_claims(claims)
  end

  for kind <- [:oauth, :api_key] do
    describe "#{kind}: soft-deleted vaults" do
      test "one deleted before the credential is not covered by a write policy", ctx do
        {:ok, _} = Vaults.delete_vault(ctx.user, ctx.n.id)
        token = credential(ctx, unquote(kind), {%{to_string(ctx.w.id) => "write"}, "write"})

        # The trash listing and restore are REST: an API key's surface.
        if unquote(kind) == :api_key do
          refute to_string(ctx.n.id) in deleted_ids(token)
          assert restore(token, ctx.n).status == 404
        end

        assert {:ok, _} = Vaults.restore_vault(ctx.user, ctx.n.id)
        assert reads(unquote(kind), token, ctx.n) == :refused
      end
    end
  end

  # Restoring is REST, so an API key's (an OAuth token's 401 is pinned in
  # vault_access_attack_test.exs).
  describe "api_key: restoring soft-deleted vaults" do
    test "one reached only through the policy cannot be restored by it", ctx do
      token = credential(ctx, :api_key, levels(ctx, "write"))
      later = later_vault(ctx)
      {:ok, _} = Vaults.delete_vault(ctx.user, later.id)

      assert restore(token, later).status == 403
    end

    test "one listed at write can be deleted and restored by it", ctx do
      token = credential(ctx, :api_key, levels(ctx, "none"))

      assert token |> as() |> delete("/api/vaults/#{ctx.w.id}") |> json_response(200)
      assert to_string(ctx.w.id) in deleted_ids(token)
      assert restore(token, ctx.w).status == 200
    end
  end

  describe "mcp:read grants" do
    test "never create, rename, delete or restore a vault", ctx do
      # The client asked for mcp:read; the user picked write for every vault.
      # The scope caps it.
      {verifier, challenge} = pkce_pair()
      redirect_uri = hd(ctx.client.redirect_uris)

      {:ok, session} =
        Local.issue_access_token(ctx.user.external_id, ctx.user.email)

      code =
        build_conn()
        |> put_req_header("authorization", "Bearer #{session}")
        |> post("/api/oauth/authorize/consent", %{
          "client_id" => ctx.client.client_id,
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "state" => "s",
          "scope" => "mcp:read",
          "default_access" => "write"
        })
        |> json_response(200)
        |> Map.fetch!("redirect_uri")
        |> code_from_redirect()

      ro =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => redirect_uri,
          "client_id" => ctx.client.client_id,
          "code_verifier" => verifier
        })
        |> json_response(200)
        |> Map.fetch!("access_token")

      # As minted the token is MCP-bound: every vault route is 401. Under the
      # legacy `aud` (a token minted before #1997) it reaches the vaults
      # controller, where the read-only scope refuses it.
      legacy = legacy_audience(ctx.user, ro)

      for {t, status} <- [{ro, 401}, {legacy, 403}] do
        assert t
               |> as()
               |> post("/api/vaults/register", %{
                 "name" => "N",
                 "client_id" => Ecto.UUID.generate()
               })
               |> Map.fetch!(:status) == status

        assert (t |> as() |> patch("/api/vaults/#{ctx.w.id}", %{"name" => "x"})).status == status
        assert (t |> as() |> delete("/api/vaults/#{ctx.w.id}")).status == status
        assert (t |> as() |> post("/api/vaults/#{ctx.w.id}/restore")).status == status
      end

      assert {:ok, %{name: "Writable", deleted_at: nil}} = Vaults.get_vault(ctx.user, ctx.w.id)
      assert length(Vaults.list_vaults(ctx.user)) == 3
    end
  end

  describe "storage" do
    test "refresh copies levels and the new-vaults policy unchanged", ctx do
      {verifier, challenge} = pkce_pair()
      redirect_uri = hd(ctx.client.redirect_uris)
      {map, _} = levels(ctx, "read")

      {:ok, validated} =
        OAuth.validate_authorization_request(%{
          "client_id" => ctx.client.client_id,
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "scope" => "mcp"
        })

      {:ok, url} = OAuth.mint_authorization_code(ctx.user, validated, {map, "read"}, nil)

      {:ok, first} =
        OAuth.exchange_authorization_code(%{
          "code" => code_from_redirect(url),
          "client_id" => ctx.client.client_id,
          "redirect_uri" => redirect_uri,
          "code_verifier" => verifier
        })

      {:ok, second} = OAuth.rotate_refresh_token(first.refresh_token, ctx.client.client_id)
      # The token references its grant; the levels resolve from the rotated
      # row, so the row must still carry them.
      {:ok, claims} = Accounts.grant_claims(second.access_token)

      assert claims["vault_access"] == map
      assert claims["default_access"] == "read"
      # Back-compat claim: the WRITE vaults only, so a reader that predates
      # levels (which reads every listed id as write) cannot widen read.
      assert claims["vault_ids"] == [to_string(ctx.w.id)]
    end

    test "GET /api/vaults advertises access-level support", ctx do
      {:ok, session} = Local.issue_access_token(ctx.user.external_id, ctx.user.email)

      assert session
             |> as()
             |> get("/api/vaults")
             |> json_response(200)
             |> Map.get("access_levels")
    end

    defp consent(ctx, extra) do
      {_verifier, challenge} = pkce_pair()
      {:ok, session} = Local.issue_access_token(ctx.user.external_id, ctx.user.email)

      session
      |> as()
      |> post(
        "/api/oauth/authorize/consent",
        Map.merge(
          %{
            "client_id" => ctx.client.client_id,
            "redirect_uri" => hd(ctx.client.redirect_uris),
            "response_type" => "code",
            "code_challenge" => challenge,
            "code_challenge_method" => "S256",
            "state" => "s",
            "scope" => "mcp"
          },
          extra
        )
      )
      |> json_response(200)
    end

    test "consent echoes the stored grant", ctx do
      {map, _} = levels(ctx, "none")
      granted = consent(ctx, %{"vault_access" => map, "default_access" => "none"})["granted"]

      assert granted == %{
               "scope" => "mcp",
               "vault_access" => %{to_string(ctx.w.id) => "write", to_string(ctx.r.id) => "read"},
               "default_access" => "none"
             }
    end

    test "consent echoes the read-only cap", ctx do
      granted = consent(ctx, %{"default_access" => "write", "read_only" => true})["granted"]

      assert granted["scope"] == "mcp:read"
      assert granted["default_access"] == "read"
    end

    test "consent echoes a pre-levels all-vaults grant as write everywhere", ctx do
      granted = consent(ctx, %{"vault_choice" => "vault:*"})["granted"]
      assert {granted["vault_access"], granted["default_access"]} == {%{}, "write"}
    end

    for path <- ["/api/api-keys", "/api/connections/pat"] do
      test "#{path} echoes the stored levels", ctx do
        {:ok, session} = Local.issue_access_token(ctx.user.external_id, ctx.user.email)
        {map, _} = levels(ctx, "read")

        body =
          session
          |> as()
          |> post(unquote(path), %{
            "name" => "k",
            "vault_access" => map,
            "default_access" => "read"
          })
          |> json_response(unquote(if path == "/api/api-keys", do: 200, else: 201))

        assert body["vault_access"] == map
        assert body["default_access"] == "read"
      end

      test "#{path} echoes an unrestricted key as write everywhere", ctx do
        {:ok, session} = Local.issue_access_token(ctx.user.external_id, ctx.user.email)

        body =
          session
          |> as()
          |> post(unquote(path), %{"name" => "k"})
          |> json_response(unquote(if path == "/api/api-keys", do: 200, else: 201))

        assert {body["vault_access"], body["default_access"]} == {%{}, "write"}
      end
    end

    test "a consent that reaches nothing is refused, not minted", ctx do
      {_verifier, challenge} = pkce_pair()
      redirect_uri = hd(ctx.client.redirect_uris)

      {:ok, session} =
        Local.issue_access_token(ctx.user.external_id, ctx.user.email)

      url =
        build_conn()
        |> put_req_header("authorization", "Bearer #{session}")
        |> post("/api/oauth/authorize/consent", %{
          "client_id" => ctx.client.client_id,
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "state" => "s",
          "vault_access" => %{to_string(ctx.w.id) => "none"},
          "default_access" => "none"
        })
        |> json_response(200)
        |> Map.fetch!("redirect_uri")

      assert url =~ "error=access_denied"
    end

    test "a consent naming a vault the user does not own is refused", ctx do
      {_verifier, challenge} = pkce_pair()
      redirect_uri = hd(ctx.client.redirect_uris)
      other = insert(:vault)

      {:ok, session} =
        Local.issue_access_token(ctx.user.external_id, ctx.user.email)

      url =
        build_conn()
        |> put_req_header("authorization", "Bearer #{session}")
        |> post("/api/oauth/authorize/consent", %{
          "client_id" => ctx.client.client_id,
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "state" => "s",
          "vault_access" => %{to_string(other.id) => "write"}
        })
        |> json_response(200)
        |> Map.fetch!("redirect_uri")

      assert url =~ "error=access_denied"
    end

    test "an API key created without levels keeps full write on every vault", ctx do
      {:ok, raw, _} = Accounts.create_api_key(ctx.user, "legacy")
      assert written?(write_note(raw, ctx.r))
    end

    test "an API key naming a vault the user does not own is refused", ctx do
      other = insert(:vault)

      assert {:error, :invalid_access} =
               Accounts.create_api_key(ctx.user, "k", {%{to_string(other.id) => "read"}, "none"})
    end
  end

  describe "key creation endpoints" do
    for path <- ["/api/connections/pat", "/api-keys"] do
      test "#{path} stores per-vault levels and the new-vaults policy", ctx do
        {:ok, session} =
          Local.issue_access_token(ctx.user.external_id, ctx.user.email)

        {map, _} = levels(ctx, "read")
        path = String.replace_prefix(unquote(path), "/api-keys", "/api/api-keys")

        body =
          build_conn()
          |> put_req_header("authorization", "Bearer #{session}")
          |> post(path, %{"name" => "scoped", "vault_access" => map, "default_access" => "read"})
          |> json_response(if(path =~ "pat", do: 201, else: 200))

        assert refusal(write_note(body["key"], ctx.r)) =~ "read-only"
        assert written?(write_note(body["key"], ctx.w))
      end

      test "#{path} rejects an unknown level", ctx do
        {:ok, session} =
          Local.issue_access_token(ctx.user.external_id, ctx.user.email)

        path = String.replace_prefix(unquote(path), "/api-keys", "/api/api-keys")

        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{session}")
          |> post(path, %{"name" => "bad", "vault_access" => %{to_string(ctx.w.id) => "admin"}})

        assert conn.status == 422
      end
    end
  end

  # The access token carries a grant REFERENCE (`gid`, the family id) and the
  # fail-closed legacy `vault_ids`, never the per-vault map: its size must not
  # grow with the user's vault count, and the server resolves levels from the
  # grant row, so a revoke takes effect at once rather than at `exp`.
  describe "OAuth access token: grant reference" do
    defp token_claims(token) do
      {:ok, claims} = Engram.Token.verify(token)
      claims
    end

    defp many_vaults(ctx, n), do: for(_ <- 1..n, do: insert(:vault, user: ctx.user))

    test "500 vaults at write with a read policy: under 2 KB, levels still enforced", ctx do
      vaults = many_vaults(ctx, 500)
      access = Map.new(vaults, &{to_string(&1.id), "write"})

      token = credential(ctx, :oauth, {access, "read"})
      claims = token_claims(token)

      assert byte_size(token) < 2_048
      refute Map.has_key?(claims, "vault_access")
      refute Map.has_key?(claims, "default_access")
      assert claims["vault_ids"] == ["00000000-0000-0000-0000-000000000000"]
      assert is_binary(claims["gid"])

      # Resolved server-side: a listed vault writes, an unlisted one reads.
      assert written?(write_note(token, hd(vaults)))
      assert refusal(write_note(token, ctx.r)) =~ "read-only"
      assert reads(:oauth, token, ctx.r) == :ok
    end

    test "500 vaults at none with a write policy: under 2 KB, no none entries", ctx do
      vaults = many_vaults(ctx, 500)
      access = Map.new(vaults, &{to_string(&1.id), "none"})

      token = credential(ctx, :oauth, {access, "write"})

      assert byte_size(token) < 2_048
      assert reads(:oauth, token, hd(vaults)) == :refused
      assert reads(:oauth, token, ctx.r) == :ok
    end

    test "a revoked grant's access token stops working at once", ctx do
      token = credential(ctx, :oauth, levels(ctx, "none"))
      assert reads(:oauth, token, ctx.r) == :ok

      family = token_claims(token)["gid"]
      assert :ok = Engram.Connections.revoke_oauth_grant(ctx.user.id, family)

      assert token
             |> as()
             |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
             |> Map.get(:status) == 401

      assert upload(token, ctx.w).status == 401

      # REST and the socket refuse this token for its audience anyway; the
      # revoke reaching them is pinned with a legacy-audience token here and in
      # grant_revocation_socket_test.exs.
      legacy = legacy_audience(ctx.user, token)
      assert rest_read(legacy, ctx.r).status == 401
      assert :error = EngramWeb.UserSocket.connect(%{"token" => legacy}, %Phoenix.Socket{}, %{})
    end
  end
end
