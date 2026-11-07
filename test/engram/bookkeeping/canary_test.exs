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

    %{notes: notes, user: user, vault: vault}
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

    # Compared by nonce (R8 b1): a later release stops writing the `notes`
    # ciphertext, so only the nonce names the body. A body corrupted under
    # its own nonce fails its AEAD tag on read instead.
    test "a body whose nonce differs from its notes row", %{notes: [n | _]} do
      sql(n, """
      UPDATE note_bodies SET content_ct = set_byte(content_ct, 4, get_byte(content_ct, 4) # 255)
      WHERE note_id = $1
      """)

      assert drift_of(Canary.run()) == %{body_drift: 1}
    end
  end

  # #2413: FolderTable has no nightly re-verify, so the canary samples the
  # references readers trust. Red before: no folder invariant existed.
  describe "folder references" do
    defp put_att(user, vault, path) do
      {:ok, att} =
        Engram.Attachments.upsert_attachment(user, vault, %{
          "path" => path,
          "content_base64" => Base.encode64("bytes of " <> path)
        })

      att
    end

    defp folder_id(user, path), do: Engram.FolderRows.tree(user)[path].id

    test "clean folders and attachments: zero drift, attachments counted", ctx do
      %{user: u, vault: v} = ctx
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "F/n.md", "content" => "x"}, actor: "api")
      put_att(u, v, "F/a.png")
      put_att(u, v, "root.png")

      report = Canary.run()
      assert report.checked == 3 + 1 + 2
      assert drift_of(report) == %{}
    end

    test "a note whose reference names another folder's row", ctx do
      %{user: u, vault: v} = ctx
      {:ok, n} = Notes.upsert_note(u, v, %{"path" => "F/n.md", "content" => "x"}, actor: "api")
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "G/m.md", "content" => "x"}, actor: "api")

      Repo.query!("UPDATE notes SET folder_ref_id = $2 WHERE id = $1", [
        Ecto.UUID.dump!(n.id),
        Ecto.UUID.dump!(folder_id(u, "G"))
      ])

      assert drift_of(Canary.run()) == %{folder_ref: 1}
    end

    test "a trusted attachment reference to the wrong folder", ctx do
      %{user: u, vault: v} = ctx
      att = put_att(u, v, "F/a.png")
      put_att(u, v, "G/b.png")

      Repo.query!(
        "UPDATE attachments SET folder_ref_id = $2, folder_ref_stamp = path_nonce WHERE id = $1",
        [Ecto.UUID.dump!(att.id), Ecto.UUID.dump!(folder_id(u, "G"))]
      )

      assert drift_of(Canary.run()) == %{folder_ref: 1}
    end

    # No index can find a reference to a soft-deleted folder row, so the
    # canary counts it.
    test "a note whose reference names a deleted folder row", ctx do
      %{user: u, vault: v} = ctx
      {:ok, n} = Notes.upsert_note(u, v, %{"path" => "F/n.md", "content" => "x"}, actor: "api")

      dead = folder_id(u, "F")
      Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(dead)])

      # `folders_release_refs` NULLs it on the delete, and `folder_ref_live_only`
      # NULLs one written after; a row written before both (replayed here with
      # triggers off) can still name the dead row, and the canary must see it.
      Repo.query!("SET LOCAL session_replication_role = replica")

      Repo.query!("UPDATE notes SET folder_ref_id = $2 WHERE id = $1", [
        Ecto.UUID.dump!(n.id),
        Ecto.UUID.dump!(dead)
      ])

      Repo.query!("SET LOCAL session_replication_role = origin")

      assert drift_of(Canary.run()) == %{folder_ref: 1}
    end

    # Mid-rotation, rows and folder rows are re-keyed in separate sweeps: a
    # compare under the new key would report drift that is not there.
    test "a user under a DEK rotation is not judged", ctx do
      %{user: u, vault: v} = ctx
      att = put_att(u, v, "F/a.png")
      {:ok, n} = Notes.upsert_note(u, v, %{"path" => "F/n.md", "content" => "x"}, actor: "api")
      put_att(u, v, "G/b.png")

      Repo.query!(
        "UPDATE attachments SET folder_ref_id = $2, folder_ref_stamp = path_nonce WHERE id = $1",
        [Ecto.UUID.dump!(att.id), Ecto.UUID.dump!(folder_id(u, "G"))]
      )

      Repo.query!("UPDATE notes SET folder_ref_id = $2 WHERE id = $1", [
        Ecto.UUID.dump!(n.id),
        Ecto.UUID.dump!(folder_id(u, "G"))
      ])

      Repo.query!("UPDATE users SET dek_rotation_locked_at = now() WHERE id = $1", [
        Ecto.UUID.dump!(u.id)
      ])

      assert drift_of(Canary.run()) == %{}
    end

    test "control: an unstamped wrong reference is the drain's, not trusted drift", ctx do
      %{user: u, vault: v} = ctx
      att = put_att(u, v, "F/a.png")
      put_att(u, v, "G/b.png")

      Repo.query!(
        "UPDATE attachments SET folder_ref_id = $2, folder_ref_stamp = NULL WHERE id = $1",
        [Ecto.UUID.dump!(att.id), Ecto.UUID.dump!(folder_id(u, "G"))]
      )

      assert drift_of(Canary.run()) == %{}
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

  # The last-run gauge is the dead-man signal: a run that fails must not
  # refresh it, or a canary that always crashes would read as alive.
  test "a failed run does not emit the last-run time" do
    me = self()

    :telemetry.attach(
      "canary-ran-test",
      [:engram, :bookkeeping, :canary_ran],
      fn _, _, _, _ -> send(me, :ran) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("canary-ran-test") end)

    # The check step fails mid-run (its state table is gone).
    Repo.query!("ALTER TABLE note_index_state RENAME TO note_index_state_gone")

    assert_raise Postgrex.Error, fn -> Canary.run() end
    refute_received :ran
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
