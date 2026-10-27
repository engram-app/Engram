defmodule Engram.NotesFanoutBoundsTest do
  # #2169: a cascade over N notes must cost O(N / chunk) Oban insert
  # statements, not O(N). The count is the `INSERT INTO "oban_jobs"` statements
  # the calling process issues; each is one pool checkout.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Notes
  alias Engram.Workers.DeleteNoteIndex

  @n 8

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp seed(user, vault, folder, n \\ @n) do
    for i <- 1..n do
      {:ok, note} =
        Notes.upsert_note(
          user,
          vault,
          %{"path" => "#{folder}/n#{i}.md", "content" => "body #{i}", "mtime" => 1.0},
          actor: "api"
        )

      note
    end
  end

  # Number of `INSERT INTO "oban_jobs"` statements `fun` issues from this process.
  defp oban_insert_statements(fun) do
    test = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:engram, :repo, :query],
      fn _, _, %{query: q}, _ ->
        if self() == test and q =~ ~r/^INSERT INTO .*"oban_jobs"/, do: send(test, :oban_insert)
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_inserts(0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_inserts(n) do
    receive do
      :oban_insert -> drain_inserts(n + 1)
    after
      0 -> n
    end
  end

  defp job_note_ids(worker),
    do: [worker: worker] |> all_enqueued() |> Enum.map(& &1.args["note_id"]) |> Enum.sort()

  describe "delete_scanned/4 (folder delete cascade)" do
    test "enqueues the index cleanup in one bulk insert, one job per note", ctx do
      %{user: user, vault: vault} = ctx
      notes = seed(user, vault, "Docs")
      {:ok, matches} = Notes.scan_folders(user, vault, ["Docs"])

      {{:ok, %{notes: @n}}, inserts} =
        oban_insert_statements(fn -> Notes.delete_scanned(user, vault, matches) end)

      # ReleaseIndexEntries.enqueue is one more insert; the cleanup jobs are
      # one. Per-note inserts would be at least @n.
      assert inserts <= 2
      assert job_note_ids(DeleteNoteIndex) == notes |> Enum.map(& &1.id) |> Enum.sort()
    end
  end
end
