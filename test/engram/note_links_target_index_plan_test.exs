defmodule Engram.NoteLinksTargetIndexPlanTest do
  # Guard: lookups of note_links by target note / attachment, including the
  # FKs' ON DELETE SET NULL actions, are served by the partial target indexes.
  #
  # Most links never resolve to an attachment (and many dangle), so a full
  # index on the target columns was mostly NULL keys. The partial
  # `WHERE target_* IS NOT NULL` indexes hold only the resolved edges, and
  # `target_* = $1` implies the predicate (a strict operator rules out NULL),
  # so every lookup by target, generic plan included, can still use them.
  use Engram.DataCase, async: true

  alias Engram.Links.NoteLink
  alias Engram.QueryPlan

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)
    target = insert(:note, user: user, vault: vault)
    attachment = insert(:attachment, user: user, vault: vault)

    for n <- 1..300 do
      source = insert(:note, user: user, vault: vault)

      # A few resolved edges among many dangling ones, as in a real vault.
      {note_id, att_id} =
        case rem(n, 30) do
          0 -> {target.id, nil}
          1 -> {nil, attachment.id}
          _ -> {nil, nil}
        end

      Repo.insert!(
        %NoteLink{
          user_id: user.id,
          vault_id: vault.id,
          source_note_id: source.id,
          target_note_id: note_id,
          target_attachment_id: att_id,
          target_text_ciphertext: "x",
          target_text_nonce: "n",
          target_basename_hmac: :crypto.strong_rand_bytes(32),
          link_type: "wikilink",
          position: 0
        },
        skip_tenant_check: true
      )
    end

    :ok
  end

  defp plan(sql), do: QueryPlan.generic_plan(sql, analyze: ["note_links"], bitmapscan: false)

  test "backlinks by target note use the partial target note index" do
    sql =
      ~s(SELECT id FROM note_links WHERE user_id = $1 AND vault_id = $2 AND target_note_id = $3)

    assert plan(sql) =~ "note_links_target_note_id_index"
  end

  test "the FK actions find their rows by the partial indexes" do
    # The statements RI_FKey_setnull runs when a note or attachment is deleted.
    note_fk = ~s(UPDATE ONLY note_links SET target_note_id = NULL WHERE $1 = target_note_id)
    assert plan(note_fk) =~ "note_links_target_note_id_index"

    att_fk =
      ~s(UPDATE ONLY note_links SET target_attachment_id = NULL WHERE $1 = target_attachment_id)

    assert plan(att_fk) =~ "note_links_target_attachment_id_index"
  end
end
