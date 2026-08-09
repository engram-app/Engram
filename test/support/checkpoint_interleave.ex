defmodule Engram.CheckpointInterleave do
  @moduledoc """
  Pins a mid-transaction interleave so a test can commit a competing write
  BETWEEN the checkpoint's row read and its write (#1326).

  ## Why this has to exist

  `Engram.DataCase` checks out one sandbox connection per test and wraps it in a
  transaction that never commits. Everything the test does — including work in
  spawned tasks, which are `allow`ed onto the same connection — therefore runs
  on **one** connection inside **one** transaction.

  That makes a whole class of bug untestable. `CrdtCheckpoint` reads the note
  row inside `Repo.with_tenant`, does crypto/Yjs work, then writes. At READ
  COMMITTED a write committing in that gap is visible to the UPDATE, so the
  checkpoint can overwrite it. Under the sandbox no other connection can commit
  at all, so the gap is never exercised — the existing race tests say as much in
  their own headers (see `note_upsert_race_test.exs`: "ExUnit's shared sandbox
  serializes the tasks through one connection, so this does NOT trigger the SQL
  race in isolation").

  Two things are needed to close that: real connections that genuinely commit,
  and a way to hold the checkpoint still at a known point while one of them does.

  ## Real connections

  Tests using this helper check out with `sandbox: false`, so writes really
  commit and are visible across connections. CI gives each `MIX_TEST_PARTITION`
  its own database (`config/test.exs`), so committed rows cannot leak between
  partitions — but they DO outlive the test, hence `cleanup/1`.

  ## Holding the checkpoint still

  `CrdtCheckpoint` calls its interleave hook at named points. The hook is read
  from `Application.get_env(:engram, :checkpoint_interleave_hook)` and is `nil`
  in every environment that does not set it, which is all of them outside these
  tests. `arm/1` installs a hook that parks the checkpoint at a point and hands
  control back to the test.

  ## Usage

      # arm/1 returns an uninstall closure — register it, or the hook stays
      # global and parks unrelated checkpoints for @park_timeout each.
      on_exit(CheckpointInterleave.arm(:after_row_read))

      task =
        Task.async(fn ->
          CheckpointInterleave.checkout_real!()
          CrdtCheckpoint.checkpoint(uid, vid, nid, doc)
        end)

      # Blocks until the checkpoint is parked mid-transaction; returns the pid
      # holding it, which release/2 needs.
      parked = CheckpointInterleave.await_parked(:after_row_read)

      # Commits on a DIFFERENT real connection while the checkpoint holds its
      # transaction open. This is the write the checkpoint must not clobber.
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "p.md", ...})

      CheckpointInterleave.release(:after_row_read, parked)
      Task.await(task)

  The park is ONE-SHOT: a stale fence makes the checkpoint retry, and the retry
  must not park again with nobody left to release it.
  """

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Repo

  @hook_key :checkpoint_interleave_hook

  # A parked checkpoint holds a DB transaction open, so every wait here is
  # bounded. Timing out releases rather than hangs: a stuck harness must fail
  # the assertion, not wedge the suite behind a held transaction.
  @park_timeout 10_000

  @doc """
  Install a hook that parks the checkpoint at `point` until `release/1`.

  Returns a function that uninstalls it; `ExUnit`'s `on_exit` should call it so
  a failed test cannot leak a hook onto the next one.
  """
  def arm(point) when is_atom(point) do
    test_pid = self()
    prev = Application.get_env(:engram, @hook_key)

    # ONE-SHOT. A stale fence makes the checkpoint retry, and the retry hits the
    # same point again — with a re-arming hook it would park a second time with
    # nobody left to release it, burn the full @park_timeout, and blow the
    # caller's `Task.await`. The park is the thing being tested; the retry after
    # it must run unimpeded.
    armed = :counters.new(1, [:atomics])

    hook = fn
      ^point ->
        if :counters.get(armed, 1) == 0 do
          :counters.add(armed, 1, 1)
          send(test_pid, {:checkpoint_parked, point, self()})

          receive do
            {:checkpoint_release, ^point} -> :ok
          after
            # Never block a real transaction indefinitely.
            @park_timeout -> :ok
          end
        end

        :ok

      _other ->
        :ok
    end

    Application.put_env(:engram, @hook_key, hook)

    fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, @hook_key),
        else: Application.put_env(:engram, @hook_key, prev)
    end
  end

  @doc """
  Block until the checkpoint reports it is parked at `point`.

  Fails the test rather than returning if it never parks — a silent pass here
  would mean the interleave never happened and the assertion proved nothing.
  """
  def await_parked(point) do
    receive do
      {:checkpoint_parked, ^point, pid} ->
        pid
    after
      @park_timeout ->
        raise "checkpoint never parked at #{inspect(point)} — the interleave did not happen, " <>
                "so any assertion after this point would be vacuous"
    end
  end

  @doc "Let the parked checkpoint continue."
  def release(point, pid) when is_pid(pid), do: send(pid, {:checkpoint_release, point})

  @doc """
  Check out a REAL (non-sandbox) connection for the calling process.

  Every process that touches the DB needs its own: the test, any `Task` it
  spawns, and the `on_exit` callback (which runs in `ExUnit.OnExitHandler`, not
  the test process). Register `cleanup/2` with `on_exit` BEFORE the first
  committing write — these rows really commit, so nothing else removes them.
  """
  def checkout_real! do
    # Idempotent. Two `on_exit` callbacks both run in the same OnExitHandler
    # process, so the second would otherwise get `{:already, :owner}` and raise
    # — turning a successful test into a failure during teardown.
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end

  # `chunks`, `attachments`, `notes` and `vaults` reference `users` with NO
  # ACTION, not CASCADE — deleting the user first raises a FK violation and
  # leaves the whole tree behind.
  @children ~w(chunks attachments notes vaults)

  @doc """
  Delete the rows a real-connection test committed. Raises if it cannot.

  ## Two traps, both of which bit before this was written this way

  **RLS.** These tables are under FORCE ROW LEVEL SECURITY. A bare
  `DELETE FROM notes WHERE user_id = $1` with no `app.current_tenant` set
  matches **zero rows and reports success** — so the children survive, the
  `users` delete then fails on the FK, and nothing looks wrong. The deletes must
  run inside `Repo.with_tenant/2`, which sets the tenant and drops to the
  `engram_app` role.

  **Swallowing errors.** An earlier version wrapped this in `catch _, _ -> :ok`
  "so cleanup could not mask the assertion". It masked the cleanup instead: 8
  users/vaults/notes accumulated across runs, and because several suites scan
  globally (`ReconcileEmbeddings` "caps the batch at 500 across all vaults",
  `ReindexKeyword` "no-op when vault has no notes", the migration backfill
  tests), the leak surfaced as **27 unrelated failures** elsewhere in the suite.
  A cleanup that cannot be trusted is worse than one that fails loudly.
  """
  def cleanup(user_id, note_ids \\ []) do
    uuid = Ecto.UUID.dump!(user_id)

    # `on_exit` callbacks run in ExUnit.OnExitHandler, NOT the test process, so
    # this process owns no connection and every query would raise
    # DBConnection.OwnershipError. Check one out here.
    checkout_real!()

    # A committed checkpoint ENQUEUES: EmbedNote and ExtractNoteLinks keyed by
    # `note_id`, RebindNoteLinks keyed by `user_id`. Those rows commit too, and
    # `oban_jobs` has no FK to users so nothing above removes them. Left behind
    # they break every suite that asserts on the job queue — 14 failures across
    # EmbedNote/ExtractNoteLinks/ReconcileEmbeddings/RepathNoteIndex before this
    # was added, none of which touch the checkpoint path.
    SQL.query!(Repo, "DELETE FROM oban_jobs WHERE args->>'user_id' = $1", [
      user_id
    ])

    for note_id <- note_ids do
      SQL.query!(Repo, "DELETE FROM oban_jobs WHERE args->>'note_id' = $1", [
        note_id
      ])
    end

    {:ok, _} =
      Repo.with_tenant(user_id, fn ->
        for table <- @children do
          SQL.query!(Repo, "DELETE FROM #{table} WHERE user_id = $1", [uuid])
        end
      end)

    # `users` is not tenant-scoped, so it goes outside the tenant block.
    SQL.query!(Repo, "DELETE FROM users WHERE id = $1", [uuid])
    :ok
  end
end
