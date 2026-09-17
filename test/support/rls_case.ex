defmodule Engram.RlsCase do
  @moduledoc """
  Case template for tests that prove a query is tenant-scoped under an
  **enforced** RLS policy. Canonical reference:
  `docs/context/rls-enforcement-testing-traps.md`.

  The whole suite connects as a superuser, and a superuser bypasses RLS even
  under `FORCE ROW LEVEL SECURITY`. So a test that merely runs the code proves
  nothing; it has to drop to `engram_app` first. That drop is what the two
  helpers here do.

  ## Two variants, and why there cannot be a third

  The choice is a single axis — rollback or commit — and everything else
  follows from it:

    * Rolling back is the only way to run code that can **raise**. A policy
      rejection aborts the transaction, so any trailing `RESET ROLE` fails with
      25P02 and masks the original 42501. Rolling back discards the `SET LOCAL`
      state instead, leaving nothing to reset. But the value can then only
      escape through `Repo.rollback/1`, which forces the tagged return.

    * Committing is the only way to assert **persisted effect**, which is what
      the filtered-write path needs — an RLS-filtered `update_all` reports
      `{0, nil}` and never raises, so the only observable is whether the row
      changed. A rollback would discard the very write under test.

  `commit + rescue` is not on the menu. A rescued raise leaves an aborted
  transaction that can be neither reset nor committed. That is a constraint of
  Postgres, not a gap here.

  ## Every adopter must declare `async: false` itself

  `SET LOCAL ROLE` applies to the connection, so two of these running
  concurrently on a shared sandbox connection would each see the other's role.

  This module does NOT enforce that. All six adopters `import Engram.RlsCase`
  and write `use Engram.DataCase, async: false` by hand, so the
  `ExUnit.CaseTemplate` `using` block below is currently used by zero files —
  it is kept only so `use Engram.RlsCase` works for a new file that wants it.
  An earlier version of this doc claimed the template "forces `async: false`",
  which was false in the direction that matters: a file importing the helpers
  without declaring it would get no protection while the doc said otherwise.

  ## Every file using this still needs its own CONTROL test

  Deliberately not provided. A control asserts the dropped role sees ZERO rows,
  and without one a green file is ambiguous between "correctly scoped" and "the
  role drop never engaged" — but the *right* control is per-file. The one in
  `index_cap_rls_test.exs` first makes a superuser call to reproduce the
  tenant-leak condition the clear exists to undo; a templated control would
  quietly drop that step and weaken every file that adopted it.

  Setup is likewise per-file: the five current users differ on DEK fixtures,
  Bypass stubs, `billing_enabled`, and one deliberately creates its user
  per-test rather than in `setup`.
  """
  use ExUnit.CaseTemplate

  # Load-bearing, and the thing that broke on extraction. The six harnesses
  # this replaced called a bare `Repo`, which resolved through each test
  # module's own `alias Engram.Repo`. Moved here, the function bodies compile
  # in THIS module's scope, where that alias does not exist — so every call
  # became `Repo.transaction/1 is undefined` and every RLS test failed at once.
  # The `use Engram.DataCase` below aliases Repo for the TEST module, which is a
  # different scope and does not help these functions.
  alias Engram.Repo

  using do
    quote do
      use Engram.DataCase, async: false

      import Engram.RlsCase
    end
  end

  @doc """
  Runs `fun` as `engram_app` with NO tenant set, then ROLLS BACK.

  Use wherever the code under test can raise — in practice any INSERT path,
  since INSERT is the only statement type the policy rejects rather than
  filters.

  Returns `{:returned, value}` or `{:raised, exception}`. The tag is what makes
  a policy rejection legible: without it an aborted transaction surfaces as an
  opaque error and the test cannot say which statement the policy stopped.

  Note the tenant is cleared BEFORE the role drop, and that order is
  load-bearing. Omitting the clear is a documented cause of a false green — the
  sandbox's enclosing transaction can still be carrying a tenant from earlier
  in the test, which silently satisfies the policy.

  Only `rescue`, not `catch`: an `exit` or `throw` escapes untagged. No current
  test does either.

  **Never use this to assert a write did NOT persist.** The rollback discards
  the write regardless, so "the row is unchanged afterwards" holds whether or
  not the policy filtered anything — such a test passes against a completely
  unscoped implementation. That direction is silent, unlike its opposite
  (asserting a write DID persist under a rollback fails loudly on the reload).
  Use `as_prod_role_committing/1` for any assertion about persisted effect.

  The `rescue` is also broad: a fixture bug, a `MatchError` from a changed
  return shape, and a missing `engram_app` GRANT all arrive as `{:raised, e}`,
  and a 42501 from a permission denial is indistinguishable there from a 42501
  policy violation. Match on the specific error, not on `{:raised, _}`.
  """
  def as_prod_role(fun) when is_function(fun, 0) do
    {:error, outcome} =
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('app.current_tenant', '', true)")
        Repo.query!("SET LOCAL ROLE engram_app")

        outcome =
          try do
            {:returned, fun.()}
          rescue
            e -> {:raised, e}
          end

        Repo.rollback(outcome)
      end)

    outcome
  end

  @doc """
  Runs `fun` as `engram_app` with NO tenant set, then COMMITS.

  Use ONLY for assertions about persisted effect on the filtered-write path
  (`update_all` / `delete_all`, which report `{0, nil}` and never raise).
  Returns the bare value.

  A raise here propagates, rolling the transaction back and discarding the
  `SET LOCAL` state — which is exactly why `RESET ROLE` sits on the success
  path and NOT in an `after`. In an `after` it runs against an already-aborted
  transaction, fails with 25P02, and replaces the real error with a useless
  one.
  """
  def as_prod_role_committing(fun) when is_function(fun, 0) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('app.current_tenant', '', true)")
        Repo.query!("SET LOCAL ROLE engram_app")

        result = fun.()

        Repo.query!("RESET ROLE")
        result
      end)

    result
  end
end
