defmodule Engram.Workers.EmbedNoteCrashGuardClusterTest do
  # CrashGuard's death test against a REAL second node: a stamp written by a
  # runner on a connected node is a live attempt; once that node is gone, the
  # same stamp is one death and the note is isolated. The unit tests in
  # embed_note_test.exs can only fake the "gone" side with a made-up node name.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]

  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.EmbedNote
  alias Engram.Workers.EmbedNote.CrashGuard

  @moduletag :cluster

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "C/Note.md", content: "# C\n\nbody"})
    # The test kills the peer itself, so teardown must tolerate it being gone.
    {peer_pid, peer_node} =
      Engram.ClusterCase.start_peer!([], fn stop -> on_exit(fn -> catch_exit(stop.()) end) end)

    %{note: note, peer_pid: peer_pid, peer_node: peer_node}
  end

  defp stamp_from!(note, runner) do
    from(n in Note, where: n.id == ^note.id)
    |> Repo.update_all(
      [
        set: [
          embed_started_at: DateTime.utc_now(),
          embed_started_by: runner,
          embed_started_hash: note.content_hash
        ]
      ],
      skip_tenant_check: true
    )
  end

  defp args(note), do: %{note_id: note.id, user_id: note.user_id}

  test "a stamp from a connected node is live; after that node dies it is a death",
       %{note: note, peer_pid: peer_pid, peer_node: peer_node} do
    peer_runner = :peer.call(peer_pid, CrashGuard, :runner_id, [])
    assert String.starts_with?(peer_runner, "#{peer_node}/")
    assert peer_node in Node.list()

    stamp_from!(note, peer_runner)

    # The peer is up: its attempt may still be running, so wait, don't count.
    assert {:snooze, _} = perform_job(EmbedNote, args(note))
    assert Repo.get!(Note, note.id, skip_tenant_check: true).embed_crashes in [nil, 0]

    # Die the way an OOM kill does: the VM halts, nothing cleans up.
    catch_exit(:peer.call(peer_pid, :erlang, :halt, [137]))
    wait_until(fn -> peer_node not in Node.list() end)

    assert {:cancel, :isolated_after_node_death} = perform_job(EmbedNote, args(note))

    updated = Repo.get!(Note, note.id, skip_tenant_check: true)
    assert updated.embed_crashes == 1
    assert is_nil(updated.embed_started_at)
    assert_enqueued(worker: EmbedNote, queue: :embed_isolated, args: %{note_id: note.id})
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
