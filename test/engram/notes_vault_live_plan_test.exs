defmodule Engram.NotesVaultLivePlanTest do
  # Guard: the index a read of one vault's live notes runs on, when nothing
  # in the statement names a user. Under `engram_app` the tenant policy adds
  # `user_id = <tenant>`, so such a read takes a `(user_id, vault_id, ..)`
  # index. On the maintenance pool (`maintenance_all` is `true`, no user
  # qual) the planner wants a `(vault_id, ..) WHERE deleted_at IS NULL AND
  # kind = 'note'` index. Before 20261125100000 it borrowed
  # `notes_folder_name_live` for that, an index built for a by-name probe
  # (prod 0.87.0: 9,757 scans, while no code names its expression). With it
  # gone the read must land on another vault-bound index (leading `vault_id`,
  # or `user_id, vault_id`; `notes_folder_ref_live` is the expected one),
  # never a scan of the table.
  #
  # Custom (the call's own value) and generic (`PREPARE` under
  # `force_generic_plan`) plans, as each role (`engram_app` under RLS, the
  # tenant set). Tenancy shaped as in `NotesWholeVaultPlanTest`, 40 tenants:
  # `n_distinct = 40` on the tenant columns, pinned before ANALYZE.
  # Not async: the ALTER TABLE locks `notes` until the sandbox rolls back.
  use Engram.DataCase, async: false

  alias Engram.QueryPlan

  @moduletag timeout: 180_000

  @live 400
  @trashed 100
  @other_vaults 10

  @reads [
    count:
      "SELECT count(*) FROM notes WHERE vault_id = $1 AND deleted_at IS NULL AND kind = 'note'",
    page:
      "SELECT id, dek_version FROM notes WHERE vault_id = $1 AND deleted_at IS NULL " <>
        "AND kind = 'note' LIMIT 500",
    vaults:
      "SELECT vault_id, count(*) FROM notes WHERE vault_id = ANY($1::uuid[]) " <>
        "AND deleted_at IS NULL AND kind = 'note' GROUP BY vault_id"
  ]

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)

    row = fn attrs ->
      insert(
        :note,
        [
          user: user,
          vault: vault,
          path_hmac: :crypto.strong_rand_bytes(32),
          basename_hmac: :crypto.strong_rand_bytes(32)
        ] ++ attrs
      )
    end

    for _ <- 1..@live, do: row.([])
    for _ <- 1..@trashed, do: row.(deleted_at: DateTime.utc_now())
    for _ <- 1..@other_vaults, do: copy_vault(vault)

    Repo.query!("ALTER TABLE notes ALTER COLUMN user_id SET (n_distinct = 40)")
    Repo.query!("ALTER TABLE notes ALTER COLUMN vault_id SET (n_distinct = 40)")
    Repo.query!("ANALYZE notes")

    %{user: user, vault: vault, vault_bound: vault_bound_indexes()}
  end

  # The notes indexes whose leading key is `vault_id`, or `user_id` then
  # `vault_id`: a scan of one of them reads one vault, never the table.
  defp vault_bound_indexes do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.relname FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_attribute a0 ON a0.attrelid = i.indrelid AND a0.attnum = i.indkey[0]
      LEFT JOIN pg_attribute a1 ON a1.attrelid = i.indrelid AND a1.attnum = i.indkey[1]
      WHERE i.indrelid = 'notes'::regclass
        AND (a0.attname = 'vault_id' OR (a0.attname = 'user_id' AND a1.attname = 'vault_id'))
      """)

    MapSet.new(List.flatten(rows))
  end

  defp copy_vault(vault) do
    other = insert(:user)
    to = insert(:vault, user: other)

    %{rows: cols} =
      Repo.query!("""
      SELECT quote_ident(column_name) FROM information_schema.columns
      WHERE table_name = 'notes' AND is_generated = 'NEVER'
        AND column_name NOT IN ('id', 'user_id', 'vault_id', 'folder_ref_id')
      """)

    cols = Enum.map_join(cols, ", ", &hd/1)

    Repo.query!(
      "INSERT INTO notes (id, user_id, vault_id, #{cols}) " <>
        "SELECT gen_random_uuid(), $1, $2, #{cols} FROM notes WHERE vault_id = $3",
      [Ecto.UUID.dump!(other.id), Ecto.UUID.dump!(to.id), Ecto.UUID.dump!(vault.id)]
    )
  end

  # The custom plan as `role` (tenant set for `engram_app`), seq scans off:
  # a Seq Scan left in the plan means no index can serve it.
  defp custom_plan(sql, param, role, user_id) do
    {:ok, plan} =
      Repo.transaction(fn ->
        Repo.query!("SAVEPOINT vault_live_plan")

        try do
          Repo.query!("SET LOCAL ROLE #{role}")
          Repo.query!("SELECT set_config('app.current_tenant', $1, true)", [user_id])
          Repo.query!("SET LOCAL enable_seqscan = off")
          Repo.query!("EXPLAIN " <> sql, [param]).rows |> List.flatten() |> Enum.join("\n")
        after
          Repo.query!("ROLLBACK TO SAVEPOINT vault_live_plan")
          Repo.query!("RELEASE SAVEPOINT vault_live_plan")
        end
      end)

    plan
  end

  defp param(:vaults, vault), do: [Ecto.UUID.dump!(vault.id)]
  defp param(_read, vault), do: Ecto.UUID.dump!(vault.id)

  for role <- ["engram_maintenance", "engram_app"], {read, _sql} <- @reads do
    test "#{role}: the #{read} read stays on a vault-scoped index",
         %{user: u, vault: v, vault_bound: bound} do
      sql = Keyword.fetch!(@reads, unquote(read))

      custom = custom_plan(sql, param(unquote(read), v), unquote(role), u.id)
      generic = QueryPlan.generic_plan(sql, role: unquote(role), seqscan: false)

      for plan <- [custom, generic] do
        refute plan =~ "notes_folder_name_live", plan
        refute plan =~ "Seq Scan on notes", plan

        used =
          Regex.scan(~r/(?:Index (?:Only )?Scan using|Bitmap Index Scan on) (notes\w*)/, plan,
            capture: :all_but_first
          )
          |> List.flatten()

        assert used != [], plan
        assert Enum.all?(used, &MapSet.member?(bound, &1)), plan
      end
    end
  end
end
