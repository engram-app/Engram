defmodule Engram.Bookkeeping.CanaryTest do
  # Not async: the canary samples every user's notes.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import ExUnit.CaptureLog

  alias Engram.Bookkeeping.Canary
  alias Engram.Notes
  alias Engram.Repo
  alias Engram.Workers.BookkeepingCanary

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Canary", Ecto.UUID.generate())

    notes =
      for i <- 1..3 do
        {:ok, n} =
          Notes.upsert_note(user, vault, %{"path" => "c#{i}.md", "content" => "c#{i}"},
            actor: "api"
          )

        n
      end

    %{notes: notes}
  end

  defp sql(note, statement),
    do: Repo.query!(statement, [Ecto.UUID.dump!(note.id)])

  defp drift_of(report), do: for({k, n} <- report.drift, n > 0, into: %{}, do: {k, n})

  test "clean data: every sampled row checked, zero drift", %{notes: notes} do
    report = Canary.run()
    assert report.checked == length(notes)
    assert drift_of(report) == %{}
    assert Map.keys(report.drift) |> Enum.sort() == Enum.sort(Canary.invariants())
  end

  # Positive controls: each corruption is seen by exactly its invariant. They
  # fail without the canary (the module does not exist).
  describe "a corrupted row is reported under its own invariant" do
    test "a missing state row", %{notes: [n | _]} do
      sql(n, "DELETE FROM note_index_state WHERE note_id = $1")
      assert drift_of(Canary.run()) == %{state_missing: 1}
    end

    test "a drifted chunk counter", %{notes: [n | _]} do
      sql(n, "UPDATE note_index_state SET points = 5 WHERE note_id = $1")
      assert drift_of(Canary.run()) == %{counters_drift: 1}
    end

    test "underived keys", %{notes: [n | _]} do
      sql(n, "UPDATE notes SET is_folder = NULL WHERE id = $1")
      assert drift_of(Canary.run()) == %{note_split: 1}
    end

    test "a missing body row", %{notes: [n | _]} do
      sql(n, "DELETE FROM note_bodies WHERE note_id = $1")
      assert drift_of(Canary.run()) == %{note_split: 1}
    end

    test "a body whose ciphertext tail differs under the same nonce", %{notes: [n | _]} do
      sql(n, """
      UPDATE note_bodies SET content_ct =
        overlay(content_ct PLACING '\\x00'::bytea FROM length(content_ct))
      WHERE note_id = $1
      """)

      assert drift_of(Canary.run()) == %{body_drift: 1}
    end
  end

  test "telemetry carries counts and the rows checked; logs carry no ids", %{notes: [n | _]} do
    sql(n, "DELETE FROM note_index_state WHERE note_id = $1")
    me = self()

    :telemetry.attach_many(
      "canary-test",
      [
        [:engram, :bookkeeping, :drift],
        [:engram, :bookkeeping, :canary_rows],
        [:engram, :bookkeeping, :canary_ran]
      ],
      fn event, m, meta, _ -> send(me, {event, m[:count] || m[:unix], meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("canary-test") end)

    log = capture_log(fn -> Canary.run() end)

    assert_received {[:engram, :bookkeeping, :canary_rows], 3, _}
    assert_received {[:engram, :bookkeeping, :drift], 1, %{invariant: :state_missing}}
    assert_received {[:engram, :bookkeeping, :drift], 0, %{invariant: :counters_drift}}
    # The dead-man gauge: when the run finished.
    assert_received {[:engram, :bookkeeping, :canary_ran], at, _}
    assert_in_delta at, System.system_time(:second), 5
    refute log =~ n.id
  end

  test "the worker runs the canary and dedups while incomplete" do
    assert :ok = perform_job(BookkeepingCanary, %{})
    {:ok, first} = Oban.insert(BookkeepingCanary.new(%{}))
    {:ok, second} = Oban.insert(BookkeepingCanary.new(%{}))
    assert second.conflict? and second.id == first.id
  end

  test "an empty database samples nothing" do
    Repo.query!("DELETE FROM notes")
    assert %{checked: 0} = Canary.run()
  end
end
