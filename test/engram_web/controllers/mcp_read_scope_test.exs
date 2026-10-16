defmodule EngramWeb.McpReadScopeTest do
  @moduledoc """
  The `mcp:read` OAuth scope (#174, first slice): a grant the user (or the
  client) narrowed to read-only. Every token here comes out of the real
  consent -> /oauth/token chain, so the scope under test is the one the server
  actually mints, not a hand-built claim.
  """
  use EngramWeb.ConnCase, async: true

  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Engram.MCP.Tools
  alias Engram.OAuth

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    user = ensure_external_id(user)
    vault = insert(:vault, user: user, is_default: true)

    {:ok, _} =
      Engram.Notes.upsert_note(
        user,
        vault,
        %{"path" => "a.md", "content" => "hello", "mtime" => 1.0},
        actor: "api"
      )

    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://muse.example/callback"],
        "client_name" => "Muse"
      })

    %{user: user, vault: vault, client: client}
  end

  defp session(conn, user) do
    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # Runs consent as the user, then exchanges the code. Returns the token body.
  defp grant(user, client, scope, consent_extras \\ %{}) do
    {verifier, challenge} = pkce_pair()
    redirect_uri = hd(client.redirect_uris)

    params =
      Map.merge(
        %{
          "client_id" => client.client_id,
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "state" => "s",
          "scope" => scope
        },
        consent_extras
      )
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    consent = build_conn() |> session(user) |> post("/api/oauth/authorize/consent", params)
    code = consent |> json_response(200) |> Map.fetch!("redirect_uri") |> code_from_redirect()

    build_conn()
    |> post("/oauth/token", %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => client.client_id,
      "code_verifier" => verifier
    })
    |> json_response(200)
  end

  defp bearer(conn, %{"access_token" => token}),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp tool_names(conn) do
    conn
    |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    |> json_response(200)
    |> get_in(["result", "tools"])
    |> Enum.map(& &1["name"])
  end

  defp full_names, do: Enum.map(Tools.list(), & &1.name)

  describe "issuance" do
    test "a client asking for mcp:read gets a token scoped mcp:read", %{user: u, client: c} do
      assert grant(u, c, "mcp:read")["scope"] == "mcp:read"
    end

    test "consent read_only downgrades a client that asked for mcp", %{user: u, client: c} do
      assert grant(u, c, "mcp", %{"read_only" => true})["scope"] == "mcp:read"
    end

    test "a client asking for mcp:read is not upgraded by read_only=false", %{
      user: u,
      client: c
    } do
      assert grant(u, c, "mcp:read", %{"read_only" => false})["scope"] == "mcp:read"
    end

    test "asking for both scopes is their union: full mcp", %{user: u, client: c} do
      refute grant(u, c, "mcp mcp:read")["scope"] == "mcp:read"
    end

    test "absent scope still defaults to full mcp", %{user: u, client: c} do
      assert grant(u, c, nil)["scope"] == "mcp"
    end

    test "refresh keeps mcp:read and never widens it", %{user: u, client: c} do
      first = grant(u, c, "mcp", %{"read_only" => true})

      refreshed =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => first["refresh_token"],
          "client_id" => c.client_id
        })
        |> json_response(200)

      assert refreshed["scope"] == "mcp:read"

      refute build_conn()
             |> bearer(refreshed)
             |> tool_names()
             |> Enum.any?(&Tools.writes_vault?/1)
    end
  end

  describe "MCP enforcement" do
    # Every tool that writes vault data is hidden; send_feedback writes
    # none (it reaches the Engram team), so it stays.
    test "tools/list under mcp:read lists no tool that writes vault data", %{user: u, client: c} do
      names = build_conn() |> bearer(grant(u, c, "mcp:read")) |> tool_names()

      assert "search_notes" in names
      assert "send_feedback" in names
      refute "write_note" in names
      assert names == Enum.reject(full_names(), &Tools.writes_vault?/1)
    end

    test "tools/list under mcp lists every tool", %{user: u, client: c} do
      assert build_conn() |> bearer(grant(u, c, "mcp")) |> tool_names() == full_names()
    end

    test "tools/list with a token that carries no scope lists every tool", %{user: u} do
      conn =
        put_req_header(build_conn(), "authorization", "Bearer #{Engram.Accounts.generate_jwt(u)}")

      assert tool_names(conn) == full_names()
    end

    test "calling a write tool under mcp:read is refused and writes nothing", %{
      user: u,
      vault: v,
      client: c
    } do
      body =
        build_conn()
        |> bearer(grant(u, c, "mcp:read"))
        |> call_tool("write_note", %{"path" => "new.md", "content" => "x"})
        |> json_response(200)

      assert body["error"]["message"] =~ "read-only"
      assert {:error, :not_found} = Engram.Notes.get_note(u, v, "new.md")
    end

    # It hands out where (and with which credential) to UPLOAD: a write.
    test "get_attachment_upload_target is neither listed nor callable under mcp:read", %{
      user: u,
      client: c
    } do
      token = grant(u, c, "mcp:read")
      refute "get_attachment_upload_target" in (build_conn() |> bearer(token) |> tool_names())

      body =
        build_conn()
        |> bearer(token)
        |> call_tool("get_attachment_upload_target", %{})
        |> json_response(200)

      assert body["error"]["message"] =~ "read-only"
    end

    # send_feedback is not read-only (it sends something), but it changes no
    # note and no vault: it reaches the Engram team. A read-only grant still
    # may tell us something is wrong.
    test "send_feedback, which writes no vault data, works under mcp:read", %{user: u, client: c} do
      body =
        build_conn()
        |> bearer(grant(u, c, "mcp:read"))
        |> call_tool("send_feedback", %{"message" => "hello", "initiated_by" => "user"})
        |> json_response(200)

      # Reached the tool: no JSON-RPC refusal from an access gate. (Whether
      # feedback is then collected depends on the install, not on access.)
      refute body["error"]
      assert %{"content" => [_ | _]} = body["result"]
    end

    test "a read tool under mcp:read still works", %{user: u, client: c} do
      conn =
        build_conn()
        |> bearer(grant(u, c, "mcp:read"))
        |> call_tool("get_notes", %{"paths" => ["a.md"]})

      assert tool_text(conn) =~ "hello"
    end

    test "a write tool under mcp still works", %{user: u, vault: v, client: c} do
      body =
        build_conn()
        |> bearer(grant(u, c, "mcp"))
        |> call_tool("write_note", %{"path" => "new.md", "content" => "x"})
        |> json_response(200)

      refute body["error"]
      assert {:ok, _} = Engram.Notes.get_note(u, v, "new.md")
    end
  end

  # The same access token authenticates the REST API (get_attachment_upload_target
  # tells the model to POST there with it), so read-only must hold there too.
  describe "REST enforcement" do
    test "a write under mcp:read is refused", %{user: u, vault: v, client: c} do
      conn =
        build_conn()
        |> bearer(grant(u, c, "mcp:read"))
        |> put_req_header("x-vault-id", v.id)
        |> post("/api/notes", %{"path" => "rest.md", "content" => "x", "mtime" => 1.0})

      assert json_response(conn, 403)["error"] == "read_only_grant"
      assert {:error, :not_found} = Engram.Notes.get_note(u, v, "rest.md")
    end

    test "a read under mcp:read is allowed", %{user: u, vault: v, client: c} do
      conn =
        build_conn()
        |> bearer(grant(u, c, "mcp:read"))
        |> put_req_header("x-vault-id", v.id)
        |> get("/api/tags")

      assert conn.status == 200
    end
  end

  # `vaults` queries THIS process runs inside `fun` (the file is async).
  defp vault_queries(fun) do
    me = self()
    {_, queries} = Engram.QueryRecorder.record(fun)
    Enum.count(queries, &(&1.pid == me and &1.source == "vaults"))
  end

  # An unrestricted grant writes everywhere: nothing to compute, so listing
  # tools never reads the vault list. The factory vault's name is not
  # encrypted under the user's DEK, so the list never caches (a failed
  # decrypt is not cached) and every reader queries: the one expected is the
  # onboarding gate's (`Vaults.has_vault?/1`); `tools/list` adds none.
  describe "an unrestricted grant" do
    test "lists write tools without reading the vault list", %{user: u, client: c} do
      conn = bearer(build_conn(), grant(u, c, "mcp"))

      n =
        ExUnit.CaptureLog.with_log(fn ->
          vault_queries(fn -> assert "write_note" in tool_names(conn) end)
        end)
        |> elem(0)

      assert n == 1
    end
  end
end
