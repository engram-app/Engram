defmodule Engram.NotesWholeVaultPlanTest do
  # Guard: the index each whole-vault read and each read by a list of ids
  # runs on, on its 7th execution (past the 5 custom plans Postgres tries
  # before it may switch a named statement to a GENERIC plan).
  #
  # Whole-vault live reads that do not state `kind = 'note'` (folder counts,
  # tag counts, the folder cascade's unresolved rows) read
  # `notes_user_vault_live (user_id, vault_id) WHERE deleted_at IS NULL`. Before it they
  # borrowed `notes_user_id_vault_id_basename_hmac_index`, the only other
  # live-only `(.., vault_id, ..)` index (prod 2026-11-02: 277 scans/h).
  #
  # Reads by a list of note ids fetch each id by primary key
  # (`Engram.Backfill.IdWindows.by_id/2`). As `id = ANY(ids)` beside the
  # vault filter they walked the whole vault on a vault-leading index once
  # the list held more than a handful of ids (staging, 200 ids:
  # `notes_recent_index`, filtering `id`).
  #
  # Each test asserts the custom plan (the call's own values) and the
  # generic plan (`EXPLAIN (GENERIC_PLAN)`), so the plan is right whichever
  # one the statement runs on. The tenancy shape is set as
  # `NotesGenericPlanTest` sets it: `n_distinct = 40`, so the planner sees
  # many vaults and this one as a fraction of the table. Not async: the
  # ALTER TABLE locks `notes` until the sandbox rolls back.
  use Engram.DataCase, async: false

  alias Engram.Cache
  alias Engram.DataMigrations
  alias Engram.FieldCatalogHelpers
  alias Engram.Notes
  alias Engram.Notes.FieldCatalog
  alias Engram.QueryPlan

  @moduletag timeout: 180_000

  @filler 400
  @trashed 100
  @real 20
  # Other tenants' vaults, each a copy of the big vault's filler: the table
  # is many vaults, as prod's is, not this one.
  @other_vaults 10

  setup do
    on_exit(fn ->
      Cache.clear_local(:note_split)
      DataMigrations.reset_cache()
    end)

    # Prod's key path (note_split done): lookups by id columns.
    :ok = DataMigrations.mark_done("note_split", 1)
    Cache.clear_local(:note_split)

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, fk} = Engram.Crypto.dek_filter_key(user)
    # Root notes: the folder cascade decrypts only rows it cannot place.
    root = Engram.Crypto.hmac_field(fk, "")
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Big", Ecto.UUID.generate())

    real =
      for i <- 1..@real do
        {:ok, note} =
          Notes.upsert_note(
            user,
            vault,
            %{"path" => "F/n#{i}.md", "content" => "---\ntags: [a]\n---\nx"},
            actor: "api"
          )

        note
      end

    _ = FieldCatalogHelpers.write_indexed!(user, vault, "T.md", "---\nstatus: draft\n---\nbody")

    filler = fn attrs ->
      insert(
        :note,
        [
          user: user,
          vault: vault,
          path_hmac: :crypto.strong_rand_bytes(32),
          folder_hmac: root,
          basename_hmac: :crypto.strong_rand_bytes(32)
        ] ++ attrs
      )
    end

    for _ <- 1..@filler, do: filler.([])
    for _ <- 1..@trashed, do: filler.(deleted_at: DateTime.utc_now())
    for _ <- 1..@other_vaults, do: copy_vault(vault)

    Repo.query!("ALTER TABLE notes ALTER COLUMN user_id SET (n_distinct = 40)")
    Repo.query!("ALTER TABLE notes ALTER COLUMN vault_id SET (n_distinct = 40)")
    Repo.query!("ANALYZE notes")

    %{user: user, vault: vault, ids: Enum.map(real, & &1.id)}
  end

  # The vault's rows again under another user and vault, in one statement.
  defp copy_vault(vault) do
    other = insert(:user)
    to = insert(:vault, user: other)

    %{rows: cols} =
      Repo.query!("""
      SELECT quote_ident(column_name) FROM information_schema.columns
      WHERE table_name = 'notes' AND is_generated = 'NEVER'
        AND column_name NOT IN ('id', 'user_id', 'vault_id')
      """)

    cols = Enum.map_join(cols, ", ", &hd/1)

    Repo.query!(
      "INSERT INTO notes (id, user_id, vault_id, #{cols}) " <>
        "SELECT gen_random_uuid(), $1, $2, #{cols} FROM notes WHERE vault_id = $3",
      [Ecto.UUID.dump!(other.id), Ecto.UUID.dump!(to.id), Ecto.UUID.dump!(vault.id)]
    )
  end

  # The vault's live rows from `notes_user_vault_live`, nowhere else.
  defp assert_vault_live(%{custom: custom, generic: generic}) do
    for plan <- [custom, generic] do
      assert plan =~ "notes_user_vault_live", plan
      refute plan =~ "basename_hmac_index", plan
      refute plan =~ "Seq Scan on notes", plan
    end
  end

  # Every notes row by primary key: no vault- or user-leading index walk.
  defp assert_pkey_only(%{custom: custom, generic: generic}) do
    for plan <- [custom, generic] do
      assert plan =~ "notes_pkey", plan
      refute plan =~ ~r/Scan using (?!notes_pkey\b)\S+ on notes\b/, plan
      refute plan =~ ~r/Bitmap Index Scan on (?!notes_pkey\b)(idx_)?notes/, plan
      refute plan =~ "Seq Scan on notes", plan
    end
  end

  defp uncached(fun) do
    fn ->
      Cache.clear_local(:vault_scan)
      Cache.clear_local(:field_catalog)
      fun.()
    end
  end

  test "folder counts read notes_user_vault_live", %{user: u, vault: v} do
    plans =
      QueryPlan.after_runs(
        fn -> Repo.with_tenant!(u.id, fn -> Notes.raw_folder_count_rows(u, v) end) end,
        ~r/GROUP BY n0\."folder_ref_id", n0\."folder_hmac"/
      )

    assert_vault_live(plans)
  end

  test "tag counts read notes_user_vault_live", %{user: u, vault: v} do
    plans =
      QueryPlan.after_runs(
        uncached(fn -> {:ok, _} = Notes.list_tags_with_counts(u, v) end),
        ~r/GROUP BY n0\."tags_hmac"/
      )

    assert_vault_live(plans)
  end

  test "the folder cascade's unresolved rows read notes_user_vault_live", %{user: u, vault: v} do
    plans =
      QueryPlan.after_runs(
        fn -> {:ok, _} = Notes.scan_folders(u, v, ["F"]) end,
        ~r/GROUP BY n0\."folder_hmac"/
      )

    assert_vault_live(plans)
  end

  test "get_note_meta_by_ids fetches each id by primary key", %{user: u, vault: v, ids: ids} do
    plans =
      QueryPlan.after_runs(
        fn ->
          {:ok, found} = Notes.get_note_meta_by_ids(u, v, ids)
          assert map_size(found) == @real
        end,
        ~r/FROM "notes"/
      )

    assert_pkey_only(plans)
  end

  test "get_note_meta_by_ids still drops trashed, foreign and malformed ids", ctx do
    %{user: u, vault: v, ids: [keep, gone | _]} = ctx
    :ok = Notes.delete_note(u, v, "F/n2.md")
    other = insert(:note, user: u, vault: insert(:vault, user: u))

    {:ok, found} = Notes.get_note_meta_by_ids(u, v, [keep, gone, other.id, "nope", keep])
    assert Map.keys(found) == [keep]
  end

  test "the field catalog reads its sample notes by primary key", %{user: u, vault: v} do
    plans =
      QueryPlan.after_runs(
        uncached(fn -> {:ok, [_ | _]} = FieldCatalog.list(u, v) end),
        ~r/"notes" AS s?n0 LEFT OUTER JOIN "note_bodies"/
      )

    assert_pkey_only(plans)
  end

  # The new index must not take a key lookup's place: on a path lookup it is
  # a 16-byte vault walk next to the path's own index.
  test "a path lookup still reads notes_path_live", %{user: u, vault: v} do
    %{custom: custom} =
      QueryPlan.after_runs(
        fn -> assert Notes.note_exists?(u, v, "F/n1.md") end,
        ~r/"path_id" = \$/
      )

    assert custom =~ "notes_path_live", custom
  end
end
