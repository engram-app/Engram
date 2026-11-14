defmodule Engram.Links.QualifiedPlanTest do
  # S4.6 (Engram#2523) statements planned as prod runs them: as `engram_app`
  # with the tenant set (FORCE RLS applies), in a custom AND a forced generic
  # plan (`QueryPlan.rls_plans/3`, docs/context/rls-leakproof-index-quals.md).
  #
  #   * the backfill's window probe and its write: by primary key only, never
  #     a vault's links;
  #   * the S5 gate (a folder rename asks "does this vault hold any
  #     path-qualified link?"): one descent of `note_links_qualified`, never
  #     a vault-wide index, whatever the vault's link count. S5 must send
  #     exactly this shape (`@probe`), or re-pin it here.
  #
  # Every qual compares a plain column to a parameter or tests a plain
  # boolean column: no function is applied to a column, so RLS cannot bar
  # it from an index. `n_distinct = 40` on the tenant columns costs a
  # generic `vault_id = $n` as prod's hundreds of tenants
  # (notes-generic-plan-mis-pick.md). Not async: ALTER TABLE and the role drop.
  use Engram.DataCase, async: false

  alias Engram.QueryPlan
  alias Engram.Workers.BackfillNoteLinkQualified

  @probe "SELECT EXISTS (SELECT 1 FROM note_links WHERE user_id = $1 AND vault_id = $2 AND qualified)"

  # 3,000 links from 30 notes; `qualified_count` of them qualified.
  defp seed_links!(user, vault, qualified_count) do
    notes =
      Engram.Fixtures.insert_notes!(
        user,
        vault,
        for(_ <- 1..30, do: build(:note, path_hmac: :crypto.strong_rand_bytes(32)))
      )

    Repo.query!(
      """
      INSERT INTO note_links (user_id, vault_id, source_note_id, target_text_ciphertext,
        target_text_nonce, target_basename_hmac, link_type, position, qualified)
      SELECT $1, $2, s.id, '\\x00'::bytea, '\\x00'::bytea, decode(md5(s.id::text || p), 'hex'),
        'wikilink', p, false
      FROM unnest($3::uuid[]) AS s(id), generate_series(0, 99) AS p
      """,
      [
        Ecto.UUID.dump!(user.id),
        Ecto.UUID.dump!(vault.id),
        Enum.map(notes, &Ecto.UUID.dump!/1)
      ]
    )

    Repo.query!(
      "UPDATE note_links SET qualified = true WHERE id IN " <>
        "(SELECT id FROM note_links WHERE vault_id = $1 ORDER BY id LIMIT $2)",
      [Ecto.UUID.dump!(vault.id), qualified_count]
    )
  end

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    hub = insert(:vault, user: user)
    plain = insert(:vault, user: user)
    seed_links!(user, hub, 5)
    seed_links!(user, plain, 0)

    Repo.query!("ALTER TABLE note_links ALTER COLUMN user_id SET (n_distinct = 40)")
    Repo.query!("ALTER TABLE note_links ALTER COLUMN vault_id SET (n_distinct = 40)")
    QueryPlan.fresh!("note_links")
    %{user: user, hub: hub, plain: plain}
  end

  defp plans(user, sql, params) do
    %{custom: custom, generic: generic} = QueryPlan.rls_plans(user.id, sql, params)
    [custom: custom, generic: generic]
  end

  defp assert_index!(plans, index) do
    for {mode, plan} <- plans do
      assert plan =~ index, "#{mode} plan did not read #{index}:\n#{plan}"
      refute plan =~ "Seq Scan", "#{mode} plan:\n#{plan}"
      refute plan =~ ~r/note_links_user_id_vault_id_\w+_index/, "#{mode} plan:\n#{plan}"
      refute plan =~ "note_links_vault_id_index", "#{mode} plan:\n#{plan}"
    end
  end

  test "the S5 gate reads note_links_qualified, a few buffers, in both plan modes", %{
    user: user,
    hub: hub,
    plain: plain
  } do
    for vault <- [hub, plain] do
      plans = plans(user, @probe, [Ecto.UUID.dump!(user.id), Ecto.UUID.dump!(vault.id)])
      assert_index!(plans, "note_links_qualified")

      for {mode, plan} <- plans do
        IO.puts("plan-proof s5_probe #{mode} buffers=#{QueryPlan.buffers(plan)}")
        assert QueryPlan.buffers(plan) <= 6, "#{mode}:\n#{plan}"
      end
    end
  end

  test "the backfill window probe and write read by primary key only", %{user: user, hub: hub} do
    %{rows: rows} =
      Repo.query!("SELECT id FROM note_links WHERE vault_id = $1 ORDER BY id LIMIT 100", [
        Ecto.UUID.dump!(hub.id)
      ])

    ids = Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)

    {probe_sql, probe_params} = Repo.to_sql(:all, BackfillNoteLinkQualified.stale_query(ids))

    {write_sql, write_params} =
      Repo.to_sql(:update_all, BackfillNoteLinkQualified.write_query(ids, true))

    for {name, sql, params} <- [
          {:probe, probe_sql, probe_params},
          {:write, write_sql, write_params}
        ] do
      plans = plans(user, sql, params)
      assert_index!(plans, "note_links_pkey")

      for {mode, plan} <- plans do
        IO.puts("plan-proof backfill_#{name} #{mode} buffers=#{QueryPlan.buffers(plan)}")
        # One primary-key descent per id (3 levels), never the vault's 3,000 links.
        assert QueryPlan.buffers(plan) <= 4 * length(ids), "#{mode}:\n#{plan}"
      end
    end
  end
end
