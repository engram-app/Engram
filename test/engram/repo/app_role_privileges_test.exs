defmodule Engram.Repo.AppRolePrivilegesTest do
  @moduledoc """
  Pins the write privileges `engram_app` must NOT hold (#1766).

  `plans` is seeded and read-only at runtime (`Engram.Billing.PlanCache`), and
  `system_canaries` is insert-once (`Engram.Crypto.BootCanary.provision!/1`).
  A blanket `GRANT` in a later migration would silently hand the app
  credential the power to rewrite every user's limits or corrupt the boot
  canary; this fails loudly instead.

  `schema_migrations` is written only by the migrator. An app credential that
  can delete a version row makes the next deploy re-run that migration as the
  migrator; one that can insert a version makes a migration silently skip.
  """
  use Engram.DataCase, async: true

  defp privilege?(table, priv) do
    %{rows: [[granted]]} =
      Repo.query!("SELECT has_table_privilege('engram_app', $1, $2)", [table, priv])

    granted
  end

  for {table, priv} <- [
        {"plans", "INSERT"},
        {"plans", "UPDATE"},
        {"plans", "DELETE"},
        {"system_canaries", "UPDATE"},
        {"system_canaries", "DELETE"},
        {"schema_migrations", "INSERT"},
        {"schema_migrations", "UPDATE"},
        {"schema_migrations", "DELETE"}
      ] do
    test "engram_app lacks #{priv} on #{table}" do
      refute privilege?(unquote(table), unquote(priv))
    end
  end

  # CONTROL: the runtime paths still work, so the refutes above are not
  # passing because the role or tables are missing.
  for {table, priv} <- [
        {"plans", "SELECT"},
        {"system_canaries", "SELECT"},
        {"system_canaries", "INSERT"},
        {"schema_migrations", "SELECT"}
      ] do
    test "engram_app keeps #{priv} on #{table}" do
      assert privilege?(unquote(table), unquote(priv))
    end
  end
end
