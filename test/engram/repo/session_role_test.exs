defmodule Engram.Repo.SessionRoleTest do
  @moduledoc """
  Pins the Postgres semantics the enforced-RLS test job depends on.

  To run the whole suite under a role RLS applies to, something has to drop the
  sandbox connection off its superuser. There are two ways to do that and only
  one of them survives contact with this codebase.

  `SET ROLE engram_app` changes `current_user` but leaves `session_user` as the
  superuser. `Engram.Repo.with_tenant/2` ends every block with
  `set_config('role', 'none', true)` — the equivalent of `SET LOCAL ROLE NONE`
  — which reverts to `session_user`. So under `SET ROLE`, the first
  `with_tenant` call in a test silently hands the connection back to the
  superuser and every later statement runs UNENFORCED. The suite would look
  like it was proving RLS while proving nothing after the first scoped call —
  the same false-green shape as the leak-forward trap in
  `docs/context/rls-enforcement-testing-traps.md`, but suite-wide.

  `SET SESSION AUTHORIZATION engram_app` changes `session_user` itself, so
  `ROLE NONE` lands back on `engram_app` instead of the superuser.

  These tests are the evidence for that claim. If Postgres ever changes the
  behaviour, the enforced-RLS job goes quietly useless and this is what says so.
  """
  use Engram.DataCase, async: false

  # This file is ABOUT the role machinery, so it cannot run under the
  # enforced-RLS diagnostic: half its assertions are only true when
  # `session_user` is the superuser.
  @moduletag :rls_unsafe

  describe "SET ROLE — why it is NOT usable for suite-wide enforcement" do
    test "role NONE reverts to the superuser, un-enforcing mid-test" do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL ROLE engram_app")
        assert [["engram_app"]] = Repo.query!("SELECT current_user").rows

        # Exactly what `with_tenant/2` runs on its way out.
        Repo.query!("SELECT set_config('role', 'none', true)")

        [[after_reset]] = Repo.query!("SELECT current_user").rows
        refute after_reset == "engram_app"

        Repo.rollback(:done)
      end)
    end
  end

  describe "SET SESSION AUTHORIZATION — the primitive the job uses" do
    test "role NONE lands back on engram_app, so enforcement survives with_tenant" do
      Repo.query!("SET SESSION AUTHORIZATION engram_app")

      try do
        assert [["engram_app"]] = Repo.query!("SELECT current_user").rows

        Repo.transaction(fn ->
          Repo.query!("SELECT set_config('role', 'none', true)")

          assert [["engram_app"]] = Repo.query!("SELECT current_user").rows

          Repo.rollback(:done)
        end)
      after
        Repo.query!("RESET SESSION AUTHORIZATION")
      end
    end

    # This is the form `Engram.DataCase` actually uses, and it is a distinct
    # claim from the session-level one above.
    #
    # A plain `SET SESSION AUTHORIZATION` would be wrong in the sandbox: the
    # connection goes back to a pool, so the authorization would leak into
    # whichever test checks it out next, and resetting in `on_exit` is
    # unreliable because that callback runs outside the connection's owner.
    #
    # `SET LOCAL` scopes it to the sandbox's per-test transaction, so the
    # rollback reverts it with no cleanup step to forget. What has to survive is
    # the same thing: `ROLE NONE` must land on engram_app, not the superuser.
    test "the LOCAL form is transaction-scoped and still survives role NONE" do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
        assert [["engram_app"]] = Repo.query!("SELECT current_user").rows

        Repo.query!("SELECT set_config('role', 'none', true)")
        assert [["engram_app"]] = Repo.query!("SELECT current_user").rows

        Repo.rollback(:done)
      end)

      # Reverted by the rollback, with nothing to reset explicitly — this is
      # what makes it safe on a pooled connection.
      refute [["engram_app"]] == Repo.query!("SELECT current_user").rows
    end

    test "RLS actually applies under it, and lifts again on reset" do
      user = insert(:user)
      note = insert(:note, user: user, vault: insert(:vault, user: user))

      Repo.query!("SET SESSION AUTHORIZATION engram_app")

      filtered =
        try do
          Repo.query!("SELECT count(*) FROM notes WHERE id = $1", [
            Ecto.UUID.dump!(note.id)
          ]).rows
        after
          Repo.query!("RESET SESSION AUTHORIZATION")
        end

      # Raw SQL, so Engram's application-level tripwire is not involved: this is
      # the POLICY filtering, which is the thing the job needs to be real.
      assert [[0]] = filtered

      # And the reset genuinely restores superuser visibility — otherwise the
      # suite could not clean up after itself.
      assert [[1]] =
               Repo.query!("SELECT count(*) FROM notes WHERE id = $1", [
                 Ecto.UUID.dump!(note.id)
               ]).rows
    end
  end
end
