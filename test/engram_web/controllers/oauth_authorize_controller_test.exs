defmodule EngramWeb.OAuthAuthorizeControllerTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.OAuth
  alias Engram.Repo

  defp jwt_authed(conn, user) do
    user = ensure_external_id(user)
    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # An OAuth-issued access token: the same mint path `/oauth/token` uses, so the
  # `scope` claim `RequireSession` keys on is present exactly as in production.
  defp oauth_authed(conn, user, extras) do
    user = ensure_external_id(user)
    token = Engram.Accounts.generate_jwt(user, extras)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp register_client(redirect_uri \\ "https://claude.ai/api/mcp/auth_callback") do
    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => [redirect_uri],
        "client_name" => "Claude"
      })

    client
  end

  defp valid_params(client_id, redirect_uri) do
    %{
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "code_challenge" => "abc123challenge",
      "code_challenge_method" => "S256",
      "state" => "xyz",
      "scope" => "mcp"
    }
  end

  # ──────────────────────────────────────────────────────────────────
  # GET /oauth/authorize — Phase 7.A: now PUBLIC (browser navigation,
  # no Bearer header on 302). Validates request, then 302s to the SPA
  # at /oauth/consent?<all-params>. Invalid client/redirect still
  # returns 400 HTML (no redirect — code-leak prevention).
  # ──────────────────────────────────────────────────────────────────

  describe "GET /oauth/authorize — happy path (PUBLIC, no auth required)" do
    test "redirects to /oauth/consent with all params preserved", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      params = valid_params(client.client_id, redirect_uri)

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")

      uri = URI.parse(location)
      assert uri.path == "/oauth/consent"

      query = URI.decode_query(uri.query)
      assert query["client_id"] == client.client_id
      assert query["redirect_uri"] == redirect_uri
      assert query["response_type"] == "code"
      assert query["code_challenge"] == "abc123challenge"
      assert query["code_challenge_method"] == "S256"
      assert query["state"] == "xyz"
      assert query["scope"] == "mcp"
    end

    test "preserves resource param (RFC 8707) pass-through", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("resource", "https://app.engram.page/api/mcp")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      query = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert query["resource"] == "https://app.engram.page/api/mcp"
    end

    test "does NOT require Authorization: Bearer header", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      params = valid_params(client.client_id, redirect_uri)

      conn = get(conn, "/oauth/authorize", params)

      refute conn.status == 401
      assert conn.status == 302
    end
  end

  describe "GET /oauth/authorize — invalid client" do
    test "returns 400 HTML when client_id is unknown", %{conn: conn} do
      params = valid_params("00000000-0000-0000-0000-000000000000", "https://x/cb")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 400
      assert conn.resp_body =~ "invalid_client"
    end

    # This route answers text/html, not JSON, so it needs the browser headers
    # the :api pipelines legitimately skip. It had NONE — the OAuth entry point
    # served framable, sniffable, full-Referer documents. `state` is in the
    # query string of that page, which is why referrer-policy belongs here too.
    test "the HTML error page carries browser security headers", %{conn: conn} do
      params = valid_params("00000000-0000-0000-0000-000000000000", "https://x/cb")

      conn = get(conn, "/oauth/authorize", params)

      assert ["text/html" <> _] = get_resp_header(conn, "content-type")
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "referrer-policy") == ["origin"]

      # x-frame-options is asserted, but it is NOT what stops framing here.
      # put_secure_browser_headers always emits a CSP (put_secure_defaults runs
      # first and the map merges over it), and CSP Level 2 §7.4.1 makes
      # `frame-ancestors` supersede `x-frame-options` wherever both are
      # understood. Phoenix's default is `frame-ancestors 'self'` — so asserting
      # DENY alone passed while every modern browser allowed same-origin
      # framing of the OAuth entry point.
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'none'"
      assert csp =~ "default-src 'none'"
    end

    test "returns 400 HTML when redirect_uri does not match registration", %{conn: conn} do
      client = register_client("https://claude.ai/api/mcp/auth_callback")

      params = valid_params(client.client_id, "https://attacker.example/cb")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 400
      assert conn.resp_body =~ "invalid_redirect_uri"
    end
  end

  # RFC 8252 §7.3: "the authorization server MUST allow any port to be specified
  # at the time of the request for loopback IP redirect URIs, to accommodate
  # clients that obtain an available ephemeral port from the operating system at
  # the time of the request."
  #
  # This is not academic. A DCR client registers once and persists its
  # client_id, but grabs a NEW ephemeral port on every launch. Under exact
  # matching, every local-first connector (Claude Code, Cline, OpenCode, Cursor,
  # Windsurf) breaks on its second run and can only recover by re-registering.
  describe "GET /oauth/authorize — loopback ephemeral ports (RFC 8252 §7.3)" do
    test "accepts a different port than the one registered", %{conn: conn} do
      client = register_client("http://127.0.0.1:1456/mcp/oauth/callback")

      params = valid_params(client.client_id, "http://127.0.0.1:49152/mcp/oauth/callback")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 302
    end

    test "accepts an added port when none was registered", %{conn: conn} do
      client = register_client("http://localhost/callback")

      params = valid_params(client.client_id, "http://localhost:8912/callback")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 302
    end

    test "still requires the path to match", %{conn: conn} do
      client = register_client("http://127.0.0.1:1456/mcp/oauth/callback")

      params = valid_params(client.client_id, "http://127.0.0.1:1456/steal")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 400
      assert conn.resp_body =~ "invalid_redirect_uri"
    end

    test "still requires the loopback host to match", %{conn: conn} do
      client = register_client("http://127.0.0.1:1456/mcp/oauth/callback")

      params = valid_params(client.client_id, "http://localhost:1456/mcp/oauth/callback")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 400
      assert conn.resp_body =~ "invalid_redirect_uri"
    end

    # The port exemption is scoped to loopback. Relaxing it for https would let
    # anyone who controls any port on a registered host collect auth codes.
    test "does not relax the port for a non-loopback https redirect", %{conn: conn} do
      client = register_client("https://claude.ai/api/mcp/auth_callback")

      params = valid_params(client.client_id, "https://claude.ai:8443/api/mcp/auth_callback")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 400
      assert conn.resp_body =~ "invalid_redirect_uri"
    end
  end

  describe "GET /oauth/authorize — bad params (redirect with error)" do
    test "redirects to redirect_uri?error=unsupported_response_type when not code", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("response_type", "token")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, redirect_uri)
      assert location =~ "error=unsupported_response_type"
      assert location =~ "state=xyz"
    end

    test "redirects with invalid_request when code_challenge missing", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.delete("code_challenge")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "error=invalid_request"
    end

    test "redirects with invalid_request when code_challenge_method is plain", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("code_challenge_method", "plain")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "error=invalid_request"
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # POST /api/oauth/authorize/consent — Phase 7.A: SPA submits this
  # with the user's Bearer JWT after the consent UI is approved.
  # Returns JSON {redirect_uri: "..."} so the SPA can window.location.
  # ──────────────────────────────────────────────────────────────────

  describe "POST /api/oauth/authorize/consent — auth required" do
    test "returns 401 when no Authorization header is present", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:*")

      conn = post(conn, "/api/oauth/authorize/consent", params)
      assert conn.status == 401
    end
  end

  describe "POST /api/oauth/authorize/consent — session only" do
    # Consent MINTS an authorization code for whatever `client_id` and vaults
    # the caller names, and ownership is checked against the USER, not against
    # the calling credential. `/oauth/register` is public DCR, so off
    # `RequireSession` a third-party app registers its own client, self-consents
    # with the grant it already holds, and exchanges for an all-vaults token —
    # a grant on vault A minting one covering A and B, with no user in the loop.
    test "a vault-scoped grant cannot self-consent", %{conn: conn} do
      user = insert(:user)
      vault_a = insert(:vault, user: user)
      vault_b = insert(:vault, user: user)
      client = register_client()

      params =
        client.client_id
        |> valid_params(hd(client.redirect_uris))
        |> Map.put("vault_choice", "vault:#{vault_b.id}")

      conn =
        conn
        |> oauth_authed(user, %{"scope" => "mcp", "vault_ids" => [vault_a.id]})
        |> post("/api/oauth/authorize/consent", params)

      assert %{"error" => "oauth_grant_not_allowed"} = json_response(conn, 403)

      # A 403 that minted the code anyway would be worse than no check.
      assert Repo.aggregate(Engram.OAuth.AuthorizationCode, :count, skip_tenant_check: true) == 0
    end

    test "an UNSCOPED (all-vaults) grant cannot self-consent either", %{conn: conn} do
      user = insert(:user)
      _vault = insert(:vault, user: user)
      client = register_client()

      params =
        client.client_id
        |> valid_params(hd(client.redirect_uris))
        |> Map.put("vault_choice", "vault:*")

      conn =
        conn
        |> oauth_authed(user, %{"scope" => "mcp"})
        |> post("/api/oauth/authorize/consent", params)

      assert %{"error" => "oauth_grant_not_allowed"} = json_response(conn, 403)
    end

    # THE over-block guard. `RequireSession` gates the entire consent flow, so a
    # false positive here means nobody can approve any OAuth client at all —
    # the SPA on SaaS (Clerk) and on self-host (`Local.issue_access_token/2`,
    # which sets no `scope` claim) both land on this route.
    test "a first-party session still reaches consent", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      client = register_client()

      params =
        client.client_id
        |> valid_params(hd(client.redirect_uris))
        |> Map.put("vault_choice", "vault:#{vault.id}")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 200
      assert is_binary(Jason.decode!(conn.resp_body)["redirect_uri"])
    end
  end

  describe "POST /api/oauth/authorize/consent — happy path" do
    test "mints a code and returns JSON redirect_uri with code + state", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:#{vault.id}")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      assert is_binary(json["redirect_uri"])
      assert String.starts_with?(json["redirect_uri"], redirect_uri)

      uri = URI.parse(json["redirect_uri"])
      query = URI.decode_query(uri.query)
      assert query["state"] == "xyz"
      assert is_binary(query["code"]) and byte_size(query["code"]) > 16

      assert {:ok, code_row} = OAuth.get_authorization_code_by_raw(query["code"])
      assert code_row.user_id == user.id
      assert code_row.client_id == client.client_id
      assert code_row.vault_id == vault.id
      assert code_row.scope == "mcp"
    end

    test "mints code with vault_id=nil when vault_choice=vault:*", %{conn: conn} do
      user = insert(:user)
      _vault = insert(:vault, user: user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:*")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      uri = URI.parse(json["redirect_uri"])
      query = URI.decode_query(uri.query)

      assert {:ok, code_row} = OAuth.get_authorization_code_by_raw(query["code"])
      assert is_nil(code_row.vault_id)
    end
  end

  # Prod 500 observed 2026-07-30 connecting Windsurf:
  #   (Postgrex.Error) 22001 value too long for type character varying(255)
  #   at Engram.OAuth.mint_authorization_code/3
  # Two columns on oauth_authorization_codes could overflow. `state` is
  # client-supplied and RFC 6749 puts no bound on it (IDEs pack routing data in
  # there). `redirect_uri` is worse: our own DCR accepts up to 2048 bytes, then
  # we tried to store it in varchar(255) — we accepted a value we could not
  # persist. Both must round-trip, not crash.
  describe "POST /api/oauth/authorize/consent — oversized fields (Windsurf 500)" do
    test "mints a code when state exceeds 255 characters", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      long_state = String.duplicate("s", 900)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("state", long_state)
        |> Map.put("vault_choice", "vault:#{vault.id}")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      query = json["redirect_uri"] |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert query["state"] == long_state
    end

    test "mints a code when the registered redirect_uri exceeds 255 characters", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      # Comfortably over 255, comfortably under the 2048 DCR accepts.
      redirect_uri = "https://windsurf.example.com/cb?p=" <> String.duplicate("q", 400)
      client = register_client(redirect_uri)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:#{vault.id}")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      assert String.starts_with?(json["redirect_uri"], redirect_uri)
    end

    # Widening the column must not make it unbounded storage: the endpoint is
    # reachable by any signed-in user, and a code row lives 10 minutes.
    test "rejects an absurd state instead of persisting it", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      client = register_client()

      params =
        client.client_id
        |> valid_params(hd(client.redirect_uris))
        |> Map.put("state", String.duplicate("s", 5000))
        |> Map.put("vault_choice", "vault:#{vault.id}")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 400
    end
  end

  describe "POST /api/oauth/authorize/consent — vault ownership" do
    test "returns 200 with redirect_uri carrying ?error=access_denied when vault not owned",
         %{conn: conn} do
      user = insert(:user)
      other = insert(:user)
      other_vault = insert(:vault, user: other)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:#{other_vault.id}")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      assert String.starts_with?(json["redirect_uri"], redirect_uri)
      assert json["redirect_uri"] =~ "error=access_denied"
      assert json["redirect_uri"] =~ "state=xyz"
    end
  end

  describe "POST /api/oauth/authorize/consent — vault_ids (multi-vault grants)" do
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

      query =
        conn.resp_body
        |> Jason.decode!()
        |> Map.fetch!("redirect_uri")
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert {:ok, code_row} = OAuth.get_authorization_code_by_raw(query["code"])
      assert Enum.sort(code_row.vault_ids) == Enum.sort([a.id, b.id])
      # >1 vault: the legacy scalar carries the FIRST granted id, never NULL.
      # NULL reads as "all vaults" to a rolled-back release, which would hand
      # the client vault c — the one the user declined. Writing an id narrows
      # instead. `resolve_vaults/2` sorts, so "first" is the lowest id.
      assert code_row.vault_id == hd(Enum.sort([a.id, b.id]))
    end

    test "single-vault grant dual-writes the scalar vault_id", %{conn: conn} do
      user = insert(:user)
      a = insert(:vault, user: user, slug: "solo")
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id |> valid_params(redirect_uri) |> Map.put("vault_ids", [a.id])

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      query =
        conn.resp_body
        |> Jason.decode!()
        |> Map.fetch!("redirect_uri")
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

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
               skip_tenant_check: true
             ) == 0
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

      query =
        conn.resp_body
        |> Jason.decode!()
        |> Map.fetch!("redirect_uri")
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert {:ok, code_row} = OAuth.get_authorization_code_by_raw(query["code"])
      assert code_row.vault_ids == [a.id]
    end
  end

  describe "POST /api/oauth/authorize/consent — connection label" do
    test "a supplied label is stored on the grant", %{conn: conn} do
      user = insert(:user)
      _vault = insert(:vault, user: user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("label", "  Laptop — work vault  ")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      query =
        conn.resp_body
        |> Jason.decode!()
        |> Map.fetch!("redirect_uri")
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert {:ok, code_row} = OAuth.get_authorization_code_by_raw(query["code"])
      assert code_row.label == "Laptop — work vault"
    end

    test "a blank label stores nil rather than an empty string", %{conn: conn} do
      user = insert(:user)
      _vault = insert(:vault, user: user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params = client.client_id |> valid_params(redirect_uri) |> Map.put("label", "   ")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      query =
        conn.resp_body
        |> Jason.decode!()
        |> Map.fetch!("redirect_uri")
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert {:ok, code_row} = OAuth.get_authorization_code_by_raw(query["code"])
      assert is_nil(code_row.label)
    end

    # Rejected, not truncated: storing something other than what the user typed
    # and then showing it back to them is worse than refusing the grant.
    test "an over-long label is rejected rather than truncated", %{conn: conn} do
      user = insert(:user)
      _vault = insert(:vault, user: user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("label", String.duplicate("x", 200))

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      uri = conn.resp_body |> Jason.decode!() |> Map.fetch!("redirect_uri")
      assert uri =~ "error=access_denied"
    end

    # A grapheme bound is not a size bound. This label is ONE grapheme, so it
    # sails past the 120-char check, but the combining-mark stack makes it
    # kilobytes — and the value is re-copied into a new row on every rotation.
    # Only the byte ceiling catches it.
    test "a one-grapheme label that is kilobytes of combining marks is rejected", %{conn: conn} do
      user = insert(:user)
      _vault = insert(:vault, user: user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      zalgo = "e" <> String.duplicate(<<0x0301::utf8>>, 2500)
      assert String.length(zalgo) == 1
      assert byte_size(zalgo) > 4096, "the fixture must exceed the byte ceiling to exercise it"

      params = client.client_id |> valid_params(redirect_uri) |> Map.put("label", zalgo)

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      uri = conn.resp_body |> Jason.decode!() |> Map.fetch!("redirect_uri")
      assert uri =~ "error=access_denied"
    end

    test "the label survives the code -> refresh-token exchange", %{conn: conn} do
      user = insert(:user)
      _vault = insert(:vault, user: user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      verifier = "s3cret-code-verifier-value"
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("code_challenge", challenge)
        |> Map.put("label", "My laptop")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      query =
        conn.resp_body
        |> Jason.decode!()
        |> Map.fetch!("redirect_uri")
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert {:ok, _} =
               OAuth.exchange_authorization_code(%{
                 "code" => query["code"],
                 "client_id" => client.client_id,
                 "redirect_uri" => redirect_uri,
                 "code_verifier" => verifier
               })

      assert [%{label: "My laptop"}] =
               Repo.all(Engram.OAuth.RefreshToken, skip_tenant_check: true)
    end
  end

  describe "POST /api/oauth/authorize/consent — invalid request" do
    test "invalid client_id returns 400 JSON (no redirect — code-leak prevention)", %{conn: conn} do
      user = insert(:user)

      params =
        valid_params("00000000-0000-0000-0000-000000000000", "https://x/cb")
        |> Map.put("vault_choice", "vault:*")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 400
      json = Jason.decode!(conn.resp_body)
      # EnforceConnectionCap fires before the controller and rejects unknown
      # client_ids with this error code. The 400 code-leak-prevention guarantee
      # still holds — we never redirect an unknown client.
      assert json["error"] == "missing_or_invalid_client_id"
    end

    test "missing code_challenge returns redirect_uri with error in JSON", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.delete("code_challenge")
        |> Map.put("vault_choice", "vault:*")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      assert String.starts_with?(json["redirect_uri"], redirect_uri)
      assert json["redirect_uri"] =~ "error=invalid_request"
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # POST /oauth/authorize — RETIRED in Phase 7.A. The SPA uses
  # /api/oauth/authorize/consent with Bearer JWT instead.
  # ──────────────────────────────────────────────────────────────────

  describe "POST /oauth/authorize — retired" do
    test "old route no longer matches (returns 404)", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:*")

      conn = post(conn, "/oauth/authorize", params)
      assert conn.status == 404
    end
  end
end
