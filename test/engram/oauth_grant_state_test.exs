defmodule Engram.OAuthGrantStateTest do
  @moduledoc """
  The server-side state behind an OAuth access token's `gid` claim
  (`Engram.OAuth.expand_claims/1`, `granted_at/1`): who owns the grant,
  whether it is live, what it reaches and when it was created. The grant's
  rows are the single authority; the token's own claims are never trusted
  for any of it.

  Real flow (consent -> exchange -> rotate) wherever the property is about
  the plumbing; direct row updates only to stage what another node, a skewed
  clock or the cleanup job leaves behind.
  """
  use EngramWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Engram.{Accounts, Connections, OAuth, Vaults}
  alias Engram.OAuth.RefreshToken
  alias Engram.Repo

  @redirect "https://client.example/cb"

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    user = ensure_external_id(user)
    {:ok, a, _} = Vaults.register_vault(user, "A", Ecto.UUID.generate())
    {:ok, b, _} = Vaults.register_vault(user, "B", Ecto.UUID.generate())

    {:ok, client} =
      OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "Client"})

    %{user: user, a: a, b: b, client: client}
  end

  defp grant(ctx, selection, user \\ nil) do
    user = user || ctx.user
    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => ctx.client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp"
      })

    {:ok, url} = OAuth.mint_authorization_code(user, validated, selection, nil)

    {:ok, tokens} =
      OAuth.exchange_authorization_code(%{
        "code" => code_from_redirect(url),
        "redirect_uri" => @redirect,
        "client_id" => ctx.client.client_id,
        "code_verifier" => verifier
      })

    tokens
  end

  defp rotate(ctx, tokens) do
    {:ok, rotated} = OAuth.rotate_refresh_token(tokens.refresh_token, ctx.client.client_id)
    rotated
  end

  defp claims(tokens) do
    {:ok, claims} = Engram.Token.verify(tokens.access_token)
    claims
  end

  defp gid(tokens), do: claims(tokens)["gid"]

  defp row(raw), do: Repo.get_by!(RefreshToken, token_hash: Engram.Crypto.sha256_hex(raw))

  defp family_rows(family),
    do: Repo.all(from(t in RefreshToken, where: t.family_id == ^family))

  defp set_row(raw, changes) do
    hash = Engram.Crypto.sha256_hex(raw)

    {1, _} =
      Repo.update_all(from(t in RefreshToken, where: t.token_hash == ^hash), set: changes)
  end

  # A vault-scoped read every live grant in this file may make.
  defp folders(token, vault) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-vault-id", vault.id)
    |> get("/api/folders")
  end

  defp evict(family), do: Engram.Cache.evict_local(:oauth_grant, family)

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  # ── item 4: the grant must belong to the token's user ──────────────

  describe "a gid pointing at another user's grant" do
    test "is refused, even in a token we signed", ctx do
      other = ensure_external_id(insert(:user))
      theirs = grant(ctx, :all, other)

      # Signed with our key, but `gid` names the other user's family.
      forged = Accounts.generate_jwt(ctx.user, %{"scope" => "mcp", "gid" => gid(theirs)})

      assert Accounts.grant_claims(forged) == :revoked
      assert OAuth.granted_at(Map.put(claims(theirs), "user_id", ctx.user.id)) == :revoked

      assert folders(forged, ctx.a).status == 401

      # The owner's own token still works: the check is the pairing.
      assert {:ok, _} = Accounts.grant_claims(theirs.access_token)
    end
  end

  # ── item 5: liveness and revocation are family-wide ────────────────

  describe "RFC 7009 revoke_token" do
    test "revokes the whole family, not only the presented row", ctx do
      first = grant(ctx, :all)
      second = rotate(ctx, first)

      assert :ok = OAuth.revoke_token(second.refresh_token, ctx.client.client_id, nil)

      assert Enum.all?(family_rows(gid(first)), & &1.revoked_at)
      assert Accounts.grant_claims(first.access_token) == :revoked
      assert Accounts.grant_claims(second.access_token) == :revoked
    end

    test "a token revoked through it answers 401 at once", ctx do
      tokens = grant(ctx, :all)
      assert folders(tokens.access_token, ctx.a).status == 200

      :ok = OAuth.revoke_token(tokens.refresh_token, ctx.client.client_id, nil)

      assert folders(tokens.access_token, ctx.a).status == 401
    end
  end

  # ── item 7: refused before the plugs that have side effects ────────

  describe "a revoked grant's token on the authed pipeline" do
    test "is 401 from Auth itself: no activity stamp", ctx do
      tokens = grant(ctx, :all)
      :ok = Connections.revoke_oauth_grant(ctx.user.id, gid(tokens))
      assert is_nil(Engram.UsageMeters.last_active_at(ctx.user.id))

      conn = folders(tokens.access_token, ctx.a)

      assert conn.status == 401
      # BumpActivity (and DeviceFingerprint, WebActivity, the rps budget) run
      # after Auth: a halt there means none of them saw the request.
      assert is_nil(Engram.UsageMeters.last_active_at(ctx.user.id))
      refute Map.has_key?(conn.assigns, :current_user)
    end

    test "a live grant's token still passes and is stamped", ctx do
      tokens = grant(ctx, :all)
      assert folders(tokens.access_token, ctx.a).status == 200
      assert %DateTime{} = Engram.UsageMeters.last_active_at(ctx.user.id)
    end
  end

  describe "liveness" do
    # #1974's grace re-issue revokes the unused successor it replaces. That
    # row is marked superseded, so the family (one grant) stays live.
    test "a grace re-issue leaves the grant live", ctx do
      first = grant(ctx, :all)
      second = rotate(ctx, first)
      reissued = rotate(ctx, first)
      evict(gid(first))

      assert Repo.get_by!(RefreshToken,
               token_hash: Engram.Crypto.sha256_hex(second.refresh_token)
             ).superseded_at

      assert {:ok, _} = Accounts.grant_claims(reissued.access_token)
      assert {:ok, _} = OAuth.rotate_refresh_token(reissued.refresh_token, ctx.client.client_id)
    end

    test "cleanup never reaps a family for a superseded row", ctx do
      first = grant(ctx, :all)
      second = rotate(ctx, first)
      reissued = rotate(ctx, first)
      set_row(second.refresh_token, revoked_at: ago(8 * 24 * 3600))

      OAuth.cleanup_expired()
      evict(gid(first))

      assert {:ok, _} = Accounts.grant_claims(reissued.access_token)
    end

    test "the superseded successor presented later revokes the grant", ctx do
      first = grant(ctx, :all)
      second = rotate(ctx, first)
      reissued = rotate(ctx, first)

      assert {:error, {:invalid_grant, :refresh_token_revoked}} =
               OAuth.rotate_refresh_token(second.refresh_token, ctx.client.client_id)

      assert Accounts.grant_claims(reissued.access_token) == :revoked
    end

    # Rows minted on two nodes whose clocks disagree: the successor's
    # `inserted_at` lands BEFORE its consumed predecessor's.
    test "does not depend on inserted_at ordering", ctx do
      first = grant(ctx, :all)
      second = rotate(ctx, first)
      set_row(first.refresh_token, inserted_at: DateTime.add(DateTime.utc_now(), 3600, :second))

      # A revoke that marks one row only (a release that predates
      # family-wide RFC 7009, or the revoke racing a rotation).
      set_row(second.refresh_token, revoked_at: DateTime.utc_now(:second))
      evict(gid(first))

      assert Accounts.grant_claims(second.access_token) == :revoked
      assert folders(second.access_token, ctx.a).status == 401
    end

    # What a rotation that read its row just before a family revoke leaves
    # behind: the revoked predecessor and an unrevoked successor.
    test "an unrevoked row of a revoked family is not live and cannot rotate", ctx do
      first = grant(ctx, :all)
      second = rotate(ctx, first)
      set_row(first.refresh_token, revoked_at: DateTime.utc_now(:second))
      evict(gid(first))

      assert Accounts.grant_claims(second.access_token) == :revoked

      assert {:error, {:invalid_grant, :refresh_token_revoked}} =
               OAuth.rotate_refresh_token(second.refresh_token, ctx.client.client_id)

      assert Enum.all?(family_rows(gid(first)), & &1.revoked_at)
    end
  end

  # 0.52.0's grace re-issue (#1981) revokes the successor it replaces but
  # predates `superseded_at`, and an old node keeps writing such rows during
  # a rolling deploy. Those rows must not read as a family revoke.
  describe "a grace-superseded row written without superseded_at" do
    defp legacy_reissue(ctx) do
      first = grant(ctx, :all)
      second = rotate(ctx, first)
      reissued = rotate(ctx, first)
      set_row(second.refresh_token, superseded_at: nil)
      evict(gid(first))
      %{first: first, second: second, reissued: reissued}
    end

    test "leaves the grant live before any backfill", ctx do
      %{reissued: reissued} = legacy_reissue(ctx)

      assert {:ok, _} = Accounts.grant_claims(reissued.access_token)
      assert folders(reissued.access_token, ctx.a).status == 200
      assert {:ok, _} = OAuth.rotate_refresh_token(reissued.refresh_token, ctx.client.client_id)
    end

    test "is stamped superseded by the hourly cleanup, and never reaped", ctx do
      %{second: second, reissued: reissued} = legacy_reissue(ctx)
      revoked_at = DateTime.truncate(ago(8 * 86_400), :second)
      set_row(second.refresh_token, revoked_at: revoked_at)

      OAuth.cleanup_expired()

      assert row(second.refresh_token).superseded_at == revoked_at
      evict(gid(reissued))
      assert {:ok, _} = Accounts.grant_claims(reissued.access_token)
    end

    test "a real family revoke still kills it, and cleanup stamps nothing", ctx do
      %{second: second, reissued: reissued} = legacy_reissue(ctx)

      :ok = OAuth.revoke_token(reissued.refresh_token, ctx.client.client_id, nil)
      OAuth.cleanup_expired()
      evict(gid(reissued))

      assert Accounts.grant_claims(reissued.access_token) == :revoked
      refute row(second.refresh_token).superseded_at
    end

    # main's RFC 7009 revoked the presented row only. Revoking the live leaf
    # leaves no live row, so the family is dead.
    test "a single-row revoke of the live leaf still kills it", ctx do
      %{second: second, reissued: reissued} = legacy_reissue(ctx)

      set_row(reissued.refresh_token, revoked_at: DateTime.utc_now(:second))
      OAuth.cleanup_expired()
      evict(gid(reissued))

      assert Accounts.grant_claims(reissued.access_token) == :revoked
      refute row(second.refresh_token).superseded_at
      refute row(reissued.refresh_token).superseded_at
    end
  end

  describe "cleanup" do
    test "deleting a revoked latest row does not bring the family back", ctx do
      first = grant(ctx, :all)
      second = rotate(ctx, first)
      family = gid(first)

      # One row revoked (as above) long enough ago for cleanup to reap it;
      # the consumed predecessor is unrevoked and unexpired.
      set_row(second.refresh_token, revoked_at: DateTime.truncate(ago(8 * 86_400), :second))
      evict(family)
      assert Accounts.grant_claims(second.access_token) == :revoked

      OAuth.cleanup_expired()
      # Read the rows, not the cached verdict from before the cleanup.
      evict(family)

      assert Accounts.grant_claims(first.access_token) == :revoked
      assert Accounts.grant_claims(second.access_token) == :revoked
      # Gone whole, never left half-deleted.
      assert family_rows(family) == []
    end

    test "reaps old expired rows of a live family and leaves it live", ctx do
      first = grant(ctx, :all)
      second = rotate(ctx, first)

      set_row(first.refresh_token, expires_at: DateTime.truncate(ago(8 * 86_400), :second))
      OAuth.cleanup_expired()

      assert family_rows(gid(first)) |> Enum.map(& &1.id) == [row(second.refresh_token).id]
      assert {:ok, _} = Accounts.grant_claims(second.access_token)
    end
  end

  # ── item 6: granted_at is the family's creation, persisted ─────────

  describe "granted_at" do
    test "is stored at exchange and carried across rotation", ctx do
      first = grant(ctx, :all)
      granted = row(first.refresh_token).granted_at
      assert %DateTime{} = granted

      second = rotate(ctx, first)
      assert row(second.refresh_token).granted_at == granted
      assert OAuth.granted_at(claims(second)) == granted
    end

    test "survives cleanup of the family's oldest rows", ctx do
      first = grant(ctx, :all)
      second = rotate(ctx, first)
      granted = OAuth.granted_at(claims(second))

      # The predecessor was minted an hour earlier and is reaped.
      set_row(first.refresh_token,
        inserted_at: ago(3600),
        expires_at: DateTime.truncate(ago(8 * 86_400), :second)
      )

      OAuth.cleanup_expired()
      evict(gid(second))

      assert [_] = family_rows(gid(second))
      assert OAuth.granted_at(claims(second)) == granted
    end

    test "a row from before the column falls back to the family's first row and heals", ctx do
      first = grant(ctx, :all)
      earliest = DateTime.truncate(ago(7200), :microsecond)
      set_row(first.refresh_token, granted_at: nil, inserted_at: earliest)
      evict(gid(first))

      assert OAuth.granted_at(claims(first)) == earliest

      second = rotate(ctx, first)
      assert row(second.refresh_token).granted_at == earliest
    end
  end

  # ── item 12: a pre-levels grant's vaults come from its row ─────────

  describe "a pre-levels grant narrowed after its token was minted" do
    test "cannot reach the removed vault with the old, wider token", ctx do
      tokens = grant(ctx, [ctx.a.id, ctx.b.id])
      assert Enum.sort(claims(tokens)["vault_ids"]) == Enum.sort([ctx.a.id, ctx.b.id])

      # Deleting B narrows the grant's row to [A]; a session restores B.
      {:ok, _} = Vaults.delete_vault(ctx.user, ctx.b.id)
      {:ok, _} = Vaults.restore_vault(ctx.user, ctx.b.id)
      assert row(tokens.refresh_token).vault_ids == [ctx.a.id]

      {:ok, expanded} = Accounts.grant_claims(tokens.access_token)
      assert expanded["vault_ids"] == [ctx.a.id]
      assert expanded["vault_id"] == ctx.a.id

      assert folders(tokens.access_token, ctx.b).status == 404
      assert folders(tokens.access_token, ctx.a).status == 200
    end

    # Narrowing skips revoked rows, so a superseded successor keeps the old,
    # wider set. Minted on a node whose clock runs ahead, it is the family's
    # newest row by `inserted_at`; it must still not answer for the grant.
    test "a superseded row's stale vault set never answers for the grant", ctx do
      first = grant(ctx, [ctx.a.id, ctx.b.id])
      second = rotate(ctx, first)
      reissued = rotate(ctx, first)
      set_row(second.refresh_token, inserted_at: DateTime.add(DateTime.utc_now(), 3600, :second))

      {:ok, _} = Vaults.delete_vault(ctx.user, ctx.b.id)
      {:ok, _} = Vaults.restore_vault(ctx.user, ctx.b.id)
      assert Enum.sort(row(second.refresh_token).vault_ids) == Enum.sort([ctx.a.id, ctx.b.id])
      evict(gid(first))

      {:ok, expanded} = Accounts.grant_claims(reissued.access_token)
      assert expanded["vault_ids"] == [ctx.a.id]
      assert folders(reissued.access_token, ctx.b).status == 404
    end

    test "a family with every row revoked still answers revoked", ctx do
      first = grant(ctx, [ctx.a.id, ctx.b.id])
      second = rotate(ctx, first)
      :ok = OAuth.revoke_token(second.refresh_token, ctx.client.client_id, nil)
      evict(gid(first))

      assert Accounts.grant_claims(second.access_token) == :revoked
    end
  end

  # ── purging a vault leaves grants that reach other vaults alone ────

  describe "purging a vault" do
    # The scalar `vault_id` column is a foreign key with ON DELETE CASCADE,
    # so a grant whose scalar names the purged vault loses its rows (and so
    # its liveness) however many other vaults it still reaches. Deleting the
    # lowest-sorted vault targets the "first of set" a scalar would hold.
    defp first_and_other(ctx) do
      [first, other] = Enum.sort_by([ctx.a, ctx.b], & &1.id)
      {first, other}
    end

    defp purge!(ctx, vault) do
      bypass = Bypass.open()
      Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/delete", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":{"status":"acknowledged"}}))
      end)

      {:ok, _} = Vaults.delete_vault(ctx.user, vault.id)
      assert :ok = Engram.Workers.CleanupVault.perform_cleanup(vault.id, ctx.user.id, force: true)
    end

    defp live!(tokens, vault) do
      assert {:ok, _} = Accounts.grant_claims(tokens.access_token)
      assert folders(tokens.access_token, vault).status == 200
    end

    test "a leveled grant writing two vaults survives purge of one", ctx do
      {first, other} = first_and_other(ctx)
      tokens = grant(ctx, {%{ctx.a.id => "write", ctx.b.id => "write"}, "none"})

      purge!(ctx, first)

      live!(tokens, other)
      assert {:ok, _} = OAuth.rotate_refresh_token(tokens.refresh_token, ctx.client.client_id)
    end

    test "a narrowed pre-levels grant survives purge of its old scalar vault", ctx do
      {first, other} = first_and_other(ctx)
      tokens = grant(ctx, [ctx.a.id, ctx.b.id])
      assert row(tokens.refresh_token).vault_id == first.id

      purge!(ctx, first)

      assert row(tokens.refresh_token).vault_ids == [other.id]
      live!(tokens, other)
    end

    test "a client-wide revoke scoped to the deleted vault spares a grant narrowed off it",
         ctx do
      {first, other} = first_and_other(ctx)
      tokens = grant(ctx, [ctx.a.id, ctx.b.id])
      {:ok, _} = Vaults.delete_vault(ctx.user, first.id)
      assert row(tokens.refresh_token).vault_ids == [other.id]
      # A release that predates the repoint narrowed the array only, so the
      # scalar can still name the deleted vault; the array is the authority.
      set_row(tokens.refresh_token, vault_id: first.id)

      assert :ok = Connections.revoke_oauth_family(ctx.user.id, ctx.client.client_id, first.id)

      live!(tokens, other)
    end
  end

  # ── item 11: replay revokes the family ─────────────────────────────

  describe "refresh-token replay" do
    test "revokes the family and every access token minted from it", ctx do
      first = grant(ctx, :all)
      second = rotate(ctx, first)
      {:ok, _} = Accounts.grant_claims(second.access_token)
      # Using the successor ends #1974's grace window for `first`: from now
      # on a replay of it is theft, not a lost rotation response.
      _third = rotate(ctx, second)

      assert {:error, {:invalid_grant, :refresh_token_reuse}} =
               OAuth.rotate_refresh_token(first.refresh_token, ctx.client.client_id)

      assert Enum.all?(family_rows(gid(first)), & &1.revoked_at)
      assert Accounts.grant_claims(second.access_token) == :revoked
    end
  end
end
