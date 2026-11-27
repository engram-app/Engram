# Per-pair checks for .github/workflows/rollback-compat.yml: release J
# (folders stop writing path hashes) rolled back to release I (whose
# ExplicitFolderReconcile clears explicit flags no marker names).
#
# Asserts, both shapes: OLD lists explicit folders from the flag (as prod);
# every explicit row is stamped after NEW's writers; both merges leave one
# stamped survivor; OLD's forced reconcile clears no flag (the snapshot) and
# skips no vault; /folders/explicit and the vault tree equal the seeded set
# with NEW's ids and parents, before and after a rename + delete through OLD.
# prod: no live markers and no unstamped row before NEW; NEW's boot runs no
# ALTER TABLE on folders (20261125100100's early return); NEW's writers run
# with the marker stop on. selfhost: NEW's boot stamp covers OLD's
# unstamped rows (and its FORCE RLS toggle shows the DDL probe works).
#
# Sourced after the workflow's rbc-lib.sh (dc, sql, rpc, val, fail, SHAPE,
# FAULT, API, STATE). The workflow calls each hook at its phase; a later pair
# copies this directory, keeps the hooks it needs and edits the rest.

explicit_ids() {
  sql "SELECT id FROM folders WHERE explicit AND deleted_at IS NULL ORDER BY id"
}

unstamped() {
  sql "SELECT count(*) FROM folders WHERE explicit AND explicit_seq IS NULL AND deleted_at IS NULL"
}

# Phase 1, OLD running: seed marker-era folders, then close OLD's ledgers.
hook_seed_old() {
  python3 e2e/scripts/rollback_compat.py seed-old --api-url "$API" --state "$STATE"
  echo "unstamped explicit rows after OLD's seed: $(unstamped)"
  local out
  out=$(rpc old-ledgers.exs)
  echo "$out"
  [ "$(val LEDGERS_DONE "$out")" = true ] || fail "OLD's ledgers did not close in phase 1"
  [ "$(val EXPLICIT_READS "$out")" = true ] || fail "OLD does not read explicit folders from the flag after phase 1"
  local markers
  markers=$(sql "SELECT count(*) FROM notes WHERE kind = 'folder' AND deleted_at IS NULL")
  echo "live folder markers: $markers"
  if [ "$SHAPE" = prod ]; then
    [ "$markers" -eq 0 ] || fail "prod shape: $markers live folder markers left (folder_marker_delete should have deleted them)"
    # Prod's state before J: folder_marker_delete stamped every marker-era row.
    local n
    n=$(unstamped)
    echo "unstamped explicit rows after OLD's ledgers (prod: FolderMarkerDelete stamps them): $n"
    [ "$n" -eq 0 ] || fail "prod shape: $n explicit rows unstamped after OLD's ledgers closed"
  else
    # Without one, NEW's boot stamp is not exercised.
    [ "$(unstamped)" -ge 1 ] || fail "selfhost shape: OLD left no unstamped explicit row, so NEW's boot stamp is not exercised"
  fi
}

# Phase 1, nothing running: arm a DDL log for NEW's boot. Event triggers fire
# inside DO blocks too; pg_class xmin cannot tell (prepare_database re-GRANTs
# on every boot).
hook_before_new() {
  sql "CREATE TABLE rbc_ddl_log (tag text, obj text);
    CREATE FUNCTION rbc_ddl() RETURNS event_trigger LANGUAGE plpgsql AS \$\$
    DECLARE r record;
    BEGIN
      FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        INSERT INTO rbc_ddl_log VALUES (r.command_tag, r.object_identity);
      END LOOP;
    END \$\$;
    CREATE EVENT TRIGGER rbc_ddl ON ddl_command_end EXECUTE FUNCTION rbc_ddl();"
  # J's 20261125100100 returns early exactly when both ledgers are done.
  echo "ledgers done before NEW boots: $(sql "SELECT string_agg(name, ' ' ORDER BY name) FROM data_migrations WHERE name IN ('explicit_folder_reconcile', 'folder_marker_delete') AND completed_at IS NOT NULL")"
}

