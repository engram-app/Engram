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
    assert log =~ "oauth_refresh_reuse"
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

  test "the grace is spent once: a second replay revokes the family", ctx do
    {:ok, _} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
    {:ok, %{refresh_token: rt3}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)

    assert {:error, {:invalid_grant, _}} = OAuth.rotate_refresh_token(ctx.rt1, ctx.client_id)
    assert live_in_family(row(rt3).family_id) == 0
  end
end
