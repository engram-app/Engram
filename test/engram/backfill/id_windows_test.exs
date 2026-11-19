defmodule Engram.Backfill.IdWindowsTest do
  # heal_pass/4 is the only completion check of the ledger migrations that
  # walk id windows (#2276): these pin when it may say :done.
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.Notes.Note
  alias Engram.Repo

  setup do
    users =
      for _ <- 1..2 do
        user = insert(:user)
        vault = insert(:vault, user: user)
        notes = for _ <- 1..3, do: insert(:note, user: user, vault: vault)
        {user.id, notes |> Enum.map(& &1.id) |> Enum.sort()}
      end

    %{users: Enum.sort(users)}
  end

  # A step that reports every window to the test and returns `result`.
  defp step(result) do
    test = self()

    fn ids, ctx ->
      send(test, {:window, ctx.user_id, ids})
      result
    end
  end

  defp windows(acc \\ []) do
    receive do
      {:window, user_id, ids} -> windows([{user_id, ids} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a clean full walk is done", %{users: users} do
    assert :done = IdWindows.heal_pass("t", Note, step({0, false}), batch_size: 2)
    assert windows() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == Enum.map(users, &elem(&1, 0))
  end

  test "a window that left a row (a skipped lock) keeps the walk open" do
    assert {:more, rows: 0} = IdWindows.heal_pass("t", Note, step({0, true}), batch_size: 2)
  end

  test "the fixed-row cap halts the walk, and the next pass resumes after it", %{
    users: [{u1, [a, b, c]}, {u2, _}]
  } do
    assert {:more, rows: 1} =
             IdWindows.heal_pass("t", Note, step({1, false}), batch_size: 1, max_fixed: 1)

    # Halted in user 1: user 2 was not visited.
    assert windows() == [{u1, [a]}]

    assert {:more, rows: 1} =
             IdWindows.heal_pass("t", Note, step({1, false}), batch_size: 1, max_fixed: 1)

    assert windows() == [{u1, [b]}]

    _ = {c, u2}
  end

  test "a budget that cuts every pass short still finishes, one window a pass", %{
    users: users
  } do
    ref = make_ref()
    test = self()

    :telemetry.attach(
      ref,
      [:engram, :id_windows, :walk_spanning],
      fn _, %{passes: n}, _, _ -> send(test, {:spanning, n}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
    opts = [batch_size: 1, budget_ms: -1]

    for _ <- 1..5 do
      assert {:more, rows: 0, hit_budget: true} =
               IdWindows.heal_pass("t", Note, step({0, false}), opts)
    end

    # The sixth takes the last note and reaches the end of the table: the
    # walk, spread over six passes, fixed nothing.
    assert :done = IdWindows.heal_pass("t", Note, step({0, false}), opts)

    expected = for {user_id, ids} <- users, id <- ids, do: {user_id, [id]}
    assert windows() == expected
    assert_received {:spanning, 4}
  end

  # Prod 2026-11-18/19: note_folder_hash_null, capped at 2,000 rows a pass,
  # fixed ~2,100 rows every hourly pass and still warned "spanned N passes"
  # (category :oban, the oban-discard alert) from pass 4 on.
  defp attach_spanning do
    ref = make_ref()
    test = self()

    :telemetry.attach(
      ref,
      [:engram, :id_windows, :walk_spanning],
      fn _, %{passes: n}, _, _ -> send(test, {:spanning, n}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
  end

  # Prod 2026-11-18/19: note_folder_hash_null, capped at 2,000 rows a pass,
  # fixed ~2,100 rows every hourly pass and still warned "spanned N passes"
  # (category :oban, the oban-discard alert) from pass 4 on.
  test "cap-paced with a moving cursor stays quiet" do
    attach_spanning()

    for _ <- 1..5 do
      assert {:more, rows: 1} =
               IdWindows.heal_pass("t", Note, step({1, false}), batch_size: 1, max_fixed: 1)
    end

    # Five passes of one walk, each resuming at the last one's cursor.
    assert length(windows() |> Enum.uniq()) == 5
    refute_received {:spanning, _}
  end

  # A walk that never converges (a writer re-creates what the walk fixes) must
  # not hide behind the cap. A cap stop always advances the cursor (it ran a
  # window past it), so the pass count is the only signal.
  test "cap-paced past the pass bound warns", %{users: [{u1, [a | _]} | _]} do
    attach_spanning()
    cursors = Engram.Backfill.IdWindows.Cursors

    seed = fn passes ->
      Agent.update(cursors, &Map.put(&1, "t", %{from: {u1, a}, dirty: true, passes: passes}))
    end

    seed.(167)

    assert {:more, rows: 1} =
             IdWindows.heal_pass("t", Note, step({1, false}), batch_size: 1, max_fixed: 1)

    refute_received {:spanning, _}

    seed.(168)

    assert {:more, rows: 1} =
             IdWindows.heal_pass("t", Note, step({1, false}), batch_size: 1, max_fixed: 1)

    assert_received {:spanning, 169}
  end

  test "a fix anywhere in a walk that spans passes keeps it open for a new walk" do
    opts = [batch_size: 1, budget_ms: -1]

    assert {:more, rows: 1, hit_budget: true} =
             IdWindows.heal_pass("t", Note, step({1, false}), opts)

    for _ <- 1..4,
        do:
          assert(
            {:more, rows: 0, hit_budget: true} =
              IdWindows.heal_pass("t", Note, step({0, false}), opts)
          )

    # End of the dirty walk: not done, and a new walk starts.
    assert {:more, rows: 0} = IdWindows.heal_pass("t", Note, step({0, false}), opts)
    _ = windows()

    assert {:more, rows: 0, hit_budget: true} =
             IdWindows.heal_pass("t", Note, step({0, false}), opts)

    assert [{_, [_]}] = windows()
  end

  test "a fleet walk on the app pool raises" do
    assert_raise ArgumentError, ~r/FORCE RLS/, fn ->
      IdWindows.reduce({:fleet, Repo}, Note, nil, fn _, _, a -> {:cont, a} end)
    end
  end
end