# Phase 2, NEW booted: what its boot migrations did, then seed its writers.
hook_after_new_boot() {
  local n alter out
  n=$(unstamped)
  if [ "$SHAPE" = prod ]; then
    echo "unstamped explicit rows after NEW's boot (prod: none before, NEW must not unstamp): $n"
  else
    echo "unstamped explicit rows after NEW's boot (selfhost: NEW's boot stamp ran): $n"
  fi
  [ "$n" -eq 0 ] || fail "NEW's boot left $n explicit rows unstamped"
  sql "SELECT tag || ' ' || coalesce(obj, '-') FROM rbc_ddl_log" | sort | uniq -c | sed 's/^/DDL during NEW boot: /'
  alter=$(sql "SELECT count(*) FROM rbc_ddl_log WHERE tag = 'ALTER TABLE' AND obj = 'public.folders'")
  sql "DROP EVENT TRIGGER rbc_ddl; DROP FUNCTION rbc_ddl(); DROP TABLE rbc_ddl_log"
  out=$(rpc new-probe.exs)
  echo "$out"
  if [ "$SHAPE" = prod ]; then
    [ "$alter" -eq 0 ] || fail "prod shape: NEW's boot ran ALTER TABLE on folders $alter times (its boot migration did not take the early return)"
    [ "$(val MARKER_STOP "$out")" = true ] || fail "prod shape: NEW's writers are not on the marker stop path"
  else
    # The probe itself: the self-host boot does toggle FORCE RLS on folders.
    [ "$alter" -ge 1 ] || fail "selfhost shape: no ALTER TABLE on folders seen during NEW's boot (DDL probe blind?)"
  fi
  python3 e2e/scripts/rollback_compat.py seed-new --api-url "$API" --state "$STATE" --fault "$FAULT"
  # vault-lock needs a stale row too: the walk reports a skipped vault only
  # when that vault holds one (the lock then keeps it from being cleared).
  if [ "$FAULT" != none ]; then
    # The row seed-new created last ("Unstamped"; folder ids are uuidv7).
    sql "UPDATE folders SET explicit_seq = NULL WHERE id = (SELECT id FROM folders WHERE explicit AND deleted_at IS NULL ORDER BY id DESC LIMIT 1) RETURNING id"
  fi
  local left
  left=$(unstamped)
  echo "explicit rows: $(explicit_ids | wc -l), unstamped: $left"
  if [ "$FAULT" != none ]; then
    [ "$left" -eq 1 ] || fail "fault $FAULT: want exactly 1 unstamped row, got $left"
  else
    [ "$left" -eq 0 ] || fail "NEW's writers left $left explicit rows unstamped"
  fi
  # Each merge: the survivor live, explicit and stamped; the other row retired.
  local kind live retired
  for kind in $(python3 -c "import json,sys; print(' '.join(json.load(open(sys.argv[1]))['merges']))" "$STATE"); do
    read -r live retired < <(python3 -c "import json,sys; m=json.load(open(sys.argv[1]))['merges'][sys.argv[2]]; print(m['live'], m['retired'])" "$STATE" "$kind")
    echo "$kind: survivor $(sql "SELECT explicit || ' seq=' || coalesce(explicit_seq::text, 'NULL') || ' deleted=' || (deleted_at IS NOT NULL) FROM folders WHERE id = '$live'"), retired $(sql "SELECT 'deleted=' || (deleted_at IS NOT NULL) FROM folders WHERE id = '$retired'")"
    [ "$(sql "SELECT count(*) FROM folders WHERE id = '$live' AND explicit AND explicit_seq IS NOT NULL AND deleted_at IS NULL")" -eq 1 ] \
      || fail "$kind: survivor $live is not a live, explicit, stamped row"
    [ "$(sql "SELECT count(*) FROM folders WHERE id = '$retired' AND deleted_at IS NOT NULL")" -eq 1 ] \
      || fail "$kind: $retired was not retired, so nothing merged"
  done
}

# Before OLD's rollback boot and after its data migrations: the state the
# workflow diffs (one id per line).
hook_snapshot() { explicit_ids; }

# Phase 3, OLD running, after every OLD data migration ran once: its
# reconcile through the runner's entry point.
hook_old_reconcile() {
  local out result want
  echo "explicit_folder_reconcile ledger before the forced pass: $(sql "SELECT CASE WHEN completed_at IS NULL THEN 'open' ELSE 'closed (re-verify walk)' END FROM data_migrations WHERE name = 'explicit_folder_reconcile'")"
  out=$(rpc old-reconcile.exs)
  echo "$out"
  result=$(val RECONCILE_RESULT "$out")
  # :more with no fault means a row was skipped on a lock, unexamined.
  if [ "$FAULT" = none ]; then want=':done'; else want=':(done|more)'; fi
  grep -qxE "$want" <<<"$result" || fail "OLD's reconcile returned '$result', want $want"
  # On a closed ledger run_pass returns :done even when it skipped a locked
  # vault; the walk logs that instead.
  # Logged by the forced passes, so in the rpc output, not the container log
  # (once per vault per node per day, so the first forced pass carries it).
  local skipped
  skipped=$(grep -c 'vault skipped by the re-verify walk' "$LOGS/rpc-old-rollback.log" || true)
  echo "vaults the re-verify walk skipped: $skipped"
  [ "$skipped" -eq 0 ] || fail "OLD's reconcile skipped $skipped locked vaults, so some rows were never examined"
  # note_folder_hash_null (blocked until phase 1 closed note_payload_stamps)
  # must have walked NEW's notes in this phase: OLD's @reboot runner closes it.
  local nfhn
  nfhn=$(dc logs --no-color engram 2>&1 | grep '"migration":"note_folder_hash_null"' | grep -c '"message":"data migration done"' || true)
  echo "note_folder_hash_null closed by OLD's @reboot walk over NEW's notes: $nfhn"
  [ "$nfhn" -ge 1 ] || fail "note_folder_hash_null did not walk NEW's notes in phase 3"
}

# Phase 3: what OLD's REST serves, then a rename and a delete through it.
hook_verify_old() {
  local out
  out=$(rpc old-probe.exs)
  echo "$out"
  # The listing check only sees a lost flag when OLD lists from the flag.
  [ "$(val EXPLICIT_READS "$out")" = true ] || fail "OLD lists explicit folders from markers, not the flag, so the listing check is blind"
  python3 e2e/scripts/rollback_compat.py verify-old --api-url "$API" --state "$STATE" \
    || fail "OLD's listings after the rollback do not match the seeded folders"
}
