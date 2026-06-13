defmodule Engram.ReleaseTest do
  @moduledoc """
  Guards the self-disable safety property of `Engram.Release.reset_baseline/0`,
  the one-shot used to heal the PG18/uuidv7 cutover on a DB that was upgraded
  in-place instead of wiped (see
  `docs/context/pg18-uuidv7-prod-crashloop-2026-06-11.md`).

  The destructive `DROP SCHEMA` path is verified out-of-band against a real
  PG18 with a legacy integer-PK dump — it cannot run inside the sandbox. What
  MUST be locked here is the guard that makes the reset a no-op on a healthy
  uuid schema, so the env flag can never wipe live data.
  """
  use Engram.DataCase, async: false

  alias Engram.Release
  alias Engram.Repo

  describe "legacy_integer_pk?/2" do
    test "returns false for the current uuid `terms_versions` schema" do
      refute Release.legacy_integer_pk?(Repo, "terms_versions")
    end

    test "returns true for an integer-PK table (the broken legacy state)" do
      Repo.query!("CREATE TABLE reset_probe_legacy (id bigint NOT NULL)", [])
      assert Release.legacy_integer_pk?(Repo, "reset_probe_legacy")
    end

    test "returns false when the table is absent (fresh DB — let migrate handle it)" do
      refute Release.legacy_integer_pk?(Repo, "table_that_does_not_exist")
    end
  end

  describe "verify_schema_baseline!/2" do
    test "returns :ok for the current uuid `terms_versions` schema" do
      assert :ok == Release.verify_schema_baseline!(Repo, "terms_versions")
    end

    test "returns :ok when the sentinel table is absent (fresh DB)" do
      assert :ok == Release.verify_schema_baseline!(Repo, "table_that_does_not_exist")
    end

    test "raises an actionable error on a legacy integer-PK table" do
      Repo.query!("CREATE TABLE baseline_probe_legacy (id bigint NOT NULL)", [])

      err =
        assert_raise RuntimeError, fn ->
          Release.verify_schema_baseline!(Repo, "baseline_probe_legacy")
        end

      # Names the offending column and the documented remedy so the operator
      # gets a one-line diagnosis instead of a cryptic Ecto.UUID crash-loop.
      assert err.message =~ "baseline_probe_legacy.id"
      assert err.message =~ "ENGRAM_DB_RESET_BASELINE"
    end
  end

  describe "verify_schema_baseline/0" do
    test "returns :ok on a healthy uuid schema (all configured repos)" do
      assert :ok == Release.verify_schema_baseline()
    end
  end
end
