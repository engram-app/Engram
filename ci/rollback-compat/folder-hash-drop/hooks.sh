# Per-pair checks for .github/workflows/rollback-compat.yml: release K
# (drops folders.full_path_hmac and its folders_full_path index, through
# Engram.Release.FolderHashDrop after the migrations) rolled back to release J
# (which stopped every read and write of both).
#
# Asserts, both shapes: J lists explicit folders from the flag and writes no
# markers (FolderTable closed first); K's boot runs exactly that DDL (one
# ALTER TABLE on folders, the column and the index dropped, nothing else) and
# closes the folder_path_hash_drop ledger; afterwards the column and index are
# gone; J, rolled back onto K's schema, reads the column only to fail with
# undefined_column, keeps every folder's id, parent, explicit flag and every
# note's folder (the snapshot), and lists /folders/explicit and the vault tree
# with K's ids and parents before and after a rename + delete through J,
# then J creates a folder, writes and reads a note, and finds it through MCP
# list_folder and search_notes.
# Fault hash-read: J's process reading the column crashes, and the workflow's
# error scan must go red on it.
#
# Sourced after rbc-lib.sh, ddl-log.sh and folder-checks.sh (dc, sql, rpc, val, fail, SHAPE,
# FAULT, API, STATE).

# Phase 1, OLD (J) running: close FolderTable, then seed through J's writers.
hook_seed_old() {
  local out markers
  out=$(rpc ../folder-table-ledgers.exs)
  echo "$out"
  [ "$(val LEDGERS_DONE "$out")" = true ] || fail "J's folder_table ledger did not close in phase 1"
  [ "$(val EXPLICIT_READS "$out")" = true ] || fail "J does not read explicit folders from the flag after phase 1"
  [ "$(val MARKER_STOP "$out")" = true ] || fail "J's writers are not on the marker stop path"
  # Explicit folders (root and nested) and notes (root, nested, deep).
  python3 e2e/scripts/rollback_compat.py seed-old --api-url "$API" --state "$STATE" --with-notes
  markers=$(sql "SELECT count(*) FROM notes WHERE kind = 'folder' AND deleted_at IS NULL")
  echo "live folder markers after J's seed: $markers"
  [ "$markers" -eq 0 ] || fail "J wrote $markers folder markers (marker stop off?)"
  echo "folders with a full_path_hmac before K: $(sql "SELECT count(*) FROM folders WHERE full_path_hmac IS NOT NULL")"
}

hook_before_new() { ddl_log_arm; }

# Phase 2, NEW (K) booted: its DDL and ledger, then K's writers.
hook_after_new_boot() {
  ddl_log_read
  # The boot's own baseline counted too: prepare_database's 4 ALTER DEFAULT
  # PRIVILEGES and 5 GRANTs (an extra GRANT from K would show here).
  { printf '%s\n' 'ALTER TABLE public.folders' 'DROP index public.folders_full_path' \
      'DROP table column public.folders.full_path_hmac'
    for _ in 1 2 3 4; do echo 'ALTER DEFAULT PRIVILEGES -'; done
    for _ in 1 2 3 4 5; do echo 'GRANT -'; done; } | sort > "$RUNNER_TEMP/ddl-want.txt"
  diff "$RUNNER_TEMP/ddl-want.txt" "$RUNNER_TEMP/ddl.txt" \
    || fail "K's boot DDL is not exactly the folder hash drop (diff above: < want, > got)"
  [ "$(sql "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'folders' AND column_name = 'full_path_hmac'")" -eq 0 ] \
    || fail "folders.full_path_hmac still exists after K's boot"
  [ "$(sql "SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'folders_full_path'")" -eq 0 ] \
    || fail "folders_full_path still exists after K's boot"
  local ledger
  ledger=$(sql "SELECT count(*) FROM data_migrations WHERE name = 'folder_path_hash_drop' AND completed_at IS NOT NULL")
  echo "folder_path_hash_drop ledger done: $ledger"
  [ "$ledger" -eq 1 ] || fail "K's folder_path_hash_drop ledger is not done"
  python3 e2e/scripts/rollback_compat.py seed-new --api-url "$API" --state "$STATE" --fault none
  check_merges
}

hook_snapshot() { folder_note_snapshot; }

# Phase 3, OLD (J) running, after every J data migration ran once.
hook_old_checks() {
  local out
  out=$(rpc hash-read.exs)
  echo "$out"
  if [ "$FAULT" = hash-read ]; then
    [ "$(val HASH_READ_PROCESS "$out")" = crashed ] || fail "fault hash-read: J's read of the dropped column did not crash"
  else
    [ "$(val HASH_READ "$out")" = undefined_column ] || fail "J's read of folders.full_path_hmac returned '$(val HASH_READ "$out")', want undefined_column (the column is gone)"
  fi
}

# Phase 3: what J's REST serves, then a rename and a delete through it.
hook_verify_old() { verify_old_rest; }
