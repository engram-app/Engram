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

    for key <- ~w(notes vaults attachment_bytes lifetime_embed_tokens
                  ai_conversations_today ai_queries_today
                  external_ai_searches_today inapp_searches_today) do
      entry = body["usage"][key]
      assert is_map(entry), "missing usage entry: #{key}"
      assert is_integer(entry["used"]), "#{key}.used must always be a number"
    end
  end

  test "reports the Free caps and a real vault count", %{conn: conn} do
    body = usage(conn)

    assert body["usage"]["notes"]["limit"] == 10_000
    assert body["usage"]["vaults"]["limit"] == 1
    # register_vault/3 in setup created exactly one.
    assert body["usage"]["vaults"]["used"] == 1
    assert body["usage"]["external_ai_searches_today"]["limit"] == 15
  end

  test "an uncapped limit reports null, not -1 or a sentinel", %{conn: conn, user: user} do
    insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => -1})

    assert usage(conn)["usage"]["notes"]["limit"] == nil
  end

  test "reflects notes actually counted", %{conn: conn, user: user} do
    UsageMeters.inc_notes_count(user.id, 3)

    assert usage(conn)["usage"]["notes"]["used"] == 3
  end

  test "conversation counters reset across a UTC day boundary", %{conn: conn, user: user} do
    # Stored counters from a PREVIOUS day are already spent-and-reset as far as
    # the next tick is concerned. Reporting the raw integer would tell a user
    # they had used 5 of 5 conversations when the next call starts them at 0.
    Engram.Repo.insert!(
      %Engram.UsageMeters.Meter{
        user_id: user.id,
        conversations_today: 5,
        conversations_day_key: Date.add(Date.utc_today(), -1),
        queries_today: 40,
        queries_day_key: Date.add(Date.utc_today(), -1),
        updated_at: DateTime.utc_now()
      },
      skip_tenant_check: true,
      on_conflict: :replace_all,
      conflict_target: :user_id
    )

    body = usage(conn)

    assert body["usage"]["ai_conversations_today"]["used"] == 0
    assert body["usage"]["ai_queries_today"]["used"] == 0
  end

  test "search bucket usage tracks what was actually spent", %{conn: conn, user: user} do
    assert usage(conn)["usage"]["external_ai_searches_today"]["used"] == 0

    # Spend two tokens directly — the endpoint must observe them without
    # itself consuming budget.
    for _ <- 1..2, do: Engram.Usage.DailyCap.spend(user.id, "ext_search", 15, 15 / 86_400)

    assert usage(conn)["usage"]["external_ai_searches_today"]["used"] == 2

    # Reading twice must not move the number — asking how much budget you have
    # cannot cost budget.
    assert usage(conn)["usage"]["external_ai_searches_today"]["used"] == 2
  end
end
