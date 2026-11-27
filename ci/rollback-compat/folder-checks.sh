# Folder and note checks shared by the pairs whose OLD is release J or later
# (folder-hash-drop, notes-path-expand). Sourced after rbc-lib.sh
# (sql, rpc, val, fail, API, STATE).

# After NEW's seed-new: each merge NEW's writers made leaves its survivor live
# and explicit and the other row retired.
check_merges() {
  local kind live retired kinds
  kinds=$(python3 -c "import json,sys; print(' '.join(json.load(open(sys.argv[1]))['merges']))" "$STATE")
  [ "$kinds" = "merge_restore rename_merge" ] || fail "seed-new recorded merges '$kinds', want merge_restore rename_merge"
  for kind in $kinds; do
    read -r live retired < <(python3 -c "import json,sys; m=json.load(open(sys.argv[1]))['merges'][sys.argv[2]]; print(m['live'], m['retired'])" "$STATE" "$kind")
    [ "$(sql "SELECT count(*) FROM folders WHERE id = '$live' AND explicit AND deleted_at IS NULL")" -eq 1 ] \
      || fail "$kind: survivor $live is not a live explicit row"
    [ "$(sql "SELECT count(*) FROM folders WHERE id = '$retired' AND deleted_at IS NOT NULL")" -eq 1 ] \
      || fail "$kind: $retired was not retired, so nothing merged"
  done
}

# What OLD's data migrations and boot must not change: every live folder's
# parent and explicit flag, every live note's folder and whether it has a
# path hash.
folder_note_snapshot() {
  sql "SELECT 'folder ' || id || ' parent=' || coalesce(parent_id::text, '-') || ' explicit=' || explicit FROM folders WHERE deleted_at IS NULL
       UNION ALL
       SELECT 'note ' || id || ' folder=' || coalesce(folder_ref_id::text, '-') || ' path_hmac=' || (path_hmac IS NOT NULL) FROM notes WHERE deleted_at IS NULL" | sort
}

# Phase 3: OLD lists from the flag, then its REST listings, a rename and a
# delete, its write smoke, and every listed note read back by path. Extra
# args go to verify-old.
verify_old_rest() {
  local out
  out=$(rpc ../explicit-reads-probe.exs)
  echo "$out"
  [ "$(val EXPLICIT_READS "$out")" = true ] || fail "OLD lists explicit folders from markers, not the flag"
  python3 e2e/scripts/rollback_compat.py verify-old --api-url "$API" --state "$STATE" --writes "$@" \
    || fail "OLD's listings or REST smoke after the rollback do not match what NEW served"
}
