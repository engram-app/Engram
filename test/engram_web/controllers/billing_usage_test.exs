defmodule EngramWeb.BillingUsageTest do
  @moduledoc """
  `GET /api/billing/usage` — the caps were always fetchable; this is the half
  that was missing, so the tests are about the CURRENT values being real and
  correctly paired, not about the caps.
  """
  use EngramWeb.ConnCase, async: false

  alias Engram.UsageMeters

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, _vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "usage-key")
    grant_api_write!(user)

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), user: user}
  end

  defp usage(conn), do: conn |> get("/api/billing/usage") |> json_response(200)

  test "pairs every metered limit with a real current value", %{conn: conn} do
    body = usage(conn)

    assert body["tier"] == "free"

    for key <- ~w(notes vaults attachment_bytes lifetime_embed_tokens indexed_notes) do
      entry = body["usage"][key]
      assert is_map(entry), "missing usage entry: #{key}"
      assert is_integer(entry["used"]), "#{key}.used must always be a number"
    end

    # `ai_searches` is the one entry with no current value: the budget lives in
    # the cluster-synced ETS counter, which has no read-without-spend API.
    assert body["usage"]["ai_searches"]["used"] == nil
    assert is_integer(body["usage"]["ai_searches"]["limit"])
  end

  test "reports the Free caps and a real vault count", %{conn: conn} do
    body = usage(conn)

    assert body["usage"]["notes"]["limit"] == 10_000
    assert body["usage"]["vaults"]["limit"] == 1
    # register_vault/3 in setup created exactly one.
    assert body["usage"]["vaults"]["used"] == 1
    assert body["usage"]["indexed_notes"]["limit"] == 2_000
  end

  test "an uncapped limit reports null, not -1 or a sentinel", %{conn: conn, user: user} do
    insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => -1})

    assert usage(conn)["usage"]["notes"]["limit"] == nil
  end

  test "reflects notes actually counted", %{conn: conn, user: user} do
    UsageMeters.inc_notes_count(user.id, 3)

    assert usage(conn)["usage"]["notes"]["used"] == 3
  end

  test "the AI meter publishes its cap; used is nil by design", %{conn: conn} do
    # The budget lives in the cluster-synced ETS counter, which has no
    # read-without-spend API — asking how much is left must not cost any. The
    # cap is still published so the UI can name the limit in an upgrade prompt.
    assert usage(conn)["usage"]["ai_searches"] == %{"used" => nil, "limit" => 20}
  end

  test "indexed_notes never exceeds the indexed cap", %{conn: conn, user: user} do
    UsageMeters.inc_notes_count(user.id, 3_000)

    body = usage(conn)

    # notes_cap (10k) is NOT the binding limit on Free — indexed_notes_cap is.
    assert body["usage"]["notes"]["used"] == 3_000
    assert body["usage"]["indexed_notes"]["used"] == 2_000
    assert body["usage"]["indexed_notes"]["limit"] == 2_000
  end
end
