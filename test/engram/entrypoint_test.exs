defmodule Engram.EntrypointTest do
  @moduledoc """
  Pins the two-login split in `entrypoint.sh`.

  The container runs two kinds of work against Postgres with opposite
  privilege needs:

    * bootstrap + migrations need CREATEROLE, GRANT and DDL
    * the app pool needs a RESTRICTED role, or row-level security never
      applies to it

  One `DATABASE_URL` cannot be both, which is why RLS has never actually been
  enforced anywhere: every environment connects as its migrator role, and a
  migrator either owns the tables or holds BYPASSRLS. `MIGRATOR_DATABASE_URL`
  is the seam, scoped per command so only the admin evals see it.

  ## Why a source-text test

  `entrypoint.sh` runs only inside the built image, so there is no unit-level
  seam to drive. Booting a container here would need Docker in the unit suite.
  A source assertion is the accepted substitute already used for the same
  class of problem in `attachments_test.exs:89`, `folders_test.exs:238`,
  `links_test.exs:197` and `mcp/handlers_test.exs:162`. CI runs no shellcheck,
  so without this the file is entirely unguarded.
  """

  use ExUnit.Case, async: true

  @entrypoint "entrypoint.sh"

  # Every eval that needs the ADMIN login. `reset_baseline` is included
  # deliberately: it is behind an env flag and easy to miss when scanning for
  # "the migration commands", but it rebuilds the schema, so it needs DDL just
  # as much as `migrate` does.
  @admin_evals [
    "Engram.Release.reset_baseline()",
    "Engram.Release.prepare_database()",
    "Engram.Release.migrate()",
    "Engram.Release.verify_schema_baseline()"
  ]

  setup_all do
    %{src: File.read!(@entrypoint)}
  end

  test "MIGRATOR_DATABASE_URL falls back to DATABASE_URL when unset", %{src: src} do
    assert src =~ ~s(MIGRATOR_DATABASE_URL="${MIGRATOR_DATABASE_URL:-$DATABASE_URL}"),
           """
           The fallback assignment is missing or reworded.

           Without it, every environment that does NOT set MIGRATOR_DATABASE_URL
           (prod, CI, local dev) would run the migration evals against an empty
           DATABASE_URL and crash on boot.
           """
  end

  for eval <- @admin_evals do
    test "#{eval} runs with the migrator login", %{src: src} do
      eval = unquote(eval)

      line =
        src
        |> String.split("\n")
        |> Enum.find(fn l -> String.contains?(l, eval) and not String.starts_with?(l, "#") end)

      assert line, "no non-comment line in entrypoint.sh invokes #{eval}"

      assert line =~ ~s(DATABASE_URL="$MIGRATOR_DATABASE_URL" /app/bin/engram eval),
             """
             #{eval} is not scoped to the migrator login.

               line: #{inspect(String.trim(line))}

             It needs CREATEROLE / GRANT / DDL, which the restricted app role does
             not have, so the container would crash-loop on boot once DATABASE_URL
             points at that role.
             """
    end
  end

  test "the BEAM keeps the unmodified DATABASE_URL", %{src: src} do
    exec_line =
      src
      |> String.split("\n")
      |> Enum.find(fn l -> String.starts_with?(String.trim(l), "exec ") end)

    assert exec_line, "entrypoint.sh no longer ends in an `exec` line"

    refute exec_line =~ "MIGRATOR_DATABASE_URL",
           """
           The `exec` line was given the migrator login:

             #{inspect(String.trim(exec_line))}

           That hands the whole application the ADMIN role, which owns the tables
           or holds BYPASSRLS — so FORCE ROW LEVEL SECURITY silently stops
           applying to every query the app makes. This is the exact condition that
           left RLS unenforced in every environment.
           """
  end

  test "the migrator login is never exported globally", %{src: src} do
    refute src =~ ~r/^\s*export\s+MIGRATOR_DATABASE_URL/m,
           """
           MIGRATOR_DATABASE_URL is exported, so it leaks into the BEAM's
           environment. Harmless on its own, but it signals the per-command
           scoping was replaced by a global assignment — check the `exec` line.
           """

    refute src =~ ~r/^\s*(export\s+)?DATABASE_URL="\$MIGRATOR_DATABASE_URL"\s*$/m,
           """
           DATABASE_URL is globally reassigned to the migrator login.

           Every command after that point — including the `exec`ed BEAM —
           then runs as the admin role, which defeats the entire purpose of the
           split. The assignment must stay a per-command prefix.
           """
  end
end
