defmodule Engram.ExtendedStatisticsTest do
  # A vault belongs to one user, so `user_id = $u AND vault_id = $v` is as
  # selective as `vault_id = $v` alone. Without extended statistics the
  # planner multiplies the two selectivities and expects a fraction of a
  # vault's rows (every scoped query states both), which steers it to nested
  # loops and the wrong index on large vaults. CREATE STATISTICS
  # (dependencies, ndistinct) teaches it the dependency.
  use Engram.DataCase, async: false

  @tables ~w(notes attachments note_links chunks)

  test "every vault-scoped table carries (user_id, vault_id) statistics" do
    for t <- @tables do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT s.stxkind::text[] FROM pg_statistic_ext s
          WHERE s.stxrelid = $1::text::regclass
            AND (SELECT array_agg(a.attname::text ORDER BY a.attname)
                 FROM pg_attribute a
                 WHERE a.attrelid = s.stxrelid AND a.attnum = ANY(s.stxkeys)) = ARRAY['user_id', 'vault_id']
          """,
          [t]
        )

      assert [[kinds]] = rows, "#{t} has no (user_id, vault_id) statistics"
      assert "d" in kinds and "f" in kinds
    end
  end

  test "the planner estimates a vault's notes, not a fraction of them" do
    vaults =
      for _ <- 1..10 do
        user = insert(:user)
        for _ <- 1..2, do: {user, insert(:vault, user: user)}
      end
      |> List.flatten()

    for {user, vault} <- vaults, _ <- 1..20, do: insert(:note, user: user, vault: vault)
    Repo.query!("ANALYZE notes")

    {user, vault} = hd(vaults)

    %{rows: [[plan] | _]} =
      Repo.query!(
        "EXPLAIN SELECT 1 FROM notes WHERE user_id = '#{user.id}' AND vault_id = '#{vault.id}'"
      )

    [_, rows] = Regex.run(~r/rows=(\d+)/, plan)
    # 20 real rows. Multiplying user (1/10) by vault (1/20) over 400 gives 2.
    assert String.to_integer(rows) >= 10, plan
  end
end
