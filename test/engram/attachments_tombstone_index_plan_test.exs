defmodule Engram.AttachmentsTombstoneIndexPlanTest do
  # Guard: the rename link rewrite's old-path recovery for an attachment
  # (`RewriteNoteLinks.tombstone_old_path/4`, `:attachment`) finds the
  # tombstone at a path by index, as its notes twin does
  # (notes_vault_path_tombstone_index). The live path index is partial on
  # `deleted_at IS NULL`, so this lookup read every attachment tombstone of the
  # vault, and none is ever purged.
  use Engram.DataCase, async: true

  alias Engram.QueryPlan

  test "the attachment tombstone lookup by path uses the tombstone path index" do
    user = insert(:user)
    vault = insert(:vault, user: user)

    for n <- 1..300,
        do:
          insert(:attachment,
            user: user,
            vault: vault,
            deleted_at: if(rem(n, 2) == 0, do: DateTime.utc_now(:second))
          )

    sql = """
    SELECT a0."id" FROM "attachments" AS a0
    WHERE a0."user_id" = $1 AND a0."vault_id" = $2 AND a0."path_hmac" = $3
      AND NOT (a0."deleted_at" IS NULL)
    ORDER BY a0."seq" DESC LIMIT 1
    """

    plan = QueryPlan.generic_plan(sql, analyze: ["attachments"], bitmapscan: false)
    assert plan =~ "attachments_vault_path_tombstone_index", plan
  end
end
