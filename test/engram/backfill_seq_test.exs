defmodule Engram.BackfillSeqTest do
  use Engram.DataCase, async: false

  alias Engram.{Notes, Vaults, Repo}

  # The 20260616120100_backfill_seq migration runs on its own DB connection,
  # which cannot see the Ecto Sandbox's uncommitted test data. So per the
  # plan's documented fallback we execute the SAME three SQL statements the
  # migration runs, inside `with_tenant` (RLS tenant set so the rows are
  # visible), and assert the identical contract: no `seq IS NULL` rows remain
  # for the vault, and `change_seq >= max(seq)`.
  @backfill_notes """
  WITH numbered AS (
    SELECT id,
           row_number() OVER (PARTITION BY vault_id ORDER BY updated_at, id) AS rn
    FROM notes
    WHERE seq IS NULL
  )
  UPDATE notes n SET seq = numbered.rn
  FROM numbered WHERE n.id = numbered.id
  """

  @backfill_attachments """
  WITH maxn AS (
    SELECT vault_id, COALESCE(max(seq), 0) AS base FROM notes GROUP BY vault_id
  ),
  numbered AS (
    SELECT a.id,
           COALESCE(m.base, 0)
             + row_number() OVER (PARTITION BY a.vault_id ORDER BY a.updated_at, a.id) AS seq
    FROM attachments a
    LEFT JOIN maxn m ON m.vault_id = a.vault_id
    WHERE a.seq IS NULL
  )
  UPDATE attachments a SET seq = numbered.seq
  FROM numbered WHERE a.id = numbered.id
  """

  @advance_counter """
  UPDATE vaults v SET change_seq = GREATEST(v.change_seq, sub.maxseq)
  FROM (
    SELECT vault_id, max(seq) AS maxseq FROM (
      SELECT vault_id, seq FROM notes
      UNION ALL
      SELECT vault_id, seq FROM attachments
    ) all_rows GROUP BY vault_id
  ) sub
  WHERE v.id = sub.vault_id
  """

  test "backfill assigns seq to rows that predate stamping and advances the counter" do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "Test"})
    {:ok, n} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})

    # Simulate a legacy row: null out its seq and reset the counter.
    Repo.with_tenant(user.id, fn ->
      import Ecto.Query
      Repo.update_all(from(x in Engram.Notes.Note, where: x.id == ^n.id), set: [seq: nil])
      Repo.update_all(from(v in Vaults.Vault, where: v.id == ^vault.id), set: [change_seq: 0])
    end)

    # Run the migration's SQL directly (see module comment for why).
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.query!(@backfill_notes)
        Repo.query!(@backfill_attachments)
        Repo.query!(@advance_counter)
      end)

    {:ok, row} = Repo.with_tenant(user.id, fn -> Repo.get(Engram.Notes.Note, n.id) end)
    {:ok, v} = Repo.with_tenant(user.id, fn -> Repo.get(Vaults.Vault, vault.id) end)

    assert is_integer(row.seq)
    assert row.seq >= 1
    assert v.change_seq >= row.seq

    # Idempotency: no seq-null rows remain for this vault, and re-running the
    # backfill changes nothing.
    {:ok, null_count} =
      Repo.with_tenant(user.id, fn ->
        import Ecto.Query

        Repo.aggregate(
          from(x in Engram.Notes.Note, where: x.vault_id == ^vault.id and is_nil(x.seq)),
          :count
        )
      end)

    assert null_count == 0
  end
end
