#!/usr/bin/env bash
#
# Ecto's --log-migrations-sql output (stdin) to plain SQL (stdout), for
# squawk (priv/repo/lint_migrations.sh). The clean SQL lines have no
# timestamp prefix; each statement ends with Ecto's logged parameter list:
# ` []` inline or a lone `[]` line for none, ` [<params>]` for a query with
# bind parameters (`SELECT ... = $1 ["notes"]`). The list is stripped and the
# statement terminated; `$1` stays, squawk parses it. A SQL line that itself
# ends in ` [...]` would be cut: Postgres DDL does not write that.
#
# The greps are `|| true`: a migration that renders nothing (data-only,
# no-op) makes grep exit 1, which pipefail would turn into a silent script
# exit before the caller's "rendered no SQL" branch.
#
# Tested by test/scripts/render_migration_sql_test.sh.
set -euo pipefail

{ grep -vE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' || true; } |
  { grep -vE '^\s*$' || true; } |
  awk '{ t=$0; sub(/[ \t]+$/,"",t);
         if (t=="[]") { if(buf!=""){print buf ";"; buf=""} }
         else if (t ~ / \[.*\]$/) { sub(/ \[.*\]$/,"",t); buf=(buf==""?t:buf"\n"t); print buf ";"; buf="" }
         else { buf=(buf==""?t:buf"\n"t) } }
     END { if (buf!="") print buf ";" }'
