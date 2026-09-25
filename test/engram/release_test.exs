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

  describe "set_engram_app_password/1" do
    # Reaches Postgres directly rather than through prepare_database/0, which
    # opens its own connection via Ecto.Migrator.with_repo and escapes the
    # sandbox.

    setup do
      Repo.query!(
        "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'engram_app') " <>
          "THEN CREATE ROLE engram_app NOINHERIT LOGIN; END IF; END $$;"
      )

      on_exit(fn -> System.delete_env("ENGRAM_APP_DB_PASSWORD") end)
      :ok
    end

    defp verifier do
      %{rows: [[v]]} =
        Repo.query!("SELECT rolpassword FROM pg_authid WHERE rolname = 'engram_app'")

      v
    end

    test "unset is a no-op" do
      System.delete_env("ENGRAM_APP_DB_PASSWORD")
      before = verifier()

      assert :ok = Release.set_engram_app_password(Repo)
      assert verifier() == before
    end

    test "EMPTY is a no-op, not `PASSWORD ''`" do
      # The dangerous case. An empty ECS/SOPS value reaching Postgres verbatim
      # would set a password anyone can authenticate as, and it would look like
      # a successful rotation. Same "" handling as MAINTENANCE_DATABASE_URL in
      # runtime.exs, for the same reason.
      System.put_env("ENGRAM_APP_DB_PASSWORD", "")
      before = verifier()

      assert :ok = Release.set_engram_app_password(Repo)
      assert verifier() == before
    end

    test "the verifier matches the one Postgres builds for the same password" do
      # The load-bearing test, and it took two attempts to make it real.
      #
      # A hand-rolled SCRAM verifier that is subtly wrong — wrong iteration
      # count, HMAC and SHA transposed, salt encoded before it is used — still
      # WRITES fine and still reads back as a plausible `SCRAM-SHA-256$...`
      # string. So the obvious test is "can the role log in afterwards".
      #
      # That test was VACUOUS here: this dev/CI cluster authenticates local
      # connections with `trust`, so a deliberately wrong password connected
      # happily. The negative control is the only reason that was caught, and
      # it is why this asserts against a reference instead.
      #
      # The reference is Postgres itself. Let it build a verifier from the
      # plaintext, take ITS salt and iteration count, rebuild with our function,
      # and require the StoredKey and ServerKey to match byte for byte. That
      # cannot pass against wrong crypto, and it needs no pinned vector that
      # could drift.
      password = "pw-#{System.unique_integer([:positive])}-Aa1!"

      Repo.query!("ALTER ROLE engram_app PASSWORD '#{password}'")
      theirs = verifier()

      assert ["SCRAM-SHA-256", rest] = String.split(theirs, "$", parts: 2)
      assert [params, keys] = String.split(rest, "$", parts: 2)
      assert [iterations, salt_b64] = String.split(params, ":", parts: 2)
      assert {:ok, salt} = Base.decode64(salt_b64)

      assert iterations == "4096",
             "Postgres default changed; @scram_iterations must follow it"

      ours = Release.scram_verifier(password, salt)

      assert String.ends_with?(ours, keys),
             "our StoredKey:ServerKey differ from Postgres' for the same password + salt"

      assert ours == theirs
    end

    test "the plaintext never appears in the statement sent to Postgres" do
      # `ALTER ROLE` takes no bind parameter, so the value becomes statement
      # TEXT — and pg_stat_statements does not normalise utility statements.
      # `engram_metrics_ro` holds pg_monitor and can read that view, so a
      # plaintext password here would be readable by the metrics exporter.
      password = "unmistakable-plaintext-marker"
      System.put_env("ENGRAM_APP_DB_PASSWORD", password)

      assert :ok = Release.set_engram_app_password(Repo)

      stored = verifier()
      assert stored =~ "SCRAM-SHA-256$4096:"
      refute stored =~ password
    end

    test "a password containing a quote cannot break out" do
      # Every byte of the verifier is base64 or punctuation generated by the
      # release module, never by the password, so there is no input that closes
      # the quote. Asserted rather than reasoned about.
      System.put_env("ENGRAM_APP_DB_PASSWORD", "a'; DROP TABLE notes; --")

      assert :ok = Release.set_engram_app_password(Repo)

      assert %{rows: [[true]]} =
               Repo.query!("SELECT to_regclass('public.notes') IS NOT NULL")
    end

    test "re-applying is idempotent, so running it on every boot is safe" do
      # It runs on EVERY boot by design: setting the password only inside the
      # IF NOT EXISTS branch would mean a rotated secret never reaches Postgres
      # and the app locks itself out at the next task replacement. The salt is
      # fresh each time, so the verifier differs while the password does not.
      System.put_env("ENGRAM_APP_DB_PASSWORD", "stable-value")

      assert :ok = Release.set_engram_app_password(Repo)
      first = verifier()
      assert :ok = Release.set_engram_app_password(Repo)

      assert verifier() != first, "expected a fresh salt on each application"
    end
  end

  describe "set_engram_maintenance_password/1" do
    # Same mechanism as set_engram_app_password/1 (one shared implementation),
    # so this pins only what differs: the env var and the role it lands on, and
    # that it never touches engram_app's credential.

    setup do
      Repo.query!(
        "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'engram_maintenance') " <>
          "THEN CREATE ROLE engram_maintenance NOINHERIT LOGIN; END IF; END $$;"
      )

      on_exit(fn -> System.delete_env("ENGRAM_MAINTENANCE_DB_PASSWORD") end)
      :ok
    end

    defp verifier_for(role) do
      %{rows: [[v]]} = Repo.query!("SELECT rolpassword FROM pg_authid WHERE rolname = $1", [role])
      v
    end

    test "unset and EMPTY are no-ops" do
      before = verifier_for("engram_maintenance")

      System.delete_env("ENGRAM_MAINTENANCE_DB_PASSWORD")
      assert :ok = Release.set_engram_maintenance_password(Repo)

      System.put_env("ENGRAM_MAINTENANCE_DB_PASSWORD", "")
      assert :ok = Release.set_engram_maintenance_password(Repo)

      assert verifier_for("engram_maintenance") == before
    end

    test "applies a SCRAM verifier to engram_maintenance, never the plaintext, and leaves engram_app alone" do
      app_before = verifier_for("engram_app")
      password = "maintenance-plaintext-marker"
      System.put_env("ENGRAM_MAINTENANCE_DB_PASSWORD", password)

      assert :ok = Release.set_engram_maintenance_password(Repo)

      stored = verifier_for("engram_maintenance")
      assert stored =~ "SCRAM-SHA-256$4096:"
      refute stored =~ password
      assert verifier_for("engram_app") == app_before
    end
  end
end
