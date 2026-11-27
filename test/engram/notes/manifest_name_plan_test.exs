defmodule Engram.Notes.ManifestNamePlanTest do
  # Release L builds `notes_manifest_name` so a later release can serve
  # `GET /sync/manifest` from names instead of stored paths. This pins that
  # the manifest's notes read in that shape (every column it would select:
  # the name, its stamp and both anchoring nonces, the folder row, the body
  # fields) is an index-only scan of it, as prod runs it: `engram_app` under
  # FORCE RLS with the tenant set, custom and forced generic plan
  # (`QueryPlan.rls_plans/4`), on all-visible pages (prod's cold rows are).
  use Engram.DataCase, async: false

  alias Engram.QueryPlan

  @sql """
  SELECT n.id, uuid_send(n.id), n.dek_version, n.seq, n.content_hash, n.folder_ref_id,
         n.name_ciphertext, n.name_nonce, n.name_stamp, n.path_nonce
  FROM notes AS n
  WHERE n.user_id = $1 AND n.vault_id = $2 AND n.deleted_at IS NULL AND n.kind = 'note'
  """

  test "the manifest's name read is index-only on notes_manifest_name under RLS" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    for _ <- 1..300, do: insert(:note, user: user, vault: vault)
    # Other tenants' and trashed rows the index's key and predicate skip.
    other = insert(:user)
    for _ <- 1..100, do: insert(:note, user: other, vault: insert(:vault, user: other))
    for _ <- 1..50, do: insert(:note, user: user, vault: vault, deleted_at: DateTime.utc_now())

    Repo.query!("REINDEX TABLE notes")
    Repo.query!("ANALYZE notes")
    QueryPlan.all_visible!(["notes"])

    plans =
      QueryPlan.rls_plans(user.id, @sql, [Ecto.UUID.dump!(user.id), Ecto.UUID.dump!(vault.id)])

    for {kind, plan} <- plans do
      assert plan =~ "Index Only Scan using notes_manifest_name on notes", "#{kind}:\n#{plan}"
      refute plan =~ ~r/(Seq|Bitmap Heap) Scan on notes\b/, "#{kind}:\n#{plan}"
      assert plan =~ ~r/actual rows=300(\.00)? /, "#{kind}:\n#{plan}"
    end
  end
end
