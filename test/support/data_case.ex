defmodule Engram.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Engram.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Engram.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Engram.DataCase
      import Engram.Factory
    end
  end

  setup tags do
    Engram.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Engram.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    maybe_enforce_rls(tags)

    # A test may spin up `:global` CrdtDoc rooms (any test exercising the CRDT
    # sync path). A room is a sandbox-using process that is NOT linked to the
    # test, so it outlives the test and its `terminate` -> `CrdtPersistence.unbind/3`
    # (a DB write) runs AFTER `stop_owner/1` above has torn down the connection's
    # owner — checking out a dead-owner connection and poisoning the shared
    # sandbox for every later test (see #777).
    #
    # Fix: synchronously stop any live rooms before the owner is stopped. on_exit
    # is LIFO, so registering this AFTER the stop_owner callback runs it FIRST —
    # the room's unbind executes while the shared connection is still checked in.
    #
    # Gated on shared (non-async) mode only: there, this test runs alone, so
    # stopping every room is safe. In async mode rooms belong to concurrently
    # running tests and must not be touched (and an async test cannot lend its
    # connection to an unrelated room anyway).
    unless tags[:async] do
      on_exit(&stop_crdt_rooms/0)
    end
  end

  # Runs the suite as `engram_app` rather than the cluster superuser, so the RLS
  # policies are genuinely in force. Opt-in via `ENGRAM_ENFORCE_RLS=1`; without
  # it the suite keeps its superuser connection and behaves exactly as before.
  #
  # Why this exists: the whole suite connects as a SUPERUSER, and a superuser
  # bypasses RLS even under `FORCE ROW LEVEL SECURITY`. So ~235
  # `skip_tenant_check` call sites were never once exercised against a role the
  # policy applies to, and 32 of them turned out to be broken. Writing one RLS
  # test per bug does not scale to that; flipping the whole suite does.
  #
  # `SET LOCAL SESSION AUTHORIZATION` is the specific primitive, and both
  # obvious alternatives are wrong:
  #
  #   * `SET ROLE` — `Repo.with_tenant/2` ends every block with
  #     `set_config('role', 'none', true)`, which reverts to `session_user`.
  #     Under `SET ROLE` that is the superuser, so every statement after the
  #     first scoped call runs UNENFORCED and the suite proves nothing.
  #   * session-level `SET SESSION AUTHORIZATION` — the sandbox returns
  #     connections to a pool, so it would leak into whichever test checks out
  #     next, and resetting it in `on_exit` is unreliable because that callback
  #     runs outside the connection's owner.
  #
  # `SET LOCAL` is scoped to the sandbox's per-test transaction and reverted by
  # its rollback, so there is no cleanup step to forget. All of that is pinned
  # by `Engram.Repo.SessionRoleTest` rather than asserted here.
  #
  # `@moduletag :rls_unsafe` opts a file out, for tests whose expectations are
  # legitimately role-dependent (a foreign row is invisible under the policy, so
  # some assertions genuinely differ). That tag is the debt counter:
  # `grep -rl rls_unsafe test/ | wc -l` only goes down.
  defp maybe_enforce_rls(tags) do
    if System.get_env("ENGRAM_ENFORCE_RLS") == "1" and tags[:rls_unsafe] != true do
      Engram.Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
    end

    :ok
  end

  # Stop every live CrdtDoc room synchronously so its terminate/unbind runs
  # against the still-checked-in shared sandbox connection. Best-effort: a room
  # already mid-exit just resolves to an :exit we swallow.
  defp stop_crdt_rooms do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Engram.Notes.CrdtDocSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
