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

    for key <- ~w(notes vaults attachment_bytes lifetime_embed_tokens indexed_notes
                  ai_conversations_today ai_queries_today) do
      entry = body["usage"][key]
      assert is_map(entry), "missing usage entry: #{key}"
      assert is_integer(entry["used"]), "#{key}.used must always be a number"
    end

    # Token buckets report what is LEFT — a derived "used" decays as the bucket
    # refills, which would make a daily count read 0 by afternoon.
    for key <- ~w(external_ai_searches inapp_searches) do
      entry = body["usage"][key]
      assert is_integer(entry["remaining"]), "#{key}.remaining must be a number"
      refute Map.has_key?(entry, "used"), "#{key} must not claim a daily used count"
    end
  end

  test "reports the Free caps and a real vault count", %{conn: conn} do
    body = usage(conn)

    assert body["usage"]["notes"]["limit"] == 10_000
    assert body["usage"]["vaults"]["limit"] == 1
    # register_vault/3 in setup created exactly one.
    assert body["usage"]["vaults"]["used"] == 1
    assert body["usage"]["external_ai_searches"]["limit"] == 15
    assert body["usage"]["external_ai_searches"]["remaining"] == 15
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

  test "search bucket reports what is left, and reading does not spend", %{
    conn: conn,
    user: user
  } do
    assert usage(conn)["usage"]["external_ai_searches"]["remaining"] == 15

    for _ <- 1..2, do: Engram.Usage.DailyCap.spend(user.id, "ext_search", 15, 15 / 86_400)

    assert usage(conn)["usage"]["external_ai_searches"]["remaining"] == 13

    # Asking how much budget you have must not cost budget.
    assert usage(conn)["usage"]["external_ai_searches"]["remaining"] == 13
  end

  test "ai_conversations_today is clamped to the limit for display", %{conn: conn, user: user} do
    # The meter commits `conversations_today + 1` before testing `today > cap`,
    # so a capped Free user really does persist 6 against a limit of 5. Correct
    # for the gate, 120% on a progress bar.
    Engram.Repo.insert!(
      %Engram.UsageMeters.Meter{
        user_id: user.id,
        conversations_today: 6,
        conversations_day_key: Date.utc_today(),
        updated_at: DateTime.utc_now()
      },
      skip_tenant_check: true,
      on_conflict: :replace_all,
      conflict_target: :user_id
    )

    entry = usage(conn)["usage"]["ai_conversations_today"]
    assert entry["limit"] == 5
    assert entry["used"] == 5
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
