defmodule Engram.NotesCrdtVaultPopulatedRlsTest do
  @moduledoc """
  Pins the `vault_populated` probe against an ENFORCED row-level security
  policy.

  ## What breaks

  `maybe_broadcast_vault_populated/2` runs a LIMIT-2 probe over `notes` with
  `skip_tenant_check: true` and a comment justifying it:

      `skip_tenant_check:` rather than `Repo.with_tenant/2`: outside a
      transaction that helper opens BEGIN + set_config + COMMIT, and this
      runs on every genesis insert of a bulk first sync. The query already
      filters user_id AND vault_id, so the tenant round-trip buys nothing.

  The last sentence is the same inversion `Vaults.count_for/1` documents
  against: the policy filters FIRST, so "the query already filters user_id"
  buys exactly nothing. Filtered, the probe returns `[]`, `length(ids) == 1`
  is false, and the broadcast never fires.

  That strands the web `/link` success page and the onboarding "install the
  plugin" step forever — which is precisely the bug this event was ADDED to
  fix (see `notes_crdt_vault_populated_test.exs`'s moduledoc: "for the exact
  scenario the page was built for, an Obsidian first sync, the event never
  fired and the page waited forever").

  ## Two callers, only one of them broken

  `notes.ex:521` (the REST upsert path) sits INSIDE the `with_tenant/2` opened
  at :444, so its probe inherits a tenant and is fine. `notes.ex:974` — the
  CRDT genesis path, and the one the plugin actually uses — runs in the
  `case Repo.with_tenant(...)` RESULT handling, deliberately post-commit so a
  client cannot pull before the row is visible. That one has no tenant.

  Since `with_tenant/2` is re-entrant for the same tenant, scoping inside the
  helper costs the :521 caller nothing and fixes the :974 one.

  ## READ THIS BEFORE TRUSTING THE SECOND TEST

  **It does not discriminate, and it cannot.** Measured: it passed against the
  unscoped code. `genesis_crdt_note/5` opens its own `Repo.with_tenant/2`, and
  under the Ecto sandbox every test runs inside one enclosing transaction, so
  that block's `SET LOCAL` tenant LEAKS FORWARD and is still in force when the
  post-commit probe runs. Production has no enclosing transaction, so there the
  probe genuinely has no tenant.

  `Engram.Accounts.LifecycleRlsTest` hits the same wall and gets around it with
  a seam — `wipe_storage_prefix/2` runs between the leak and the commit point
  through a storage adapter the test already swaps. There is no equivalent here:
  the only thing between the `with_tenant` exit and the probe is
  `CrdtDeliver.announce_ready/4`, which is called directly and is not
  swappable via app env.

  So this file ships as:

    * a CONTROL that does discriminate (it proves the role drop engaged), and
    * a REGRESSION GUARD that would catch a future change removing the scope
      *and* the leak, but proves nothing about the fix on its own.

  The fix itself rests on the analysis above plus the identical, *proven*
  failure of every other probe of this shape in this sweep. Trap 7 in
  `docs/context/rls-enforcement-testing-traps.md` covers the class.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Notes
  alias Engram.Repo

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)
    EngramWeb.Endpoint.subscribe("user:#{user.id}")

    %{user: user, vault: vault}
  end

  describe "the vault_populated probe under enforced RLS" do
    # CONTROL. Without it a green file cannot distinguish "correctly scoped"
    # from "the role drop never engaged".
    test "control: the dropped role sees none of the user's notes", %{vault: vault} do
      assert {:returned, 0} =
               as_prod_role(fn ->
                 Repo.one(
                   from(n in Notes.Note, where: n.vault_id == ^vault.id, select: count(n.id)),
                   skip_tenant_check: true
                 )
               end)
    end

    test "a crdt genesis create still announces vault_populated",
         %{user: user, vault: vault} do
      id = Ecto.UUID.generate()

      # Committing harness: the broadcast is a side effect of a committed
      # insert, and a rollback would discard the row the probe counts.
      assert {:ok, _note} =
               as_prod_role_committing(fn ->
                 Notes.genesis_crdt_note(user, vault, id, "First Note.md")
               end)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "vault_populated",
                       payload: %{vault_id: broadcast_vault_id}
                     },
                     1_000,
                     "vault_populated never fired: the LIMIT-2 probe over `notes` was filtered, " <>
                       "so the /link page and the onboarding plugin step wait forever"

      assert broadcast_vault_id == vault.id
    end
  end
end
