defmodule Engram.Insights.SnapshotNotesPassTest do
  @moduledoc """
  The daily snapshot's per-vault folder and tag counts come from ONE pass
  over `notes`. Before, the scan statement held two `notes` subqueries (one
  for distinct folders, one for distinct tags), so each 500-vault chunk read
  the `notes` heap twice (prod 2026-11-05 00:40Z: ~880 MB read by the
  maintenance backend, a swap spike on the 4 GB RDS box).
  """
  use Engram.DataCase, async: false

  alias Engram.DataMigrations
  alias Engram.DataMigrations.NoteSizes
  alias Engram.FolderRows
  alias Engram.Insights.Snapshot
  alias Engram.Insights.VaultDailyMetric
  alias Engram.Notes
  alias Engram.QueryPlan
  alias Engram.QueryRecorder

  defp h, do: :crypto.strong_rand_bytes(32)

  # A folder marker's shape (`notes_kind_shape_check`).
  @marker [
    kind: "folder",
    path_hmac: nil,
    content_ciphertext: nil,
    title_ciphertext: nil,
    tags_ciphertext: nil
  ]

  # Every case the two old subqueries told apart: live vs deleted, notes vs
  # folder markers, empty and repeated tags, an empty vault.
  defp fixtures do
    user = insert(:user)
    [f1, f2, f3, f4, t1, t2, t3] = for _ <- 1..7, do: h()

    rich = insert(:vault, user: user)
    # Each note folder has its row and the note its reference, as a writer
    # sets it (the count reads references, not hashes).
    [r1, r2, r4] =
      for f <- [f1, f2, f4], do: FolderRows.insert!(user, rich, h(), full_path_hmac: f)

    note = &insert(:note, Keyword.merge([user: user, vault: rich], &1))
    note.(folder_hmac: f1, folder_ref_id: r1, tags_hmac: [t1, t2])
    note.(folder_hmac: f1, folder_ref_id: r1, tags_hmac: [t2])
    note.(folder_hmac: f4, folder_ref_id: r4, tags_hmac: [t3, t3])
    note.(folder_hmac: f2, folder_ref_id: r2, tags_hmac: [])
    # A folder marker counts as a folder; its tags never count.
    note.(@marker ++ [folder_hmac: f3, tags_hmac: [h()]])
    # Deleted rows count for neither.
    note.(folder_hmac: h(), tags_hmac: [h()], deleted_at: DateTime.utc_now())

    untagged = insert(:vault, user: user)
    u2 = FolderRows.insert!(user, untagged, h(), full_path_hmac: f2)
    insert(:note, user: user, vault: untagged, folder_hmac: f2, folder_ref_id: u2, tags_hmac: [])

    markers_only = insert(:vault, user: user)
    insert(:note, @marker ++ [user: user, vault: markers_only, folder_hmac: f1, tags_hmac: []])

    empty = insert(:vault, user: user)
    [rich, untagged, markers_only, empty]
  end

  # The pre-change queries, verbatim in shape: the reference the new single
  # pass must match.
  defp reference(vault_ids) do
    ids = Enum.map(vault_ids, &Ecto.UUID.dump!/1)

    %{rows: folders} =
      Repo.query!(
        """
        SELECT vault_id, count(DISTINCT folder_hmac) FROM notes
        WHERE vault_id = ANY($1) AND deleted_at IS NULL AND folder_hmac IS NOT NULL
        GROUP BY vault_id
        """,
        [ids]
      )

    %{rows: tags} =
      Repo.query!(
        """
        SELECT vault_id, count(DISTINCT tag) FROM (
          SELECT vault_id, unnest(tags_hmac) AS tag FROM notes
          WHERE vault_id = ANY($1) AND deleted_at IS NULL AND kind = 'note'
        ) t GROUP BY vault_id
        """,
        [ids]
      )

    f = Map.new(folders, fn [id, n] -> {Ecto.UUID.load!(id), n} end)
    t = Map.new(tags, fn [id, n] -> {Ecto.UUID.load!(id), n} end)
    Map.new(vault_ids, &{&1, {Map.get(f, &1, 0), Map.get(t, &1, 0)}})
  end

  test "folder and tag counts equal the old two-query result" do
    vaults = fixtures()
    ids = Enum.map(vaults, & &1.id)
    day = Date.add(Date.utc_today(), -1)

    Snapshot.run(day: day)

    got =
      Map.new(ids, fn id ->
        m = Repo.get_by!(VaultDailyMetric, vault_id: id, date: day)
        {id, {m.folders, m.tags}}
      end)

    assert got == reference(ids)
    # Pinned too, so a reference that drifted with the code cannot pass.
    assert Enum.map(ids, &got[&1]) == [{4, 3}, {1, 0}, {1, 0}, {0, 0}]
  end

  # R9: a note's folder is its folder ROW (`folder_ref_id`), not its folder
  # hash, which notes stop carrying. Red before: every note below holds the
  # same (stale) hash, so a count of distinct hashes says 3 (that hash and
  # the two markers'); the rows say A, B, Empty and the root.
  test "folders count folder rows, not note folder hashes" do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)

    for path <- ["A/x.md", "A/y.md", "B/z.md", "root.md"] do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => path, "content" => "x", "mtime" => 1.0},
          actor: "api"
        )
    end

    # A marker on a folder that has notes is the same folder; an empty one is
    # one more.
    {:ok, _} = Notes.create_folder_marker(user, vault, "A")
    {:ok, _} = Notes.create_folder_marker(user, vault, "Empty")

    # Triggers off: only the hash changes (no derived key, no reference).
    Repo.query!("SET LOCAL session_replication_role = replica")

    Repo.query!("UPDATE notes SET folder_hmac = $1 WHERE vault_id = $2 AND kind = 'note'", [
      h(),
      Ecto.UUID.dump!(vault.id)
    ])

    Repo.query!("SET LOCAL session_replication_role = origin")

    day = Date.add(Date.utc_today(), -1)
    Snapshot.run(day: day)

    assert Repo.get_by!(VaultDailyMetric, vault_id: vault.id, date: day).folders == 4
  end

  # Red before: the statement planned two scans of `notes`, one per subquery.
  test "the vault scan reads notes once" do
    fixtures()
    # Sizes from the narrow state rows, so `notes` is read for folders and
    # tags only (the wide size path is the pre-ledger fallback).
    DataMigrations.mark_done(NoteSizes.name(), NoteSizes.version())

    {_, queries} = QueryRecorder.record(fn -> Snapshot.run() end)
    me = self()

    %{sql: sql} =
      Enum.find(queries, &(&1.pid == me and &1.sql =~ "unnest")) ||
        flunk("no vault scan statement recorded")

    plan = QueryPlan.generic_plan(sql, seqscan: true, analyze: ["notes"], fresh: true)
    scans = Regex.scan(~r/ on notes\b/, plan)

    assert length(scans) == 1, "expected one scan of notes, got:\n" <> plan
  end
end
