defmodule EngramWeb.BillingUsageTest do
  @moduledoc """
  `GET /api/billing/usage` — the caps were always fetchable; this is the half
  that was missing, so the tests are about the CURRENT values being real and
  correctly paired, not about the caps.
  """
  use EngramWeb.ConnCase, async: false

  import Ecto.Query

  alias Engram.UsageMeters

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, _vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "usage-key")
    lift_api_rps_cap!(user)

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

  # The usage banner and panel read this: they follow the enforced set.
  test "reports the v5 Free note cap only once the v5 go flag is on", %{conn: conn} do
    Engram.IndexBudgetHelpers.enable_index_budget()
    assert usage(conn)["usage"]["notes"]["limit"] == 2_000
  end

  test "reports the Free caps and a real vault count", %{conn: conn} do
    body = usage(conn)

    assert body["usage"]["notes"]["limit"] == 3_000
    assert body["usage"]["vaults"]["limit"] == 1
    # register_vault/3 in setup created exactly one.
    assert body["usage"]["vaults"]["used"] == 1
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

  # Compat shim: plugins before the cap removal render a "Notes searchable"
  # row from this entry. Uncapped (`limit: nil`) hides it there, and `used`
  # mirrors stored notes because every stored note is searchable.
  test "indexed_notes is uncapped and equals stored notes", %{conn: conn, user: user} do
    UsageMeters.inc_notes_count(user.id, 2_500)

    body = usage(conn)

    assert body["usage"]["indexed_notes"] == %{"used" => 2_500, "limit" => nil}
  end

  # Review H3: the v5 index budget is visible. `index_points` pairs the
  # account's points (chunk rows) with its cap, which is null while the
  # budget is off; `floor_notes` counts notes on keyword-only search.
  describe "index budget" do
    setup %{user: user} do
      vault =
        Engram.Repo.one!(from(v in Engram.Vaults.Vault, where: v.user_id == ^user.id),
          skip_tenant_check: true
        )

      %{vault: vault}
    end

    test "reports points used, no limit and no floor notes while the budget is off", %{conn: conn} do
      body = usage(conn)
      assert body["usage"]["index_points"] == %{"used" => 0, "limit" => nil}
      assert body["usage"]["floor_notes"] == 0
    end

    test "with the budget on: the Free cap, real points and floor notes", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      Engram.IndexBudgetHelpers.enable_index_budget()
      note = Engram.Fixtures.insert_note!(user, vault, %{path: "F.md", content: "x"})

      {:ok, _} =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.query!(
            "INSERT INTO chunks (note_id, user_id, vault_id, position, char_start, char_end, qdrant_point_id, created_at) " <>
              "SELECT $1, $2, $3, g, 0, 1, gen_random_uuid(), now() FROM generate_series(1, 7) g",
            [Ecto.UUID.dump!(note.id), Ecto.UUID.dump!(user.id), Ecto.UUID.dump!(vault.id)]
          )

          Engram.Repo.update_all(
            from(n in Engram.Notes.Note, where: n.id == ^note.id),
            set: [index_tier: "floor"]
          )
        end)

      body = usage(conn)
      assert body["usage"]["index_points"] == %{"used" => 7, "limit" => 12_000}
      assert body["usage"]["floor_notes"] == 1
    end
  end

  describe "embed_bucket" do
    test "a new Free user sees a full bucket that is not refilling", %{conn: conn} do
      assert usage(conn)["usage"]["embed_bucket"] == %{
               "available" => 6_000_000,
               "capacity" => 6_000_000,
               "refill_per_day" => 16_438,
               "full_at" => nil,
               "parked_notes" => 0,
               "parked_ready_at" => nil
             }
    end

    test "a partly spent bucket says when it is full again", %{conn: conn, user: user} do
      {:ok, _} = UsageMeters.bucket_take(user.id, 3_000_000, 6_000_000)
      bucket = usage(conn)["usage"]["embed_bucket"]

      assert_in_delta bucket["available"], 3_000_000, 10
      {:ok, full_at, 0} = DateTime.from_iso8601(bucket["full_at"])
      expected = DateTime.add(DateTime.utc_now(), div(UsageMeters.bucket_refill_seconds(), 2))
      assert abs(DateTime.diff(full_at, expected)) < 60
    end

    test "parked_ready_at is when the whole backlog fits, even past the full date",
         %{conn: conn, user: user} do
      {:ok, _} = UsageMeters.bucket_take(user.id, 6_000_000, 6_000_000)
      vault = Engram.Repo.one!(Engram.Vaults.Vault, skip_tenant_check: true)

      for {path, need} <- [{"A.md", 4_000_000}, {"B.md", 6_000_000}] do
        note = Engram.Fixtures.insert_note!(user, vault, %{path: path, content: "# #{path}"})

        Engram.Repo.update_all(
          from(n in Engram.Notes.Note, where: n.id == ^note.id),
          [set: [embed_budget_parked: true, embed_budget_need: need]],
          skip_tenant_check: true
        )
      end

      bucket = usage(conn)["usage"]["embed_bucket"]
      assert bucket["parked_notes"] == 2

      # 10M behind an empty 6M bucket: 10/6 of a refill period, not one.
      {:ok, ready_at, 0} = DateTime.from_iso8601(bucket["parked_ready_at"])
      seconds = div(10_000_000 * UsageMeters.bucket_refill_seconds(), 6_000_000)
      assert abs(DateTime.diff(ready_at, DateTime.add(DateTime.utc_now(), seconds))) < 60
    end

    test "is null for a paid user", %{conn: conn, user: user} do
      insert(:subscription, user: user, tier: "pro", status: "active")
      # Setup's rps-cap override warmed the Free entitlement snapshot.
      :ok = Engram.Billing.EntitlementCache.evict(user.id)
      :ok = Engram.Cache.evict(:subscription, user.id)
      assert usage(conn)["usage"]["embed_bucket"] == nil
    end

    test "is null when an override removes the bucket", %{conn: conn, user: user} do
      insert(:user_limit_override, user: user, key: "embed_token_bucket", value: %{"v" => -1})
      assert usage(conn)["usage"]["embed_bucket"] == nil
    end
  end
end
