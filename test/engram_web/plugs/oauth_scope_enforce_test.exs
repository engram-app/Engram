defmodule EngramWeb.Plugs.OAuthScopeEnforceTest do
  @moduledoc """
  `OAuthScopeEnforce` must never resolve to MORE access than the request's
  credential holds:

    * a grant token that `Plugs.Auth` accepted cannot read as unrestricted
      here because its `exp` second ticked over in between (the plug used to
      re-verify with expiry and fall through to "no claims" = every vault);
    * the account-level read-only block treats a read-only API key exactly
      like an `mcp:read` grant (both have no writable vault anywhere).
  """
  use EngramWeb.ConnCase, async: true

  alias Engram.{Accounts, Permissions}
  alias EngramWeb.Plugs.OAuthScopeEnforce

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "api_rps_cap", value: %{"v" => 100})
    insert(:user_limit_override, user: user, key: "api_write_enabled", value: %{"v" => true})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    user = ensure_external_id(user)
    granted = insert(:vault, user: user, is_default: true)
    other = insert(:vault, user: user)
    %{user: user, granted: granted, other: other}
  end

  defp run_plug(token, assigns) do
    conn =
      build_conn(:get, "/api/folders")
      |> put_req_header("authorization", "Bearer #{token}")

    conn = Enum.reduce(assigns, conn, fn {k, v}, c -> Plug.Conn.assign(c, k, v) end)
    OAuthScopeEnforce.call(conn, [])
  end

  describe "a grant token that expires between Auth and this plug" do
    test "keeps the grant's vault scope; it does not read as unrestricted", ctx do
      expired =
        Accounts.generate_jwt(ctx.user, %{
          "scope" => "mcp",
          "vault_ids" => [ctx.granted.id],
          "exp" => System.system_time(:second) - 1
        })

      # Auth accepted it a moment ago; the clock has since passed `exp`.
      assert {:error, _} = Accounts.verify_jwt(expired)

      conn = run_plug(expired, current_auth_method: :internal_jwt)

      refute conn.halted
      scope = Permissions.vault_scope(conn)
      assert Permissions.allows?(scope, ctx.granted)
      refute Permissions.allows?(scope, ctx.other)
    end

    test "an internal-JWT request whose claims cannot be read at all is refused", ctx do
      # Belt and braces: Auth said this was one of our tokens, so failing to
      # read its claims must not mean "no restriction".
      conn = run_plug("not-a-jwt", current_auth_method: :internal_jwt, current_user: ctx.user)

      assert conn.halted
      assert conn.status == 401
    end

    test "a token that is not ours (Clerk, API key) still means no grant", ctx do
      conn = run_plug("not-a-jwt", current_user: ctx.user)

      refute conn.halted
      assert Permissions.vault_scope(conn) == :all
    end
  end

  test "a forged signature never yields claims" do
    [h, p, _sig] = String.split(Accounts.generate_jwt(insert(:user), %{}), ".")
    assert :error = Accounts.grant_claims(Enum.join([h, p, "AAAA"], "."))
  end

  # ── account-level read-only block (unified across credential kinds) ──

  defp read_only_key(ctx) do
    {:ok, raw, _} = Accounts.create_api_key(ctx.user, "ro", {%{}, "read"})
    raw
  end

  defp write_key(ctx) do
    {:ok, raw, _} = Accounts.create_api_key(ctx.user, "rw", {%{}, "write"})
    raw
  end

  defp mcp_read_grant(ctx) do
    Accounts.generate_jwt(ctx.user, %{"scope" => "mcp:read"})
  end

  defp as(token), do: put_req_header(build_conn(), "authorization", "Bearer #{token}")

  for {kind, fun} <- [api_key: :read_only_key, oauth: :mcp_read_grant] do
    describe "a #{kind} credential that can write no vault" do
      test "is refused PATCH /api/me", ctx do
        conn = ctx |> unquote(fun)() |> as() |> patch("/api/me", %{"name" => "x"})
        assert json_response(conn, 403)["error"] == "read_only_grant"
      end

      test "is refused POST /api/onboarding/actions", ctx do
        conn =
          ctx |> unquote(fun)() |> as() |> post("/api/onboarding/actions", %{"action" => "x"})

        assert json_response(conn, 403)["error"] == "read_only_grant"
      end

      # These write no vault data, like the MCP `send_feedback` tool the same
      # credential may call (`Tools.writes_vault?/1`): the two gates agree.
      test "may still POST /api/telemetry/spans", ctx do
        conn = ctx |> unquote(fun)() |> as() |> post("/api/telemetry/spans", %{"spans" => []})
        refute conn.status == 403, conn.resp_body
      end

      test "may still POST /api/feedback", ctx do
        conn =
          ctx
          |> unquote(fun)()
          |> as()
          |> post("/api/feedback", %{"kind" => "general", "message" => "hi"})

        # RequireSession still refuses an OAuth grant here; not as read-only.
        refute conn.resp_body =~ "read_only_grant"
      end

      test "may still POST /api/logs", ctx do
        conn =
          ctx
          |> unquote(fun)()
          |> as()
          |> put_req_header("x-vault-id", ctx.granted.id)
          |> post("/api/logs", %{"logs" => [%{"level" => "info", "message" => "m"}]})

        refute conn.status == 403, conn.resp_body
      end

      test "is refused POST /api/vaults/register", ctx do
        conn =
          ctx
          |> unquote(fun)()
          |> as()
          |> post("/api/vaults/register", %{"name" => "N", "client_id" => Ecto.UUID.generate()})

        assert json_response(conn, 403)["error"] == "read_only_grant"
      end

      test "may still search (a POST that only reads)", ctx do
        Mox.stub(Engram.MockEmbedder, :embed_texts, fn _, _ -> {:error, :offline} end)

        conn =
          ctx
          |> unquote(fun)()
          |> as()
          |> put_req_header("x-vault-id", ctx.granted.id)
          |> post("/api/search", %{"query" => "x"})

        refute conn.status == 403
      end

      test "may still price a plan change (a POST that only reads)", ctx do
        conn =
          ctx |> unquote(fun)() |> as() |> post("/api/billing/plan-change/preview", %{})

        refute conn.status == 403 and conn.resp_body =~ "read_only_grant"
      end

      test "may still GET /api/me", ctx do
        assert ctx |> unquote(fun)() |> as() |> get("/api/me") |> json_response(200)
      end
    end
  end

  # Only the POST is exempt: any other method on those paths is a write.
  test "ReadOnlyRoutes exempts only POST on the read-only and no-vault-data paths" do
    for path <- [
          ~w(api feedback),
          ~w(api logs),
          ~w(api telemetry spans),
          ~w(api mcp),
          ~w(api search)
        ] do
      refute EngramWeb.ReadOnlyRoutes.writes?(%Plug.Conn{method: "POST", path_info: path})

      for method <- ~w(PUT PATCH DELETE) do
        assert EngramWeb.ReadOnlyRoutes.writes?(%Plug.Conn{method: method, path_info: path}),
               "#{method} /#{Enum.join(path, "/")}"
      end
    end
  end

  test "an API key that can write some vault is not blocked account-wide", ctx do
    conn = ctx |> write_key() |> as() |> patch("/api/me", %{"name" => "x"})
    refute conn.status == 403
  end

  # A listed write level on a vault that no longer exists writes nothing: it
  # must not keep the account-level writable gate open.
  test "a grant whose only write vault is soft-deleted is blocked account-wide", ctx do
    gone = insert(:vault, user: ctx.user, deleted_at: DateTime.utc_now(:second))

    token =
      Accounts.generate_jwt(ctx.user, %{
        "scope" => "mcp",
        "vault_ids" => [gone.id],
        "vault_access" => %{gone.id => "write", ctx.granted.id => "read"},
        "default_access" => "none"
      })

    conn = token |> as() |> patch("/api/me", %{"name" => "x"})
    assert json_response(conn, 403)["error"] == "read_only_grant"
  end

  # `vaults` queries THIS process runs inside `fun` (the file is async).
  defp vault_queries(fun) do
    me = self()
    {_, queries} = Engram.QueryRecorder.record(fun)
    Enum.count(queries, &(&1.pid == me and &1.source == "vaults"))
  end

  # An unrestricted credential writes everywhere: nothing to compute, so a
  # write never reads the vault list (cold here, as after its TTL).
  describe "an unrestricted credential" do
    test "writes without reading the vault list", ctx do
      Engram.Cache.evict_local(:vaults, ctx.user.id)

      conn =
        build_conn(:post, "/api/notes")
        |> Plug.Conn.assign(:current_user, ctx.user)
        |> Plug.Conn.assign(:grant_claims, :error)

      n = vault_queries(fn -> refute OAuthScopeEnforce.call(conn, []).halted end)

      assert Permissions.vault_scope(conn) == :all
      assert n == 0
    end
  end
end
