defmodule EngramWeb.VaultAccessAttackTest do
  @moduledoc """
  Attack regressions for per-vault access levels (#174 OAuth, #332 API keys),
  imported from a red-team pass. Each test asserts the DEFENDED behaviour, so
  a failure is a bypass. The MCP loops enumerate the real tool registry, so
  a new tool is covered without editing this file. The REST attacks read
  every route behind `VaultPlug` from the router, and a new route fails until
  it is classified as a read or added to the attacked writes.

  Vaults: W (write), R (read), N (none). Credentials come from the real
  consent -> /oauth/token chain or `Accounts.create_api_key/3`.

  An OAuth access token is bound to the MCP server (#1997): it reaches
  `POST /api/mcp` and `POST /api/attachments` (the upload its tools hand out)
  and gets 401 everywhere else. So the REST attacks run with API keys, the
  OAuth ones run on MCP and the upload, and one test walks every vault route
  to pin the 401 itself. Where a guard behind Auth still matters for a token
  minted before #1997 (legacy `aud`, alive for 15 minutes),
  `Engram.OAuthHelpers.legacy_audience/2` stands in for one.
  """
  use EngramWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Engram.OAuthHelpers, only: [code_from_redirect: 1, legacy_audience: 2, pkce_pair: 0]

  alias Engram.{Accounts, OAuth, Repo, Vaults}
  alias Engram.Auth.Providers.Local
  alias Engram.MCP.Tools

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    insert(:user_limit_override, user: user, key: "api_rps_cap", value: %{"v" => 1000})
    insert(:user_limit_override, user: user, key: "api_write_enabled", value: %{"v" => true})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    user = ensure_external_id(user)

    {:ok, w, _} = Vaults.register_vault(user, "Writable", Ecto.UUID.generate())
    {:ok, r, _} = Vaults.register_vault(user, "Readable", Ecto.UUID.generate())
    {:ok, n, _} = Vaults.register_vault(user, "Hidden", Ecto.UUID.generate())

    notes =
      Map.new([w, r, n], fn v ->
        {:ok, note} =
          Engram.Notes.upsert_note(
            user,
            v,
            %{"path" => "Dir/a.md", "content" => "secret in #{v.name}", "mtime" => 1.0},
            actor: "api"
          )

        {v.id, note}
      end)

    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://evil.example/callback"],
        "client_name" => "Evil"
      })

    %{user: user, w: w, r: r, n: n, notes: notes, client: client}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp levels(ctx, default \\ "none") do
    {%{
       to_string(ctx.w.id) => "write",
       to_string(ctx.r.id) => "read",
       to_string(ctx.n.id) => "none"
     }, default}
  end

  defp session(ctx) do
    {:ok, s} = Local.issue_access_token(ctx.user.external_id, ctx.user.email)
    s
  end

  defp credential(ctx, :api_key, access) do
    {:ok, raw, _key} = Accounts.create_api_key(ctx.user, "key", access)
    raw
  end

  defp credential(ctx, :oauth, access), do: oauth_grant(ctx, access, "mcp")["access_token"]

  defp oauth_grant(ctx, {map, default}, scope) do
    {verifier, challenge} = pkce_pair()
    redirect_uri = hd(ctx.client.redirect_uris)

    params = %{
      "client_id" => ctx.client.client_id,
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => "s",
      "scope" => scope,
      "vault_access" => map,
      "default_access" => default
    }

    code =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session(ctx)}")
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
  end

  defp as(token), do: put_req_header(build_conn(), "authorization", "Bearer #{token}")

  defp in_vault(token, vault),
    do: token |> as() |> put_req_header("x-vault-id", to_string(vault.id))

  defp mcp(token, method, params) do
    token
    |> as()
    |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    |> json_response(200)
  end

  defp tool(token, name, args),
    do: mcp(token, "tools/call", %{"name" => name, "arguments" => args})

  # The one REST route an OAuth token reaches (#1997). `nil` vault: no
  # X-Vault-ID, so the default vault.
  defp upload(token, vault, path \\ "f.txt") do
    conn = if vault, do: in_vault(token, vault), else: as(token)
    post(conn, "/api/attachments", %{"path" => path, "content_base64" => "aGk="})
  end

  defp attachment?(ctx, vault, path \\ "f.txt"),
    do: match?({:ok, %{}}, Engram.Attachments.get_attachment(ctx.user, vault, path))

  defp refused_tool?(body),
    do: body["error"] != nil or get_in(body, ["result", "isError"]) == true

  defp note_content(ctx, vault, path) do
    case Engram.Notes.get_note(ctx.user, vault, path) do
      {:ok, note} -> note.content
      _ -> nil
    end
  end

  # Every vault-scoped write route, with a body that would succeed on a
  # writable vault. `idem` routes need X-Idempotency-Key.
  defp write_routes(ctx, vault) do
    note = ctx.notes[vault.id]

    [
      {:post, "/api/notes", %{"path" => "x.md", "content" => "pwn", "mtime" => 2.0}},
      {:post, "/api/notes/append", %{"path" => "Dir/a.md", "text" => "pwn"}},
      {:post, "/api/notes/rename", %{"old_path" => "Dir/a.md", "new_path" => "Dir/b.md"}},
      {:delete, "/api/notes/Dir/a.md", %{}},
      {:delete, "/api/notes/by-id/#{note.id}", %{}},
      {:post, "/api/notes/batch-delete", %{"ids" => [note.id]}},
      {:post, "/api/notes/batch-move", %{"ids" => [note.id], "target_folder" => "Moved"}},
      {:post, "/api/folders", %{"folder" => "NewDir"}},
      {:post, "/api/folders/rename", %{"old_path" => "Dir", "new_path" => "Dir2"}},
      {:delete, "/api/folders/Dir", %{}},
      {:post, "/api/folders/batch-delete", %{"ids" => [Ecto.UUID.generate()]}},
      {:post, "/api/folders/batch-move",
       %{"ids" => [Ecto.UUID.generate()], "target_parent" => "X"}},
      {:post, "/api/attachments", %{"path" => "f.png", "content_base64" => "aGk="}},
      {:post, "/api/attachments/rename", %{"old_path" => "f.png", "new_path" => "g.png"}},
      {:delete, "/api/attachments/f.png", %{}},
      {:post, "/api/attachments/batch-move", %{"paths" => ["f.png"], "target_folder" => "X"}},
      {:post, "/api/attachments/batch-delete", %{"paths" => ["f.png"]}},
      {:post, "/api/logs", %{"logs" => [%{"level" => "info", "message" => "m"}]}}
    ]
  end

  defp send_req(conn, :post, path, body),
    do: conn |> put_req_header("x-idempotency-key", Ecto.UUID.generate()) |> post(path, body)

  defp send_req(conn, :delete, path, body), do: delete(conn, path, body)
  defp send_req(conn, :get, path, _), do: get(conn, path)

  # An OAuth token gets 401 on all of these ("oauth: outside /api/mcp"
  # below); its one REST write, the upload, is attacked there.
  describe "api_key: REST writes on a READ vault" do
    @kind :api_key
    test "every vault-scoped write route is refused 403 and changes nothing", ctx do
      token = credential(ctx, @kind, levels(ctx))

      for {method, path, body} <- write_routes(ctx, ctx.r) do
        conn = token |> in_vault(ctx.r) |> send_req(method, path, body)

        assert conn.status == 403,
               "#{method} #{path} on READ vault returned #{conn.status}: #{conn.resp_body}"
      end

      assert note_content(ctx, ctx.r, "Dir/a.md") =~ "secret in Readable"
    end

    test "REST baseline: no write route is 403 on the WRITE vault", ctx do
      token = credential(ctx, @kind, levels(ctx))

      for {method, path, body} <- write_routes(ctx, ctx.w) do
        conn = token |> in_vault(ctx.w) |> send_req(method, path, body)

        refute conn.status in [401, 403],
               "#{method} #{path} on W -> #{conn.status} #{conn.resp_body}"
      end
    end

    test "every vault-scoped write route is refused on a NONE vault", ctx do
      token = credential(ctx, @kind, levels(ctx))

      for {method, path, body} <- write_routes(ctx, ctx.n) do
        conn = token |> in_vault(ctx.n) |> send_req(method, path, body)
        assert conn.status == 404, "#{method} #{path} on NONE vault returned #{conn.status}"
      end
    end

    test "default-vault fallback (no X-Vault-ID) honours the level", ctx do
      # Make R the default vault, then write with no header.
      {:ok, _} = Vaults.update_vault(ctx.user, ctx.r.id, %{"is_default" => true})
      token = credential(ctx, @kind, levels(ctx))

      conn =
        token |> as() |> post("/api/notes", %{"path" => "y.md", "content" => "x", "mtime" => 1})

      assert conn.status == 403
    end

    test "a NONE default vault is not readable through the fallback", ctx do
      {:ok, _} = Vaults.update_vault(ctx.user, ctx.n.id, %{"is_default" => true})
      token = credential(ctx, @kind, levels(ctx))
      conn = token |> as() |> get("/api/notes/Dir/a.md")
      assert conn.status == 404
      refute conn.resp_body =~ "secret"
    end

    test "reads on a NONE vault are refused on every GET route", ctx do
      token = credential(ctx, @kind, levels(ctx))
      note = ctx.notes[ctx.n.id]

      for path <- [
            "/api/notes/Dir/a.md",
            "/api/notes/by-id/#{note.id}",
            "/api/notes/by-id/#{note.id}/backlinks",
            "/api/tags",
            "/api/types",
            "/api/folders",
            "/api/folders/list",
            "/api/folders/explicit",
            "/api/vault/tree",
            "/api/sync/manifest",
            "/api/attachments",
            "/api/attachments/changes",
            "/api/logs",
            "/api/embed-status"
          ] do
        conn = token |> in_vault(ctx.n) |> get(path)
        assert conn.status == 404, "GET #{path} on NONE vault returned #{conn.status}"
      end

      conn = token |> in_vault(ctx.n) |> post("/api/search", %{"query" => "secret"})
      assert conn.status == 404
    end

    test "a NONE vault's note id is not reachable through a writable vault header", ctx do
      token = credential(ctx, @kind, levels(ctx))
      n_note = ctx.notes[ctx.n.id]
      r_note = ctx.notes[ctx.r.id]

      assert (token |> in_vault(ctx.w) |> get("/api/notes/by-id/#{n_note.id}")).status == 404

      assert (token |> in_vault(ctx.w) |> get("/api/notes/by-id/#{n_note.id}/backlinks")).status ==
               404

      # Destructive by-id ops under a WRITE header against R/N note ids.
      for id <- [n_note.id, r_note.id] do
        conn = token |> in_vault(ctx.w) |> delete("/api/notes/by-id/#{id}")
        assert conn.status == 404, "delete_by_id cross-vault returned #{conn.status}"

        conn =
          token
          |> in_vault(ctx.w)
          |> send_req(:post, "/api/notes/batch-delete", %{"ids" => [id]})

        assert conn.status in [404, 409], "batch-delete cross-vault returned #{conn.status}"

        conn =
          token
          |> in_vault(ctx.w)
          |> send_req(:post, "/api/notes/batch-move", %{"ids" => [id], "target_folder" => "M"})

        assert conn.status in [404, 409], "batch-move cross-vault returned #{conn.status}"
      end

      assert note_content(ctx, ctx.n, "Dir/a.md") =~ "secret in Hidden"
      assert note_content(ctx, ctx.r, "Dir/a.md") =~ "secret in Readable"
    end

    test "vault management: rename/delete/default of a READ vault refused", ctx do
      token = credential(ctx, @kind, levels(ctx))

      assert (token |> as() |> patch("/api/vaults/#{ctx.r.id}", %{"name" => "pwn"})).status ==
               403

      assert (token |> as() |> patch("/api/vaults/#{ctx.r.id}", %{"is_default" => true})).status ==
               403

      assert (token |> as() |> delete("/api/vaults/#{ctx.r.id}")).status == 403
      assert (token |> as() |> get("/api/vaults/#{ctx.n.id}")).status == 404
      {:ok, still} = Vaults.get_vault(ctx.user, ctx.r.id)
      assert still.name == "Readable"
    end

    test "GET /api/vaults and /api/bootstrap never list the NONE vault", ctx do
      token = credential(ctx, @kind, levels(ctx))
      ids = token |> as() |> get("/api/vaults") |> json_response(200) |> Map.fetch!("vaults")
      refute Enum.any?(ids, &(&1["id"] == ctx.n.id))
      boot = token |> as() |> get("/api/bootstrap")

      assert boot.status == 200
      refute boot.resp_body =~ ctx.n.id
      refute boot.resp_body =~ "Hidden"
    end

    test "register with a READ vault's client_id does not hand back write", ctx do
      token = credential(ctx, @kind, levels(ctx, "write"))

      conn =
        token
        |> as()
        |> post("/api/vaults/register", %{"name" => "x", "client_id" => ctx.r.client_id})

      # Existing: allowed to read the vault row. Must not be a write path.
      assert conn.status in [200, 403]
      {:ok, still} = Vaults.get_vault(ctx.user, ctx.r.id)
      assert still.name == "Readable"
    end

    test "register with a NONE vault's client_id does not reveal it", ctx do
      token = credential(ctx, @kind, levels(ctx, "write"))

      conn =
        token
        |> as()
        |> post("/api/vaults/register", %{"name" => "x", "client_id" => ctx.n.client_id})

      assert conn.status == 403
      refute conn.resp_body =~ "Hidden"
    end

    test "a READ-level grant cannot restore a deleted READ vault", ctx do
      token = credential(ctx, @kind, levels(ctx, "write"))
      {:ok, _} = Vaults.delete_vault(ctx.user, ctx.r.id)
      assert (token |> as() |> post("/api/vaults/#{ctx.r.id}/restore")).status == 403
    end
  end

  for kind <- [:api_key, :oauth] do
    describe "#{kind}: MCP on the READ and NONE vaults" do
      @kind kind
      test "MCP: every write tool is refused on R and N; reads of N refused", ctx do
        token = credential(ctx, @kind, levels(ctx))

        writes =
          Tools.all_callable()
          |> Enum.filter(&Tools.writes_vault?(&1.name))

        for t <- writes, vault <- [ctx.r, ctx.n] do
          args = mcp_args(t.name, vault)
          body = tool(token, t.name, args)
          assert refused_tool?(body), "#{t.name} on #{vault.name} went through: #{inspect(body)}"
          want = if vault.id == ctx.r.id, do: "read-only", else: "restricted to a subset"

          if t in Tools.list(),
            do: assert(inspect(body) =~ want, "#{t.name} on #{vault.name}: #{inspect(body)}")
        end

        assert note_content(ctx, ctx.r, "Dir/a.md") =~ "secret in Readable"
        assert note_content(ctx, ctx.n, "Dir/a.md") =~ "secret in Hidden"

        reads =
          Tools.all_callable()
          |> Enum.reject(
            &(Tools.writes_vault?(&1.name) or &1.name in ~w(list_vaults send_feedback))
          )

        for t <- reads do
          body = tool(token, t.name, mcp_args(t.name, ctx.n))
          refute inspect(body) =~ "secret in Hidden", "#{t.name} leaked N content"
          assert refused_tool?(body), "#{t.name} on N not refused: #{inspect(body)}"
        end
      end

      test "MCP baseline: the attack args are VALID (they work on W / read W)", ctx do
        token = credential(ctx, @kind, levels(ctx))

        for t <- Tools.list(), t.name not in ~w(send_feedback list_vaults) do
          body = tool(token, t.name, mcp_args(t.name, ctx.w))
          text = inspect(body)
          refute text =~ "Invalid or missing argument", "#{t.name}: #{text}"
          refute text =~ "Unknown argument", "#{t.name}: #{text}"
          refute text =~ "read-only", "#{t.name}: #{text}"
          refute text =~ "restricted to a subset", "#{t.name}: #{text}"
        end
      end

      test "MCP: NONE vault name gives the same refusal as a made-up name (no oracle)", ctx do
        token = credential(ctx, @kind, levels(ctx))
        real = tool(token, "get_notes", %{"vault_id" => "Hidden", "paths" => ["Dir/a.md"]})

        fake =
          tool(token, "get_notes", %{"vault_id" => "NoSuchVaultXyz", "paths" => ["Dir/a.md"]})

        strip = fn body, name ->
          body |> get_in(["result", "content"]) |> inspect() |> String.replace(name, "<V>")
        end

        assert strip.(real, "Hidden") == strip.(fake, "NoSuchVaultXyz")
        set_real = tool(token, "set_vault", %{"vault_id" => "Hidden"})
        set_fake = tool(token, "set_vault", %{"vault_id" => "NoSuchVaultXyz"})
        assert strip.(set_real, "Hidden") == strip.(set_fake, "NoSuchVaultXyz")
      end

      test "MCP: resources and completion never expose the NONE vault", ctx do
        token = credential(ctx, @kind, levels(ctx))
        list = mcp(token, "resources/list", %{})
        refute inspect(list) =~ ctx.n.slug
        refute inspect(list) =~ "secret in Hidden"

        read = mcp(token, "resources/read", %{"uri" => "engram://#{ctx.n.slug}/Dir/a.md"})
        refute inspect(read) =~ "secret in Hidden"

        comp =
          mcp(token, "completion/complete", %{
            "ref" => %{"type" => "ref/resource", "uri" => Engram.MCP.Resources.template_uri()},
            "argument" => %{"name" => "vault", "value" => ""}
          })

        refute inspect(comp) =~ ctx.n.slug
      end

      test "MCP: bare search never returns NONE vault hits", ctx do
        token = credential(ctx, @kind, levels(ctx))
        body = tool(token, "search_notes", %{"query" => "secret in Hidden"})
        refute inspect(body) =~ "secret in Hidden"
      end
    end
  end

  defp mcp_args(name, vault) do
    v = vault.id

    case name do
      "create_note" ->
        %{"vault_id" => v, "title" => "p", "content" => "pwn"}

      "write_note" ->
        %{"vault_id" => v, "path" => "Dir/a.md", "content" => "pwn"}

      "append_to_note" ->
        %{"vault_id" => v, "path" => "Dir/a.md", "text" => "pwn"}

      "edit_note" ->
        %{
          "vault_id" => v,
          "path" => "Dir/a.md",
          "mode" => "replace",
          "find" => "secret",
          "replace" => "pwn"
        }

      "rename_note" ->
        %{"vault_id" => v, "old_path" => "Dir/a.md", "new_path" => "Dir/z.md"}

      "rename_folder" ->
        %{"vault_id" => v, "old_folder" => "Dir", "new_folder" => "Dir9"}

      "delete_note" ->
        %{"vault_id" => v, "path" => "Dir/a.md"}

      "delete_folder" ->
        %{"vault_id" => v, "folder" => "Dir", "recursive" => true}

      "create_folder" ->
        %{"vault_id" => v, "folder" => "NewDir"}

      "move_attachment" ->
        %{"vault_id" => v, "old_path" => "a.png", "new_path" => "b.png"}

      "delete_attachment" ->
        %{"vault_id" => v, "path" => "a.png"}

      "get_attachment_upload_target" ->
        %{"vault_id" => v}

      "get_notes" ->
        %{"vault_id" => v, "paths" => ["Dir/a.md"], "include_links" => true}

      "search_notes" ->
        %{"vault_id" => v, "query" => "secret"}

      "list_folder" ->
        %{"vault_id" => v, "folder" => "Dir"}

      "set_vault" ->
        %{"vault_id" => v}

      "suggest_folder" ->
        %{"vault_id" => v, "description" => "secret"}

      _ ->
        %{"vault_id" => v}
    end
  end

  # ── every vault route, read from the router ────────────────────────────────
  #
  # The loops above walk a hand-kept list. These read the router itself: every
  # route behind `VaultPlug` is attacked, so a new route cannot skip the level
  # check by being left out of a list. A new route fails `classifies every
  # vault route` until it is named below, as a read or in `write_routes/2`.

  # Routes that only read. Non-GET entries must also be exempt in
  # `EngramWeb.ReadOnlyRoutes`.
  @vault_reads [
    {:get, "/api/notes/changes"},
    {:get, "/api/notes/by-id/:id"},
    {:get, "/api/notes/by-id/:id/backlinks"},
    {:get, "/api/notes/*path"},
    {:get, "/api/tags"},
    {:get, "/api/types"},
    {:get, "/api/folders/explicit"},
    {:get, "/api/folders/list"},
    {:get, "/api/folders/by-id/:id/notes"},
    {:get, "/api/folders"},
    {:get, "/api/vault/tree"},
    {:post, "/api/search"},
    {:get, "/api/sync/manifest"},
    {:get, "/api/attachments"},
    {:get, "/api/attachments/changes"},
    {:get, "/api/attachments/*path"},
    {:get, "/api/logs"},
    {:get, "/api/embed-status"}
  ]

  defp vault_routes do
    for r <- Phoenix.Router.routes(EngramWeb.Router),
        r.verb != :*,
        info = Phoenix.Router.route_info(EngramWeb.Router, verb(r), sample_path(r.path), ""),
        is_map(info),
        EngramWeb.Plugs.VaultPlug in Map.get(info, :pipe_through, []),
        do: {r.verb, r.path}
  end

  defp verb(route), do: route.verb |> to_string() |> String.upcase()

  # A concrete path for a route template: any value reaches VaultPlug, which
  # judges the vault before the controller reads a param.
  defp sample_path(template) do
    template
    |> String.replace(~r/\*\w+/, "Dir/a.md")
    |> String.replace(~r/:\w+/, Ecto.UUID.generate())
  end

  # The route template a concrete attack path belongs to.
  defp template_of({method, path, _body}) do
    Enum.find(vault_routes(), fn {verb, template} ->
      pattern =
        template
        |> String.replace(~r/\*\w+/, "\u0000")
        |> String.replace(~r/:\w+/, "\u0001")
        |> Regex.escape()
        |> String.replace("\u0000", ".+")
        |> String.replace("\u0001", "[^/]+")

      verb == method and Regex.match?(~r/^#{pattern}$/, path)
    end)
  end

  test "the router walk finds the vault routes", _ctx do
    routes = vault_routes()
    assert {:post, "/api/notes"} in routes
    assert {:get, "/api/notes/*path"} in routes
    refute Enum.any?(routes, fn {_, path} -> path == "/api/mcp" end)
  end

  test "classifies every vault route as a read or an attacked write", ctx do
    attacked = ctx |> write_routes(ctx.r) |> Enum.map(&template_of/1)

    unclassified = vault_routes() -- (@vault_reads ++ attacked)

    assert unclassified == [],
           "vault routes neither attacked in write_routes/2 nor listed in @vault_reads: " <>
             inspect(unclassified)

    stale = @vault_reads -- vault_routes()
    assert stale == [], "@vault_reads names routes the router no longer has: #{inspect(stale)}"
  end

  test "every vault route outside @vault_reads is a write to ReadOnlyRoutes", _ctx do
    for {verb, template} <- vault_routes(), {verb, template} not in @vault_reads do
      conn = %Plug.Conn{
        method: verb |> to_string() |> String.upcase(),
        path_info: template |> sample_path() |> String.split("/", trim: true)
      }

      assert EngramWeb.ReadOnlyRoutes.writes?(conn),
             "#{verb} #{template} is not a write to ReadOnlyRoutes, so a read vault could call it"
    end
  end

  describe "api_key: every vault route from the router" do
    @kind :api_key
    test "is refused on a NONE vault, reads included", ctx do
      token = credential(ctx, @kind, levels(ctx))

      for {verb, template} <- vault_routes() do
        conn = token |> in_vault(ctx.n) |> send_req(verb, sample_path(template), %{})

        assert conn.status == 404,
               "#{verb} #{template} on NONE vault returned #{conn.status}: #{conn.resp_body}"
      end
    end

    test "is refused on a READ vault unless it only reads", ctx do
      token = credential(ctx, @kind, levels(ctx))

      for {verb, template} <- vault_routes(), {verb, template} not in @vault_reads do
        conn = token |> in_vault(ctx.r) |> send_req(verb, sample_path(template), %{})

        assert conn.status == 403,
               "#{verb} #{template} on READ vault returned #{conn.status}: #{conn.resp_body}"
      end

      assert note_content(ctx, ctx.r, "Dir/a.md") =~ "secret in Readable"
    end
  end

  # REST routes outside VaultPlug that act on a vault or list them.
  defp vault_management_routes(ctx) do
    [
      {:get, "/api/vaults", nil},
      {:get, "/api/vaults?deleted=true", nil},
      {:get, "/api/bootstrap", nil},
      {:get, "/api/vaults/#{ctx.w.id}", nil},
      {:patch, "/api/vaults/#{ctx.w.id}", %{"name" => "pwn"}},
      {:delete, "/api/vaults/#{ctx.w.id}", nil},
      {:post, "/api/vaults/#{ctx.w.id}/restore", nil},
      {:post, "/api/vaults/register", %{"name" => "pwn", "client_id" => Ecto.UUID.generate()}}
    ]
  end

  describe "oauth: outside /api/mcp" do
    # The audience boundary itself: a live token, on the vault its grant
    # writes, refused on every route but the upload.
    for scope <- ["mcp", "mcp:read"] do
      @scope scope
      test "a live #{scope} token gets 401 on every REST route but the upload", ctx do
        token = oauth_grant(ctx, levels(ctx), @scope)["access_token"]

        routes =
          for(
            {verb, template} <- vault_routes(),
            {verb, template} != {:post, "/api/attachments"},
            do: {verb, sample_path(template), %{}}
          ) ++ vault_management_routes(ctx)

        for {verb, path, body} <- routes do
          conn = token |> in_vault(ctx.w) |> mgmt(verb, path, body)
          msg = "#{verb} #{path} -> #{conn.status} #{conn.resp_body}"
          assert conn.status == 401, msg

          assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")],
                 msg
        end

        assert {:ok, %{name: "Writable", deleted_at: nil}} = Vaults.get_vault(ctx.user, ctx.w.id)
        assert note_content(ctx, ctx.w, "Dir/a.md") =~ "secret in Writable"

        # Live: the same token works where it is meant to.
        assert ctx.w.id in (tool(token, "list_vaults", %{})
                            |> get_in(["result", "structuredContent", "vaults"])
                            |> Enum.map(& &1["id"]))

        refute upload(token, ctx.w).status == 401
      end
    end

    test "upload honours the levels: W stores, R is 403, N is 404 like a random vault", ctx do
      token = credential(ctx, :oauth, levels(ctx))

      assert upload(token, ctx.w).status in 200..201
      assert attachment?(ctx, ctx.w)

      assert json_response(upload(token, ctx.r), 403) == %{"error" => "read_only_vault"}
      refute attachment?(ctx, ctx.r)

      real = upload(token, ctx.n)
      fake = upload(token, %{id: Ecto.UUID.generate()})
      assert real.status == 404
      assert {real.status, real.resp_body} == {fake.status, fake.resp_body}
      refute attachment?(ctx, ctx.n)
    end

    test "upload without X-Vault-ID honours the default vault's level", ctx do
      token = credential(ctx, :oauth, levels(ctx))

      {:ok, _} = Vaults.update_vault(ctx.user, ctx.n.id, %{"is_default" => true})
      assert upload(token, nil).status == 404
      refute attachment?(ctx, ctx.n)

      {:ok, _} = Vaults.update_vault(ctx.user, ctx.r.id, %{"is_default" => true})
      assert json_response(upload(token, nil), 403) == %{"error" => "read_only_vault"}
      refute attachment?(ctx, ctx.r)
    end

    # The scope gate answers before any vault is resolved, so every vault
    # (N and one that does not exist included) gets the same refusal: no
    # write, and no oracle.
    test "an mcp:read token's upload is refused on every vault, alike", ctx do
      token = oauth_grant(ctx, levels(ctx), "mcp:read")["access_token"]
      fake = upload(token, %{id: Ecto.UUID.generate()})
      assert json_response(fake, 403) == %{"error" => "read_only_grant"}

      for vault <- [ctx.w, ctx.r, ctx.n, nil] do
        conn = upload(token, vault)
        assert {conn.status, conn.resp_body} == {fake.status, fake.resp_body}
      end

      for vault <- [ctx.w, ctx.r, ctx.n], do: refute(attachment?(ctx, vault))
    end
  end

  # REST oracles, so API keys: an OAuth token gets 401 on every one of these
  # routes. Its oracles are the MCP one above and the upload's.
  describe "existence oracle" do
    for kind <- [:api_key] do
      @kind kind
      test "#{kind}: X-Vault-ID of a NONE vault answers like a random uuid", ctx do
        token = credential(ctx, @kind, levels(ctx))
        real = token |> in_vault(ctx.n) |> get("/api/tags")
        fake = token |> in_vault(%{id: Ecto.UUID.generate()}) |> get("/api/tags")
        assert {real.status, real.resp_body} == {fake.status, fake.resp_body}
      end

      test "#{kind}: GET /api/vaults/:id of a NONE vault answers like a random uuid (read policy)",
           ctx do
        token = credential(ctx, @kind, levels(ctx, "read"))
        real = token |> as() |> get("/api/vaults/#{ctx.n.id}")
        fake = token |> as() |> get("/api/vaults/#{Ecto.UUID.generate()}")
        assert {real.status, real.resp_body} == {fake.status, fake.resp_body}
      end

      for policy <- ~w(none read write) do
        @policy policy
        test "#{kind}: vault management of a NONE vault answers like a random uuid (#{policy} policy)",
             ctx do
          token = credential(ctx, @kind, levels(ctx, @policy))
          fake_id = Ecto.UUID.generate()

          for {method, suffix, body} <- [
                {:get, "", nil},
                {:patch, "", %{"name" => "pwn"}},
                {:delete, "", nil},
                {:post, "/restore", nil}
              ] do
            real = token |> as() |> mgmt(method, "/api/vaults/#{ctx.n.id}#{suffix}", body)
            fake = token |> as() |> mgmt(method, "/api/vaults/#{fake_id}#{suffix}", body)

            assert {real.status, real.resp_body} == {fake.status, fake.resp_body},
                   "#{method} #{suffix}: NONE #{real.status} vs random #{fake.status}"
          end

          # The trashed case, which is what restore operates on.
          {:ok, _} = Vaults.delete_vault(ctx.user, ctx.n.id)
          real = token |> as() |> post("/api/vaults/#{ctx.n.id}/restore")
          fake = token |> as() |> post("/api/vaults/#{fake_id}/restore")
          assert {real.status, real.resp_body} == {fake.status, fake.resp_body}
          assert {:error, :not_found} = Vaults.get_vault(ctx.user, ctx.n.id)
        end
      end
    end

    test "legacy key: X-Vault-ID outside its list answers like a random uuid", ctx do
      raw = legacy_key_restricted_to(ctx, ctx.w)
      real = raw |> in_vault(ctx.n) |> get("/api/tags")
      fake = raw |> in_vault(%{id: Ecto.UUID.generate()}) |> get("/api/tags")
      assert real.status == 404
      assert {real.status, real.resp_body} == {fake.status, fake.resp_body}
    end

    test "a READ vault still answers read_only_vault to a write (it is visible)", ctx do
      token = credential(ctx, :api_key, levels(ctx))
      conn = token |> in_vault(ctx.r) |> send_req(:post, "/api/notes", %{"path" => "q.md"})
      assert conn.status == 403
      assert json_response(conn, 403) == %{"error" => "read_only_vault"}
    end
  end

  defp mgmt(conn, :get, path, _), do: get(conn, path)
  defp mgmt(conn, :patch, path, body), do: patch(conn, path, body)
  defp mgmt(conn, :delete, path, _), do: delete(conn, path)
  defp mgmt(conn, :post, path, nil), do: post(conn, path)
  defp mgmt(conn, :post, path, body), do: post(conn, path, body)

  defp legacy_key_restricted_to(ctx, vault) do
    {:ok, raw, key} = Accounts.create_api_key(ctx.user, "legacy", nil)

    Repo.insert_all("api_key_vaults", [
      %{api_key_id: Ecto.UUID.dump!(key.id), vault_id: Ecto.UUID.dump!(vault.id)}
    ])

    Engram.Cache.evict(:api_key, key.key_hash)
    raw
  end

  # ── escalation via PATCH / scope ───────────────────────────────────────────

  describe "escalation" do
    test "mcp:read grant cannot be PATCHed to write (per-vault or default)", ctx do
      grant = oauth_grant(ctx, {%{to_string(ctx.r.id) => "read"}, "none"}, "mcp:read")
      family = family_of(grant["refresh_token"])

      for body <- [
            %{"vault_access" => %{to_string(ctx.r.id) => "write"}, "default_access" => "none"},
            %{"vault_access" => %{}, "default_access" => "write"},
            %{"default_access" => "write"}
          ] do
        conn =
          session(ctx)
          |> as()
          |> patch("/api/connections/oauth/#{ctx.client.client_id}?family_id=#{family}", body)

        assert conn.status == 422, "mcp:read PATCH #{inspect(body)} -> #{conn.status}"
      end

      body =
        tool(grant["access_token"], "write_note", %{
          "vault_id" => ctx.r.id,
          "path" => "q.md",
          "content" => "x"
        })

      assert refused_tool?(body)
    end

    test "mcp:read: even if a write level lands in the row, from_claims caps it", ctx do
      grant = oauth_grant(ctx, {%{to_string(ctx.r.id) => "read"}, "none"}, "mcp:read")
      family = family_of(grant["refresh_token"])

      # Simulate a stored write level (old node / direct DB edit).
      Repo.update_all(
        from(t in Engram.OAuth.RefreshToken, where: t.family_id == ^family),
        [set: [vault_access: %{to_string(ctx.r.id) => "write"}, default_access: "write"]],
        skip_tenant_check: true
      )

      Engram.Cache.evict(:oauth_grant, family)

      assert json_response(upload(grant["access_token"], ctx.r), 403) == %{
               "error" => "read_only_grant"
             }

      refute attachment?(ctx, ctx.r)

      assert refused_tool?(
               tool(grant["access_token"], "write_note", %{
                 "vault_id" => ctx.r.id,
                 "path" => "q.md",
                 "content" => "x"
               })
             )
    end

    test "PATCH with another user's vault id is refused", ctx do
      other = insert(:user)
      {:ok, other} = Engram.Crypto.ensure_user_dek(other)
      {:ok, ov, _} = Vaults.register_vault(other, "TheirVault", Ecto.UUID.generate())
      {:ok, _raw, key} = Accounts.create_api_key(ctx.user, "k", levels(ctx))

      conn =
        session(ctx)
        |> as()
        |> patch("/api/connections/pat/#{key.id}", %{
          "vault_access" => %{to_string(ov.id) => "write"},
          "default_access" => "none"
        })

      assert conn.status == 422
    end

    test "PATCH body edge cases are refused and leave the key unchanged", ctx do
      {:ok, raw, key} = Accounts.create_api_key(ctx.user, "k", levels(ctx))

      for body <- [
            %{},
            %{"vault_access" => nil, "default_access" => nil},
            %{"default_access" => "WRITE"},
            %{"default_access" => "admin"},
            %{"vault_access" => [to_string(ctx.n.id)], "default_access" => "none"},
            %{"vault_access" => %{to_string(ctx.n.id) => "rw"}},
            %{"vault_access" => %{to_string(ctx.n.id) => true}},
            %{"vault_access" => %{"*" => "write"}},
            %{"vault_access" => %{}, "default_access" => "none"},
            %{"default_access" => ["write"]}
          ] do
        conn = session(ctx) |> as() |> patch("/api/connections/pat/#{key.id}", body)
        assert conn.status == 422, "PATCH #{inspect(body)} -> #{conn.status} #{conn.resp_body}"
      end

      assert (raw |> in_vault(ctx.n) |> get("/api/notes/Dir/a.md")).status == 404

      assert (raw
              |> in_vault(ctx.r)
              |> post("/api/notes", %{"path" => "q.md", "content" => "x", "mtime" => 1})).status ==
               403
    end

    test "an API key / OAuth token cannot PATCH its own access", ctx do
      {:ok, raw, key} = Accounts.create_api_key(ctx.user, "k", levels(ctx))
      oauth = credential(ctx, :oauth, levels(ctx))

      body = %{"vault_access" => %{}, "default_access" => "write"}

      # The key reaches RequireSession (403); the OAuth token is refused at
      # Auth for its audience (401). RequireSession's guard for grant tokens
      # is pinned with legacy-audience ones below.
      for {t, status} <- [{raw, 403}, {oauth, 401}] do
        assert (t |> as() |> patch("/api/connections/pat/#{key.id}", body)).status == status
        assert (t |> as() |> post("/api/api-keys", %{"name" => "x"})).status == status
        assert (t |> as() |> post("/api/connections/pat", %{"name" => "x"})).status == status
      end

      assert (raw |> in_vault(ctx.r) |> post("/api/notes", %{"path" => "q.md"})).status == 403
    end

    test "legacy engram_ key cannot be PATCHed into levels", ctx do
      {:ok, _raw, key} = Accounts.create_api_key(ctx.user, "legacy", nil)

      conn =
        session(ctx)
        |> as()
        |> patch("/api/connections/pat/#{key.id}", %{
          "vault_access" => %{},
          "default_access" => "read"
        })

      assert conn.status == 422
    end

    test "a leveled raw key with its prefix stripped/altered does not authenticate", ctx do
      {:ok, raw, _key} = Accounts.create_api_key(ctx.user, "k", levels(ctx))
      "engram_lk_" <> rest = raw

      for forged <- [
            "engram_" <> rest,
            "engram_lk_" <> rest <> "x",
            "engram_" <> "lk_" <> rest <> "="
          ] do
        conn = forged |> in_vault(ctx.n) |> get("/api/notes/Dir/a.md")
        assert conn.status == 401, "forged #{String.slice(forged, 0, 12)} -> #{conn.status}"
      end
    end

    test "PATCH narrowing a key takes effect on the very next request (no stale cache)", ctx do
      {:ok, raw, key} = Accounts.create_api_key(ctx.user, "k", levels(ctx))
      # Warm the cache with a successful write on W.
      assert (raw
              |> in_vault(ctx.w)
              |> post("/api/notes", %{"path" => "w1.md", "content" => "x", "mtime" => 1})).status in [
               200,
               201
             ]

      conn =
        session(ctx)
        |> as()
        |> patch("/api/connections/pat/#{key.id}", %{
          "vault_access" => %{to_string(ctx.w.id) => "read"},
          "default_access" => "none"
        })

      assert conn.status == 200

      assert (raw
              |> in_vault(ctx.w)
              |> post("/api/notes", %{"path" => "w2.md", "content" => "x", "mtime" => 1})).status ==
               403

      assert (raw |> in_vault(ctx.r) |> get("/api/notes/Dir/a.md")).status == 404

      body =
        tool(raw, "write_note", %{"vault_id" => ctx.w.id, "path" => "w3.md", "content" => "x"})

      assert refused_tool?(body)
    end

    test "PATCH narrowing an OAuth grant applies to the already-issued access token and refresh",
         ctx do
      grant = oauth_grant(ctx, levels(ctx), "mcp")
      token = grant["access_token"]

      assert upload(token, ctx.w, "w1.txt").status in [200, 201]

      family = family_of(grant["refresh_token"])

      conn =
        session(ctx)
        |> as()
        |> patch("/api/connections/oauth/#{ctx.client.client_id}?family_id=#{family}", %{
          "vault_access" => %{to_string(ctx.w.id) => "read"},
          "default_access" => "none"
        })

      assert conn.status == 200

      assert upload(token, ctx.w, "w2.txt").status == 403
      refute attachment?(ctx, ctx.w, "w2.txt")

      refreshed =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => grant["refresh_token"],
          "client_id" => ctx.client.client_id
        })
        |> json_response(200)

      fresh = refreshed["access_token"]
      assert upload(fresh, ctx.w, "w3.txt").status == 403
      refute attachment?(ctx, ctx.w, "w3.txt")

      assert refused_tool?(
               tool(fresh, "write_note", %{
                 "vault_id" => ctx.w.id,
                 "path" => "w3.md",
                 "content" => "x"
               })
             )

      # R went from read to none (default none): unreadable. The grant now
      # writes nowhere, so any upload is refused before a vault is resolved.
      read_r = tool(fresh, "get_notes", %{"vault_id" => ctx.r.id, "paths" => ["Dir/a.md"]})
      assert refused_tool?(read_r)
      refute inspect(read_r) =~ "secret in Readable"
      assert json_response(upload(fresh, ctx.r), 403) == %{"error" => "read_only_grant"}
    end

    test "refresh with a wider scope param does not widen mcp:read", ctx do
      grant = oauth_grant(ctx, {%{to_string(ctx.r.id) => "read"}, "none"}, "mcp:read")

      resp =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => grant["refresh_token"],
          "client_id" => ctx.client.client_id,
          "scope" => "mcp"
        })

      assert resp.status in [200, 400]

      if resp.status == 200 do
        t = json_response(resp, 200)["access_token"]

        body =
          tool(t, "write_note", %{"vault_id" => ctx.r.id, "path" => "q.md", "content" => "x"})

        assert refused_tool?(body)
        assert upload(t, ctx.r).status == 403
        refute attachment?(ctx, ctx.r)
      end
    end

    test "PATCH another user's grant family id is a 404, not an edit", ctx do
      other = insert(:user)
      {:ok, other} = Engram.Crypto.ensure_user_dek(other)
      other = ensure_external_id(other)
      {:ok, ov, _} = Vaults.register_vault(other, "Theirs", Ecto.UUID.generate())
      octx = %{ctx | user: other, w: ov, r: ov, n: ov}
      ogrant = oauth_grant(octx, {%{to_string(ov.id) => "read"}, "none"}, "mcp")
      family = family_of(ogrant["refresh_token"])

      conn =
        session(ctx)
        |> as()
        |> patch("/api/connections/oauth/#{ctx.client.client_id}?family_id=#{family}", %{
          "vault_access" => %{to_string(ctx.w.id) => "write"},
          "default_access" => "write"
        })

      assert conn.status in [404, 422]

      # Still read-only: the edit never landed. With no writable vault the
      # account-level gate answers, before any vault is resolved.
      assert json_response(upload(ogrant["access_token"], ov), 403) == %{
               "error" => "read_only_grant"
             }
    end

    # MCP has no vault-creating tool, so REST is the only way in: a key is
    # refused by its level (403), an OAuth token by its audience (401).
    test "a read-default credential cannot create a vault (MCP or REST) and then write it", ctx do
      vault_ids = fn -> ctx.user |> Vaults.list_vaults() |> Enum.map(& &1.id) |> Enum.sort() end
      before = vault_ids.()

      for {kind, status} <- [{:api_key, 403}, {:oauth, 401}] do
        token = credential(ctx, kind, levels(ctx, "read"))

        conn =
          token
          |> as()
          |> post("/api/vaults/register", %{
            "name" => "New#{kind}",
            "client_id" => Ecto.UUID.generate()
          })

        assert conn.status == status
      end

      assert vault_ids.() == before
    end
  end

  # ── credential management is session-only ─────────────────────────────────

  # An OAuth token as minted is refused at Auth for its audience (#1997)
  # before RequireSession runs; the same grant under the legacy `aud` (a
  # token minted before #1997) reaches RequireSession, which must refuse it
  # too. Both are pinned, so either guard alone holds the line.
  describe "RequireSession refuses every OAuth grant token" do
    # A grant row may hold a NULL scope (the column is nullable; rows from
    # before scopes existed). Its access token then carries no `scope` claim,
    # only `gid`, so a guard keyed on the scope claim alone lets it through.
    test "a token minted from a NULL-scope grant row cannot manage credentials", ctx do
      grant = oauth_grant(ctx, levels(ctx), "mcp")
      family = family_of(grant["refresh_token"])

      Repo.update_all(
        from(t in Engram.OAuth.RefreshToken, where: t.family_id == ^family),
        [set: [scope: nil]],
        skip_tenant_check: true
      )

      Engram.Cache.evict(:oauth_grant, family)

      refreshed =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => grant["refresh_token"],
          "client_id" => ctx.client.client_id
        })
        |> json_response(200)

      token = refreshed["access_token"]
      {:ok, claims} = Accounts.grant_claims(token)
      refute Map.has_key?(claims, "scope")
      assert claims["gid"] == family

      assert_session_only(ctx, token, family, {401, ["unauthorized"]})
      legacy = legacy_audience(ctx.user, token)
      assert_session_only(ctx, legacy, family)

      # The grant is still at its original reach: nothing widened it.
      assert (legacy |> in_vault(ctx.r) |> post("/api/notes", %{"path" => "q.md"})).status == 403
      assert upload(token, ctx.r).status == 403
      refute attachment?(ctx, ctx.r)
    end

    for scope <- ["mcp", "mcp:read"] do
      @scope scope
      test "an ordinary #{scope} token cannot PATCH either connection route", ctx do
        grant =
          oauth_grant(
            ctx,
            if(@scope == "mcp", do: levels(ctx), else: {%{to_string(ctx.r.id) => "read"}, "none"}),
            @scope
          )

        # An mcp:read token is refused writes one plug earlier, by
        # OAuthScopeEnforce (read_only_grant); either refusal is the guard.
        refusals =
          if @scope == "mcp:read",
            do: ["oauth_grant_not_allowed", "read_only_grant"],
            else: ["oauth_grant_not_allowed"]

        token = grant["access_token"]
        family = family_of(grant["refresh_token"])

        assert_session_only(ctx, token, family, {401, ["unauthorized"]})
        assert_session_only(ctx, legacy_audience(ctx.user, token), family, {403, refusals})
      end
    end
  end

  # Every credential-management route answers `status` with an error in
  # `refusals`, and changes nothing: the grant's own family, a key, the
  # user's connections.
  defp assert_session_only(ctx, token, family, expect \\ {403, ["oauth_grant_not_allowed"]}) do
    {status, refusals} = expect
    {:ok, _raw, key} = Accounts.create_api_key(ctx.user, "victim", levels(ctx))
    widen = %{"vault_access" => %{}, "default_access" => "write"}
    oauth_path = "/api/connections/oauth/#{ctx.client.client_id}"

    for {method, path, body} <- [
          {:patch, "#{oauth_path}?family_id=#{family}", widen},
          {:patch, "/api/connections/pat/#{key.id}", widen},
          {:post, "/api/api-keys", %{"name" => "escalated"}},
          {:post, "/api/connections/pat", %{"name" => "escalated"}},
          {:get, "/api/api-keys", nil},
          {:get, "/api/connections", nil},
          {:delete, "/api/api-keys/#{key.id}", nil},
          {:delete, "/api/connections/pat/#{key.id}", nil},
          {:delete, "#{oauth_path}?family_id=#{family}", nil},
          {:delete, "/api/connections/device/#{Ecto.UUID.generate()}", nil}
        ] do
      conn = token |> as() |> mgmt(method, path, body)
      msg = "#{method} #{path} -> #{conn.status} #{conn.resp_body}"
      assert conn.status == status, msg
      assert Jason.decode!(conn.resp_body)["error"] in refusals, msg
    end

    keys = Repo.all(from(k in Engram.Accounts.ApiKey, select: k.name), skip_tenant_check: true)
    assert keys == ["victim"]

    Repo.delete_all(from(k in Engram.Accounts.ApiKey, where: k.id == ^key.id),
      skip_tenant_check: true
    )

    assert Repo.one(
             from(t in Engram.OAuth.RefreshToken,
               where: t.family_id == ^family and is_nil(t.revoked_at),
               select: count()
             ),
             skip_tenant_check: true
           ) > 0

    refute Repo.exists?(
             from(t in Engram.OAuth.RefreshToken,
               where: t.family_id == ^family and t.default_access == "write"
             ),
             skip_tenant_check: true
           )
  end

  # ── lifecycle ──────────────────────────────────────────────────────────────

  describe "lifecycle" do
    test "a vault created later is reachable only at the default level", ctx do
      for {default, can_read?, can_write?} <- [{"none", false, false}, {"read", true, false}] do
        {:ok, raw, _} = Accounts.create_api_key(ctx.user, "k", levels(ctx, default))
        {:ok, later, _} = Vaults.register_vault(ctx.user, "Later#{default}", Ecto.UUID.generate())

        {:ok, _} =
          Engram.Notes.upsert_note(
            ctx.user,
            later,
            %{"path" => "l.md", "content" => "later", "mtime" => 1.0},
            actor: "api"
          )

        r = raw |> in_vault(later) |> get("/api/notes/l.md")
        assert r.status == 200 == can_read?, "default #{default} read -> #{r.status}"

        w =
          raw
          |> in_vault(later)
          |> post("/api/notes", %{"path" => "m.md", "content" => "x", "mtime" => 1})

        assert w.status in [200, 201] == can_write?, "default #{default} write -> #{w.status}"
      end
    end

    test "purging every listed vault of a leveled key (policy none) never makes it unrestricted",
         ctx do
      {:ok, raw, _} =
        Accounts.create_api_key(ctx.user, "k", {%{to_string(ctx.w.id) => "write"}, "none"})

      {:ok, _} = Vaults.delete_vault(ctx.user, ctx.w.id)
      :ok = run_cleanup(ctx.w)

      conn = raw |> in_vault(ctx.n) |> get("/api/notes/Dir/a.md")
      assert conn.status in [401, 404], "after purge got #{conn.status}"
      refute conn.resp_body =~ "secret"
    end

    test "purging every listed vault of a legacy key never makes it unrestricted", ctx do
      {:ok, raw, key} = Accounts.create_api_key(ctx.user, "legacy", nil)

      Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(key.id), vault_id: Ecto.UUID.dump!(ctx.w.id)}
      ])

      Engram.Cache.evict(:api_key, key.key_hash)
      assert (raw |> in_vault(ctx.n) |> get("/api/notes/Dir/a.md")).status == 404

      {:ok, _} = Vaults.delete_vault(ctx.user, ctx.w.id)
      :ok = run_cleanup(ctx.w)

      conn = raw |> in_vault(ctx.n) |> get("/api/notes/Dir/a.md")
      assert conn.status in [401, 404], "after purge got #{conn.status}"
    end

    test "a leveled key listing a vault at write keeps no reach after that vault's purge + recreate",
         ctx do
      {:ok, raw, _} =
        Accounts.create_api_key(
          ctx.user,
          "k",
          {%{to_string(ctx.w.id) => "write", to_string(ctx.r.id) => "read"}, "none"}
        )

      {:ok, _} = Vaults.delete_vault(ctx.user, ctx.w.id)
      :ok = run_cleanup(ctx.w)
      {:ok, fresh, _} = Vaults.register_vault(ctx.user, "Fresh", Ecto.UUID.generate())

      w =
        raw
        |> in_vault(fresh)
        |> post("/api/notes", %{"path" => "m.md", "content" => "x", "mtime" => 1})

      assert w.status == 403
    end
  end

  defp run_cleanup(vault) do
    case Engram.Workers.CleanupVault.perform(%Oban.Job{
           args: %{"vault_id" => vault.id, "user_id" => vault.user_id, "force" => true}
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> flunk("cleanup returned #{inspect(other)}")
    end
  end

  defp family_of(raw_refresh) do
    hash = Engram.Crypto.sha256_hex(raw_refresh)

    Repo.one(
      from(t in Engram.OAuth.RefreshToken, where: t.token_hash == ^hash, select: t.family_id),
      skip_tenant_check: true
    ) || flunk("no refresh row")
  end
end
