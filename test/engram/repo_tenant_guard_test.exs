defmodule Engram.RepoTenantGuardTest do
  @moduledoc """
  Drift guard: `Repo.@tenant_tables` (what the prepare_query tripwire protects)
  MUST equal the set of tables with ROW LEVEL SECURITY enabled in the schema.
  If they drift, a tenant table can ship without the app-level guard (exactly
  what the 2026-06-29 audit found for onboarding_actions + crdt_update_log,
  Engram#788).
  """
  use Engram.DataCase, async: true

  alias Engram.Repo

  test "@tenant_tables equals the set of RLS-enabled tables in the schema" do
    {:ok, %{rows: rows}} =
      Repo.query("""
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity
      """)

    rls = rows |> List.flatten() |> Enum.sort()
    guard = Repo.tenant_tables() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

    assert guard == rls,
           "Repo.@tenant_tables drifted from the schema's RLS tables.\n" <>
             "  in @tenant_tables but NOT RLS-enabled: #{inspect(guard -- rls)}\n" <>
             "  RLS-enabled but NOT in @tenant_tables: #{inspect(rls -- guard)}\n" <>
             "Add the table to @tenant_tables (or its RLS policy to the schema)."
  end
end
