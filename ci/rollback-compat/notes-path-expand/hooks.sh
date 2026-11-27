# Per-pair checks for .github/workflows/rollback-compat.yml: release L (the
# expand step of retiring notes.path_*, Engram.Release.NotesPathExpand: the
# v5 shape CHECK replaces v4, the partial manifest index notes_manifest_name,
# the name unique index shipped OFF, plus the keyword feed tables) rolled
# back to release K.
#
# Asserts, both shapes: after L's boot and again after K's phase 3, the v5
# CHECK exists and is valid, v4 is gone, notes_manifest_name exists and is
# valid, notes_name_live does not exist; L's only drop is the v4 constraint;
# the L boot-step ledgers K finds are exactly as L left them after K's boot
# and passes (K does not know their names); every K data migration gets a
# verdict; K lists, reads every listed note back by path, renames and deletes
# a folder, creates a folder, writes, reads and renames a note and finds it
# through MCP, keeping L's ids and parents. K's writes satisfy v5 (the CHECK
# would refuse them otherwise).
# Fault path-hash-null: one live note L wrote gets path_hmac NULL, which v5
# allows when the note has a name address (what a later release may write).
# K's read-back by path must go red on it.
#
# Sourced after rbc-lib.sh, ddl-log.sh and folder-checks.sh.

l_steps="'notes_shape_relax', 'notes_name_unique_build', 'notes_manifest_name_build', 'folder_path_hash_drop'"

# The L schema state K must find and keep. $1 names the moment.
l_schema() {
  local v5 v4 man uniq
  v5=$(sql "SELECT coalesce((SELECT convalidated::text FROM pg_constraint WHERE conrelid = 'public.notes'::regclass AND conname = 'notes_kind_shape_v5_check'), 'absent')")
  v4=$(sql "SELECT count(*) FROM pg_constraint WHERE conrelid = 'public.notes'::regclass AND conname = 'notes_kind_shape_v4_check'")
  man=$(sql "SELECT coalesce((SELECT i.indisvalid::text FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = 'notes_manifest_name'), 'absent')")
  uniq=$(sql "SELECT count(*) FROM pg_class WHERE relname = 'notes_name_live' AND relkind = 'i'")
  echo "$1: v5 check valid=$v5, v4 check present=$v4, notes_manifest_name valid=$man, notes_name_live present=$uniq"
  [ "$v5" = true ] || fail "$1: notes_kind_shape_v5_check is $v5, want a valid constraint"
  [ "$v4" -eq 0 ] || fail "$1: notes_kind_shape_v4_check is still there"
  [ "$man" = true ] || fail "$1: notes_manifest_name is $man, want a valid index"
  [ "$uniq" -eq 0 ] || fail "$1: notes_name_live exists, but its step ships off"
}

l_ledgers() {
  sql "SELECT name || ' v' || version || ' ' || coalesce(completed_at::text, 'open') FROM data_migrations WHERE name IN ($l_steps) ORDER BY name"
}

# Phase 1, OLD (K) running: close FolderTable, then seed through K's writers.
hook_seed_old() {
  local out markers
  out=$(rpc ../folder-table-ledgers.exs)
  echo "$out"
  [ "$(val LEDGERS_DONE "$out")" = true ] || fail "K's folder_table ledger did not close in phase 1"
  [ "$(val EXPLICIT_READS "$out")" = true ] || fail "K does not read explicit folders from the flag after phase 1"
  [ "$(val MARKER_STOP "$out")" = true ] || fail "K's writers are not on the marker stop path"
  python3 e2e/scripts/rollback_compat.py seed-old --api-url "$API" --state "$STATE" --with-notes
  markers=$(sql "SELECT count(*) FROM notes WHERE kind = 'folder' AND deleted_at IS NULL")
  [ "$markers" -eq 0 ] || fail "K wrote $markers folder markers (marker stop off?)"
}

hook_before_new() { ddl_log_arm; }

# Phase 2, NEW (L) booted: its schema, its ledgers, then L's writers.
hook_after_new_boot() {
  ddl_log_read
  # L creates and alters freely (keyword tables, the v5 CHECK, the manifest
  # index); the only thing it may drop is the v4 shape CHECK it replaces.
  grep '^DROP ' "$RUNNER_TEMP/ddl.txt" > "$RUNNER_TEMP/ddl-drops.txt" || true
  [ "$(wc -l < "$RUNNER_TEMP/ddl-drops.txt")" -eq 1 ] && grep -q 'notes_kind_shape_v4_check' "$RUNNER_TEMP/ddl-drops.txt" \
    || fail "L's boot dropped something other than (or besides) the v4 shape CHECK: $(tr '\n' ';' < "$RUNNER_TEMP/ddl-drops.txt")"
  l_schema "after L's boot"
  l_ledgers | tee "$RUNNER_TEMP/l-ledgers.txt" | sed 's/^/L boot-step ledger: /'
  grep -q '^notes_shape_relax v1 2' "$RUNNER_TEMP/l-ledgers.txt" || fail "L's notes_shape_relax step is not done"
  grep -q '^notes_manifest_name_build v1 2' "$RUNNER_TEMP/l-ledgers.txt" || fail "L's notes_manifest_name_build step is not done"
  python3 e2e/scripts/rollback_compat.py seed-new --api-url "$API" --state "$STATE" --fault none
  check_merges
  if [ "$FAULT" = path-hash-null ]; then
    # The newest live note with a name address: v5 lets it lose its path hash.
    sql "UPDATE notes SET path_hmac = NULL WHERE id = (SELECT id FROM notes WHERE kind = 'note' AND deleted_at IS NULL AND name_hmac IS NOT NULL AND folder_ref_id IS NOT NULL ORDER BY id DESC LIMIT 1) RETURNING 'fault path-hash-null: path_hmac NULL on note ' || id"
  fi
}

hook_snapshot() { folder_note_snapshot; }

# Phase 3, OLD (K) running, after every K data migration ran once.
hook_old_checks() {
  l_schema "after K's rollback passes"
  l_ledgers > "$RUNNER_TEMP/l-ledgers-after.txt"
  diff "$RUNNER_TEMP/l-ledgers.txt" "$RUNNER_TEMP/l-ledgers-after.txt" \
    || fail "K changed L's boot-step ledgers (diff above: < after L, > after K)"
}

# Phase 3: what K's REST serves, every listed note read back by path, then
# its writes.
hook_verify_old() { verify_old_rest --read-notes; }
