defmodule Engram.OAuthRefreshGraceTest do
  @moduledoc """
  Refresh-token reuse grace window (#1974).

  A client whose rotation response is lost retries with the token it still
  holds. Without a grace window that retry is indistinguishable from theft, so
  RFC 6749 §10.4 revoked the whole family and the connection died; access
  tokens last 15 min, so the risk recurred every 15 min (the 2026-10-12 churn).

  Within the window, and only while the successor has never been used, the
  replay re-issues: the unused successor is revoked and a new one minted, so
  the family never has two live tokens. Anything else is still reuse.
  """
  use Engram.DataCase, async: true

  import Ecto.Query
  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]
  import ExUnit.CaptureLog

  alias Engram.OAuth
  alias Engram.OAuth.RefreshToken
  alias Engram.Repo

  setup do
    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "client_name" => "Claude"
      })

    redirect_uri = hd(client.redirect_uris)
    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp"
      })

    {:ok, url} = OAuth.mint_authorization_code(insert(:user), validated, :all, nil)

    {:ok, %{refresh_token: rt1}} =
      OAuth.exchange_authorization_code(%{
        "code" => code_from_redirect(url),
        "redirect_uri" => redirect_uri,
        "client_id" => client.client_id,
        "code_verifier" => verifier
      })

    %{client_id: client.client_id, rt1: rt1}
  end

  defp row(raw) do
    hash = Engram.Crypto.sha256_hex(raw)
    Repo.one!(from(r in RefreshToken, where: r.token_hash == ^hash), skip_tenant_check: true)
  end

  defp live_in_family(family_id) do
    Repo.aggregate(
      from(r in RefreshToken,
        where: r.family_id == ^family_id and is_nil(r.consumed_at) and is_nil(r.revoked_at)
      ),
      :count,
      skip_tenant_check: true
    )
  end

  defp age_consumed(raw, seconds) do
    at = DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.truncate(:second)

    raw
    |> row()
    |> Ecto.Changeset.change(consumed_at: at)
    |> Repo.update!(skip_tenant_check: true)
  end

  test "a replay inside the window re-issues and revokes the unused successor", ctx do
    {:ok, %{refresh_token: rt2}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)

    log =
      capture_log(fn ->
        assert {:ok, %{refresh_token: rt3}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
        send(self(), {:rt3, rt3})
      end)

    assert_received {:rt3, rt3}
    assert log =~ "oauth_refresh_grace_reissue"
    assert log =~ "within_grace=true"

    assert row(rt2).revoked_at
    refute row(rt3).revoked_at
    assert live_in_family(row(rt3).family_id) == 1
    assert {:ok, _} = OAuth.rotate_refresh_token(rt3, ctx.client_id)
  end

  test "a replay after the window is reuse and revokes the family", ctx do
    {:ok, %{refresh_token: rt2}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
    age_consumed(ctx.rt1, 61)

    log =
      capture_log(fn ->
        assert {:error, {:invalid_grant, :refresh_token_reuse}} =
                 OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
      end)

    assert log =~ "within_grace=false"
    assert live_in_family(row(rt2).family_id) == 0
  end

  # The client provably received the successor, so the old token in anyone
  # else's hands is theft, however soon it arrives.
  test "a replay after the successor was used is reuse, even inside the window", ctx do
    {:ok, %{refresh_token: rt2}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
    {:ok, %{refresh_token: rt3}} = OAuth.rotate_refresh_token(rt2, ctx.client_id)

    assert {:error, {:invalid_grant, :refresh_token_reuse}} =
             OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)

    assert live_in_family(row(rt3).family_id) == 0
  end

  # Fifth review #4: successors are found by lineage, not by `inserted_at >=
  # consumed_at`. `inserted_at` is the minting node's clock, so a re-issue
  # minted on a lagging node used to be invisible to the next replay, and the
  # client's later use of it went unseen: theft re-issued instead of revoking.
  test "a used re-issue minted on a lagging clock still makes a replay reuse", ctx do
    {:ok, _} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
    {:ok, %{refresh_token: rt3}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)

    rt3
    |> row()
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -300, :second))
    |> Repo.update!(skip_tenant_check: true)

    {:ok, %{refresh_token: rt4}} = OAuth.rotate_refresh_token(rt3, ctx.client_id)

    assert {:error, {:invalid_grant, :refresh_token_reuse}} =
             OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)

    assert live_in_family(row(rt4).family_id) == 0
  end

  test "a re-issue minted on a lagging clock is still superseded by the next replay", ctx do
    {:ok, _} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
    {:ok, %{refresh_token: rt3}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)

    rt3
    |> row()
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -300, :second))
    |> Repo.update!(skip_tenant_check: true)

    assert {:ok, %{refresh_token: rt5}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
    assert row(rt3).superseded_at
    assert live_in_family(row(rt5).family_id) == 1
  end

  # Second review of #1974: three or more duplicates of one retry are still
  # the lost-response case. Each re-issues; only one token is ever live.
  test "every replay inside the window re-issues, leaving one live token", ctx do
    {:ok, _} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
    {:ok, _} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
    {:ok, %{refresh_token: rt4}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)

    assert live_in_family(row(rt4).family_id) == 1
    refute row(rt4).revoked_at
  end

  # Approved follow-up #1: the re-issues per presented token are capped, and
  # the window is anchored at the token's first use (its consumed_at, set
  # once), so a stream of replays can neither mint forever nor slide the
  # window. Hydra caps the same way (persister_oauth2.go, used_times < N).
  test "re-issues are capped at 5 per token; the 6th replay is reuse", ctx do
    {:ok, _} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
    first_use = row(ctx.rt1).consumed_at

    for _ <- 1..5, do: assert({:ok, _} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id))

    assert row(ctx.rt1).consumed_at == first_use

    log =
      capture_log(fn ->
        assert {:error, {:invalid_grant, :refresh_token_reuse}} =
                 OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
      end)

    assert log =~ "oauth_refresh_reuse"
    assert live_in_family(row(ctx.rt1).family_id) == 0
  end

  # A successor revoked any other way (RFC 7009) must stay revoked: a replay
  # of its parent is not a way back in.
  test "a replay never resurrects a successor revoked by the client", ctx do
    {:ok, %{refresh_token: rt2}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
    :ok = OAuth.revoke_token(rt2, ctx.client_id, nil)

    assert {:error, {:invalid_grant, :refresh_token_reuse}} =
             OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)

    assert live_in_family(row(rt2).family_id) == 0
  end

  # Review of #1974: every re-issue is visible, with whether it came from the
  # address that received the successor. A thief replaying from elsewhere
  # inside the window still gets a token, so this is the trail.
  test "a re-issue logs the client and whether the IP matched the rotation", ctx do
    {:ok, _} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id, ip: "203.0.113.7")

    log =
      capture_log(fn ->
        assert {:ok, _} =
                 OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id, ip: "198.51.100.9")
      end)

    assert log =~ "oauth_refresh_grace_reissue"
    assert log =~ "client_id=#{row(ctx.rt1).client_id}"
    assert log =~ "ip_matched=false"
  end

  test "a re-issue from the rotation's own IP logs ip_matched=true", ctx do
    {:ok, _} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id, ip: "203.0.113.7")

    log =
      capture_log(fn ->
        assert {:ok, _} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id, ip: "203.0.113.7")
      end)

    assert log =~ "oauth_refresh_grace_reissue"
    assert log =~ "ip_matched=true"
  end

  # Only one of the two holders can be the client. If the successor the grace
  # revoked turns up later, someone else had a copy: the family dies.
  test "the revoked successor used after a re-issue revokes the family", ctx do
    {:ok, %{refresh_token: rt2}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
    {:ok, %{refresh_token: rt3}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)

    assert {:error, {:invalid_grant, :refresh_token_revoked}} =
             OAuth.rotate_refresh_token(rt2, ctx.client_id)

    assert live_in_family(row(rt3).family_id) == 0
  end

  test "a replay from another client never re-issues", ctx do
    {:ok, other} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://example.com/cb"],
        "client_name" => "Other"
      })

    {:ok, %{refresh_token: rt2}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)

    assert {:error, {:invalid_grant, :client_mismatch}} =
             OAuth.rotate_refresh_token(ctx.rt1, other.client_id)

    refute row(rt2).revoked_at
  end

  # Reuse detection needs the used rows: a replay of a token whose row was
  # pruned reads as unknown, not as reuse, and revokes nothing. The hourly
  # cleanup must keep consumed and revoked rows well past the grace window
  # (at least 30 min; it keeps revoked rows 7 days, consumed ones until expiry).
  test "cleanup keeps used refresh tokens long enough for reuse detection", ctx do
    {:ok, %{refresh_token: rt2}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
    age_consumed(ctx.rt1, 31 * 60)

    {:ok, %{refresh_token: rt3}} = OAuth.rotate_refresh_token(rt2, ctx.client_id)
    :ok = OAuth.revoke_token(rt3, ctx.client_id, nil)

    rt3
    |> row()
    |> Ecto.Changeset.change(revoked_at: DateTime.add(DateTime.utc_now(:second), -31 * 60))
    |> Repo.update!(skip_tenant_check: true)

    OAuth.cleanup_expired()

    assert row(ctx.rt1).consumed_at
    assert row(rt3).revoked_at

    log =
      capture_log(fn ->
        assert {:error, {:invalid_grant, :refresh_token_reuse}} =
                 OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
      end)

    assert log =~ "oauth_refresh_reuse"
  end
end
