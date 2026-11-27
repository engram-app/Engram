# DDL log for NEW's boot, shared by every pair's hooks.sh. Event triggers fire
# for DDL inside DO blocks too; pg_class xmin cannot tell (prepare_database
# re-GRANTs on every boot). ddl_command_end records what was created or
# altered; sql_drop records what was dropped (ddl_command_end does not).
# Needs sql (rbc-lib.sh). Lines: "<tag> <object>" / "DROP <type> <object>".

ddl_log_arm() {
  sql "CREATE TABLE rbc_ddl_log (tag text, obj text);
    CREATE FUNCTION rbc_ddl() RETURNS event_trigger LANGUAGE plpgsql AS \$\$
    DECLARE r record;
    BEGIN
      FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        INSERT INTO rbc_ddl_log VALUES (r.command_tag, r.object_identity);
      END LOOP;
    END \$\$;
    CREATE FUNCTION rbc_drop() RETURNS event_trigger LANGUAGE plpgsql AS \$\$
    DECLARE r record;
    BEGIN
      FOR r IN SELECT * FROM pg_event_trigger_dropped_objects() WHERE original LOOP
        INSERT INTO rbc_ddl_log VALUES ('DROP ' || r.object_type, r.object_identity);
      END LOOP;
    END \$\$;
    CREATE EVENT TRIGGER rbc_ddl ON ddl_command_end EXECUTE FUNCTION rbc_ddl();
    CREATE EVENT TRIGGER rbc_drop ON sql_drop EXECUTE FUNCTION rbc_drop();" >/dev/null
}

# Prints the log (also to $RUNNER_TEMP/ddl.txt, one "tag obj" per line, the
# boot's GRANT / ALTER DEFAULT PRIVILEGES baseline left out of the file) and
# drops the triggers.
ddl_log_read() {
  sql "SELECT tag || ' ' || coalesce(obj, '-') FROM rbc_ddl_log" | sort | uniq -c | sed 's/^/DDL during NEW boot: /'
  sql "SELECT tag || ' ' || coalesce(obj, '-') FROM rbc_ddl_log WHERE tag NOT IN ('GRANT', 'ALTER DEFAULT PRIVILEGES')" | sort > "$RUNNER_TEMP/ddl.txt"
  sql "DROP EVENT TRIGGER rbc_ddl; DROP EVENT TRIGGER rbc_drop; DROP FUNCTION rbc_ddl(); DROP FUNCTION rbc_drop(); DROP TABLE rbc_ddl_log" >/dev/null
}
