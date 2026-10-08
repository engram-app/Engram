defmodule Engram.DataMigrations.EnvelopeFormatTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.DataMigrations
  alias Engram.DataMigrations.EnvelopeFormat
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Workers.{DataMigrationsRunner, ReencodeEnvelopes}

  @big String.duplicate("a compressible line of note text\n", 40)

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp note!(user, vault, path, content, compression) do
    Application.put_env(:engram, :envelope_compression, compression)

    try do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")
    after
      Application.put_env(:engram, :envelope_compression, true)
    end

    Engram.Fixtures.raw_note_by_path!(user, path)
  end

  test "registered with the runner" do
    assert EnvelopeFormat in DataMigrationsRunner.migrations()
    assert {EnvelopeFormat.name(), EnvelopeFormat.version()} == {"envelope_format", 1}
  end

  # An empty body is format 0 even with the policy on (16-byte tag only).
  test "only empty and format 1 rows: done, nothing enqueued", %{user: u, vault: v} do
    note!(u, v, "empty.md", "", true)
    note!(u, v, "new.md", @big, true)
    note!(u, v, "tiny.md", "hi", true)
    assert byte_size(Engram.Fixtures.raw_note_by_path!(u, "empty.md").content_ciphertext) == 16

    assert EnvelopeFormat.run_pass() == :done
    refute_enqueued(worker: ReencodeEnvelopes)
  end

  test "a legacy row: enqueues its user and stays open", %{user: u, vault: v} do
    note!(u, v, "old.md", @big, false)

    assert EnvelopeFormat.run_pass() == :more
    assert_enqueued(worker: ReencodeEnvelopes, args: %{"user_id" => u.id})
  end

  test "jobs in flight: open, enqueues nothing more", %{user: u, vault: v} do
    note!(u, v, "old.md", @big, false)
    {:ok, _} = Oban.insert(ReencodeEnvelopes.new(%{"user_id" => u.id}))

    assert EnvelopeFormat.run_pass() == :more
    assert length(all_enqueued(worker: ReencodeEnvelopes)) == 1
  end

  # A job pinned for one user (a stale rotation lock snoozing it) must not
  # stall discovery for everyone else.
  test "another user's in-flight job does not stop this user's enqueue", %{user: u, vault: v} do
    {:ok, other} = Engram.Fixtures.user_with_dek_fixture()
    other_vault = insert(:vault, user: other)
    note!(u, v, "old.md", @big, false)
    note!(other, other_vault, "old.md", @big, false)

    {:ok, _} =
      Oban.insert(ReencodeEnvelopes.new(%{"user_id" => u.id}, schedule_in: 60))

    assert EnvelopeFormat.run_pass() == :more
    assert_enqueued(worker: ReencodeEnvelopes, args: %{"user_id" => other.id})
    assert length(all_enqueued(worker: ReencodeEnvelopes, args: %{"user_id" => u.id})) == 1
  end

  # `unique` does not cover :executing, so discovery skips that user itself:
  # a second chain would run beside the first.
  test "a user whose job is executing gets no second job", %{user: u, vault: v} do
    note!(u, v, "old.md", @big, false)
    {:ok, job} = Oban.insert(ReencodeEnvelopes.new(%{"user_id" => u.id}))
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])

    assert EnvelopeFormat.run_pass() == :more

    assert [%{state: "executing"}] =
             Repo.all(
               from(j in Oban.Job,
                 where: j.worker == "Engram.Workers.ReencodeEnvelopes",
                 where: fragment("?->>'user_id' = ?", j.args, ^u.id)
               )
             )
  end

  test "an undecryptable legacy row keeps the migration open", %{user: u, vault: v} do
    note = note!(u, v, "bad.md", @big, false)

    {:ok, _} =
      Repo.with_tenant(u.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id),
          set: [content_ciphertext: :crypto.strong_rand_bytes(200)]
        )
      end)

    assert :ok = perform_job(ReencodeEnvelopes, %{"user_id" => u.id})
    Repo.delete_all(Oban.Job)
    assert EnvelopeFormat.run_pass() == :more
  end

  defp ledger(name), do: Repo.get(Engram.DataMigrations.Entry, name)

  describe "kill switch (enabled?/0)" do
    setup do
      Application.put_env(:engram, :envelope_compression, false)
      on_exit(fn -> Application.put_env(:engram, :envelope_compression, true) end)
    end

    test "the runner skips it entirely: no pass, no ledger row, no job", %{user: u, vault: v} do
      note!(u, v, "old.md", @big, false)
      Application.put_env(:engram, :envelope_compression, false)

      refute EnvelopeFormat.enabled?()
      assert DataMigrationsRunner.run(EnvelopeFormat) == :skipped
      assert is_nil(ledger("envelope_format"))
      refute_enqueued(worker: ReencodeEnvelopes)
    end
  end

  describe "daily re-verify" do
    setup %{user: u, vault: v} do
      note!(u, v, "new.md", @big, true)
      assert DataMigrationsRunner.run(EnvelopeFormat) == :done
      assert DataMigrations.done?("envelope_format", 1)
      :ok
    end

    test "a done migration stays skipped outside the re-verify run", %{user: u, vault: v} do
      note!(u, v, "late.md", @big, false)
      assert DataMigrationsRunner.run(EnvelopeFormat, false) == :skipped
      refute_enqueued(worker: ReencodeEnvelopes)
    end

    test "re-verify with nothing new keeps it done", _ do
      assert DataMigrationsRunner.run(EnvelopeFormat, true) == :done
      assert DataMigrations.done?("envelope_format", 1)
      refute_enqueued(worker: ReencodeEnvelopes)
    end

    test "re-verify reopens it when a legacy row reappears", %{user: u, vault: v} do
      note!(u, v, "late.md", @big, false)

      assert DataMigrationsRunner.run(EnvelopeFormat, true) == :more
      assert is_nil(ledger("envelope_format").completed_at)
      refute DataMigrations.done?("envelope_format", 1)
      assert_enqueued(worker: ReencodeEnvelopes, args: %{"user_id" => u.id})
    end

    test "the 04:00 UTC runner job is the re-verify run", %{user: u, vault: v} do
      note!(u, v, "late.md", @big, false)

      assert :ok =
               perform_job(DataMigrationsRunner, %{}, scheduled_at: ~U[2026-10-08 05:33:00Z])

      assert DataMigrations.done?("envelope_format", 1)

      assert :ok =
               perform_job(DataMigrationsRunner, %{}, scheduled_at: ~U[2026-10-08 04:33:00Z])

      refute DataMigrations.done?("envelope_format", 1)
    end

    test "a migration without reverify?/0 is never re-run once done" do
      Engram.DataMigrations.mark_done(Engram.DataMigrations.CrdtStateSeed.name(), 1)

      assert DataMigrationsRunner.run(Engram.DataMigrations.CrdtStateSeed, true) == :skipped
    end
  end

  test "a full pass then closes it", %{user: u, vault: v} do
    note!(u, v, "old.md", @big, false)
    assert :ok = perform_job(ReencodeEnvelopes, %{"user_id" => u.id})
    assert EnvelopeFormat.run_pass() == :done
  end
end
