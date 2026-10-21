defmodule Engram.Workers.CheckpointNoteRetimeTest do
  # retime_snoozed/1 runs on every room exit. It names the queue so Postgres
  # can use Oban's (state, queue, ...) index instead of scanning every
  # scheduled job of every queue.
  use Engram.DataCase, async: true

  alias Engram.Workers.CheckpointNote

  defp snoozed(note_id, opts) do
    args = %{user_id: Ecto.UUID.generate(), vault_id: Ecto.UUID.generate(), note_id: note_id}
    {:ok, job} = Oban.insert(CheckpointNote.new(args, [schedule_in: 60] ++ opts))
    job
  end

  defp seconds_out(job), do: DateTime.diff(Repo.reload!(job).scheduled_at, DateTime.utc_now())

  test "re-times only the note's crdt_checkpoint job" do
    note_id = Ecto.UUID.generate()
    ours = snoozed(note_id, [])
    other_queue = snoozed(note_id, queue: :default)
    other_note = snoozed(Ecto.UUID.generate(), [])

    assert CheckpointNote.retime_snoozed(note_id) == 1

    assert seconds_out(ours) <= CheckpointNote.room_exit_delay_s()
    assert seconds_out(other_queue) > 30
    assert seconds_out(other_note) > 30
  end
end
