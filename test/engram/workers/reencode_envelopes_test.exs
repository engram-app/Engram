defmodule Engram.Workers.ReencodeEnvelopesTest do
  # async: false: flips the global :envelope_compression flag to seed format 0
  # rows, and the RLS describe changes the connection's role.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.RlsCase
  import ExUnit.CaptureLog

  alias Engram.Accounts.User
  alias Engram.{Crypto, Notes}
  alias Engram.Crypto.{Envelope, RotationLock}
  alias Engram.Notes.{CrdtUpdateLog, Note, VaultIndexState, VaultIndexUpdateLog}
  alias Engram.Workers.ReencodeEnvelopes

  @big String.duplicate("a compressible line of note text\n", 40)

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  # Writes with the policy off, so every envelope is format 0 (12-byte nonce).
  defp legacy(fun) do
    Application.put_env(:engram, :envelope_compression, false)

    try do
      fun.()
    after
      Application.put_env(:engram, :envelope_compression, true)
    end
  end

  defp tenant!(user, fun) do
    {:ok, v} = Repo.with_tenant(user.id, fun)
    v
  end

  defp legacy_note!(user, vault, path, content) do
    legacy(fn ->
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")
    end)

    Engram.Fixtures.raw_note_by_path!(user, path)
  end

  defp seed_crdt_state!(user, note, state) do
    {:ok, {ct, nonce}} = legacy(fn -> Crypto.encrypt_crdt_state(state, user, note.id) end)

    tenant!(user, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^note.id),
        set: [crdt_state_ciphertext: ct, crdt_state_nonce: nonce]
      )
    end)

    # Separately: the trigger NULLs crdt_head in the same UPDATE as a state write.
    tenant!(user, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^note.id), set: [crdt_head: "warm"])
    end)
  end

  defp seed_tail!(user, vault, note, update) do
    {:ok, {ct, nonce}} = legacy(fn -> Crypto.encrypt_crdt_state(update, user, note.id) end)

    tenant!(user, fn ->
      %CrdtUpdateLog{}
      |> CrdtUpdateLog.changeset(%{
        note_id: note.id,
        user_id: user.id,
        vault_id: vault.id,
        update_ciphertext: ct,
        update_nonce: nonce
      })
      |> Repo.insert!()
    end)
  end

  defp seed_index_state!(user, vault, state) do
    {:ok, {ct, nonce}} = legacy(fn -> Crypto.encrypt_index_state(state, user, vault.id) end)
    now = DateTime.utc_now()

    tenant!(user, fn ->
      Repo.insert_all(VaultIndexState, [
        %{
          vault_id: vault.id,
          user_id: user.id,
          state_ciphertext: ct,
          state_nonce: nonce,
          inserted_at: now,
          updated_at: now
        }
      ])
    end)
  end

  defp seed_index_tail!(user, vault, update) do
    id = Ecto.UUID.generate()
    {:ok, {ct, nonce}} = legacy(fn -> Crypto.encrypt_index_update(update, user, id) end)

    tenant!(user, fn ->
      Repo.insert_all(VaultIndexUpdateLog, [
        %{
          id: id,
          vault_id: vault.id,
          user_id: user.id,
          update_ciphertext: ct,
          update_nonce: nonce,
          inserted_at: DateTime.utc_now()
        }
      ])
    end)

    id
  end

  defp reload(schema, clauses),
    do: Repo.one!(from(r in schema, where: ^clauses), skip_tenant_check: true)

  defp dek(user), do: elem(Crypto.get_dek(Repo.get!(User, user.id)), 1)

  defp open!(ct, nonce, user, aad) do
    {:ok, pt} = Envelope.decrypt(ct, nonce, dek(user), aad)
    pt
  end

  defp run(user), do: perform_job(ReencodeEnvelopes, %{"user_id" => user.id})

  describe "perform/1" do
    test "re-encodes every legacy column to format 1, same plaintext", %{user: u, vault: v} do
      note = legacy_note!(u, v, "a.md", @big)
      seed_crdt_state!(u, note, @big <> "state")
      seed_tail!(u, v, note, @big <> "tail")
      seed_index_state!(u, v, @big <> "index")
      tail_id = seed_index_tail!(u, v, @big <> "index tail")

      before = reload(Note, id: note.id)
      assert byte_size(before.content_nonce) == 12
      assert byte_size(before.crdt_state_nonce) == 12

      assert :ok = run(u)

      n = reload(Note, id: note.id)
      assert byte_size(n.content_nonce) == 13
      assert byte_size(n.crdt_state_nonce) == 13

      assert open!(
               n.content_ciphertext,
               n.content_nonce,
               u,
               Crypto.aad_for_row(:notes, :content, n.id)
             ) == @big

      assert open!(
               n.crdt_state_ciphertext,
               n.crdt_state_nonce,
               u,
               Crypto.aad_for_row(:notes, :crdt_state, n.id)
             ) == @big <> "state"

      # Only the envelope columns move. The trigger NULLs crdt_head on a
      # crdt_state rewrite (WarmCrdtHeads re-warms it); nothing else changes.
      assert {n.updated_at, n.version, n.seq} == {before.updated_at, before.version, before.seq}

      assert {n.title_ciphertext, n.path_ciphertext, n.dek_version} ==
               {before.title_ciphertext, before.path_ciphertext, before.dek_version}

      assert before.crdt_head == "warm"
      assert is_nil(n.crdt_head)

      tail = reload(CrdtUpdateLog, note_id: note.id)
      assert byte_size(tail.update_nonce) == 13

      assert open!(
               tail.update_ciphertext,
               tail.update_nonce,
               u,
               Crypto.aad_for_row(:notes, :crdt_state, note.id)
             ) == @big <> "tail"

      s = reload(VaultIndexState, vault_id: v.id)
      assert byte_size(s.state_nonce) == 13

      assert open!(
               s.state_ciphertext,
               s.state_nonce,
               u,
               Crypto.aad_for_row(:vault_index_states, :state, v.id)
             ) == @big <> "index"

      t = reload(VaultIndexUpdateLog, id: tail_id)
      assert byte_size(t.update_nonce) == 13

      assert open!(
               t.update_ciphertext,
               t.update_nonce,
               u,
               Crypto.aad_for_row(:vault_index_update_log, :update, tail_id)
             ) == @big <> "index tail"

      refute ReencodeEnvelopes.legacy_rows?(u.id)
    end

    # The crdt_state rewrite NULLs every head (trigger); rotation re-warms right
    # after its sweep (#1341), and so does this, instead of waiting for the
    # hourly WarmCrdtHeads.
    test "finishing the notes crdt_state column enqueues a head re-warm per vault",
         %{user: u, vault: v} do
      other_vault = insert(:vault, user: u)
      note = legacy_note!(u, v, "a.md", @big)
      seed_crdt_state!(u, note, @big <> "state")
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.BackfillCrdtHead"))

      assert :ok = run(u)

      for vault <- [v, other_vault],
          do:
            assert_enqueued(
              worker: Engram.Workers.BackfillCrdtHead,
              args: %{"user_id" => u.id, "vault_id" => vault.id}
            )
    end

    # The note's CRDT state is never empty (a Yjs doc encodes to bytes), so it
    # is real work; the 16-byte body is not, and survives the pass untouched.
    test "an empty note body stays format 0 and is not work", %{user: u, vault: v} do
      note = legacy_note!(u, v, "empty.md", "")
      n = reload(Note, id: note.id)
      assert byte_size(n.content_ciphertext) == 16

      assert :ok = run(u)
      refute ReencodeEnvelopes.legacy_rows?(u.id)
      after_run = reload(Note, id: note.id)

      assert {after_run.content_ciphertext, after_run.content_nonce} ==
               {n.content_ciphertext, n.content_nonce}
    end

    test "a pre-T3.6 (dek_version 1) note body is not work: its empty AAD cannot compress",
         %{user: u, vault: v} do
      note = legacy_note!(u, v, "v1.md", @big)

      tenant!(u, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id),
          set: [dek_version: 1, crdt_state_ciphertext: nil, crdt_state_nonce: nil]
        )
      end)

      refute ReencodeEnvelopes.legacy_rows?(u.id)
    end

    test "a row changed since it was read is not overwritten (CAS)", %{user: u, vault: v} do
      note = legacy_note!(u, v, "a.md", @big)
      stale = reload(Note, id: note.id)

      {fresh_ct, fresh_nonce} =
        Envelope.encrypt("edited", dek(u), Crypto.aad_for_row(:notes, :content, note.id))

      tenant!(u, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id),
          set: [content_ciphertext: fresh_ct, content_nonce: fresh_nonce]
        )
      end)

      assert {0, _} =
               tenant!(u, fn ->
                 ReencodeEnvelopes.write_row(
                   :notes_content,
                   note.id,
                   stale.content_ciphertext,
                   "x",
                   "y"
                 )
               end)

      assert reload(Note, id: note.id).content_ciphertext == fresh_ct
    end

    test "a user mid-rotation is snoozed with no writes", %{user: u, vault: v} do
      note = legacy_note!(u, v, "a.md", @big)
      before = reload(Note, id: note.id)
      {:ok, _} = RotationLock.acquire(u.id)

      assert {:snooze, _} = run(u)
      assert reload(Note, id: note.id) == before
    end

    # A crashed rotation keeps its lock on purpose; a job snoozing behind it
    # forever would hold the user's chain. After the cap it cancels and the
    # next hourly pass re-enqueues once the lock clears.
    test "a job snoozed past the cap behind a rotation lock cancels with a warning",
         %{user: u, vault: v} do
      note = legacy_note!(u, v, "a.md", @big)
      before = reload(Note, id: note.id)
      {:ok, _} = RotationLock.acquire(u.id)

      assert {:snooze, _} =
               perform_job(ReencodeEnvelopes, %{"user_id" => u.id}, meta: %{"snoozed" => 59})

      log =
        capture_log([level: :warning], fn ->
          assert {:cancel, :rotation_locked} =
                   perform_job(ReencodeEnvelopes, %{"user_id" => u.id}, meta: %{"snoozed" => 60})
        end)

      assert log =~ "rotation lock"
      assert log =~ u.id
      assert reload(Note, id: note.id) == before
    end

    test "an undecryptable row is logged, left, and keeps the user listed", %{user: u, vault: v} do
      note = legacy_note!(u, v, "a.md", @big)
      ok = legacy_note!(u, v, "b.md", @big)
      bad = reload(Note, id: note.id)
      <<head::binary-size(byte_size(bad.content_ciphertext) - 1), last>> = bad.content_ciphertext
      corrupt = <<head::binary, Bitwise.bxor(last, 0xFF)>>

      tenant!(u, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id),
          set: [content_ciphertext: corrupt]
        )
      end)

      log = capture_log(fn -> assert :ok = run(u) end)

      assert log =~ "notes_content"
      assert log =~ note.id
      assert reload(Note, id: note.id).content_ciphertext == corrupt
      assert byte_size(reload(Note, id: ok.id).content_nonce) == 13
      assert ReencodeEnvelopes.legacy_rows?(u.id)
    end
  end

  describe "bounded runs, kill switch, gate, reads" do
    setup do
      on_exit(fn -> Application.delete_env(:engram, ReencodeEnvelopes) end)
    end

    defp tune(opts), do: Application.put_env(:engram, ReencodeEnvelopes, opts)

    defp drain_chain(count \\ 0) do
      case all_enqueued(worker: ReencodeEnvelopes) do
        [] ->
          count

        [job | _] ->
          Repo.delete!(job)
          assert :ok = perform_job(ReencodeEnvelopes, job.args)
          drain_chain(count + 1)
      end
    end

    test "with the kill switch set, an in-flight job cancels and writes nothing",
         %{user: u, vault: v} do
      note = legacy_note!(u, v, "a.md", @big)
      before = reload(Note, id: note.id)
      Application.put_env(:engram, :envelope_compression, false)
      on_exit(fn -> Application.put_env(:engram, :envelope_compression, true) end)

      assert {:cancel, :compression_off} = run(u)
      assert reload(Note, id: note.id) == before
    end

    test "compression turning off mid-job stops it before the next chunk",
         %{user: u, vault: v} do
      [a, b] =
        Enum.sort([legacy_note!(u, v, "a.md", @big).id, legacy_note!(u, v, "b.md", @big).id])

      tune(chunk_bytes: 1)
      handler = "switch-off-after-chunk-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :reencode_envelopes, :chunk],
        fn _e, _m, _meta, _c -> Application.put_env(:engram, :envelope_compression, false) end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler)
        Application.put_env(:engram, :envelope_compression, true)
      end)

      assert {:cancel, :compression_off} = run(u)
      assert byte_size(reload(Note, id: a).content_nonce) == 13
      assert byte_size(reload(Note, id: b).content_nonce) == 12
    end

    test "out of budget: hands off its cursor to a successor while still running",
         %{user: u, vault: v} do
      [a, b] =
        Enum.sort([legacy_note!(u, v, "a.md", @big).id, legacy_note!(u, v, "b.md", @big).id])

      tune(budget_ms: 0, batch_size: 1)

      assert :ok = run(u)

      # The successor exists as soon as this job returns: the chain never
      # has a gap in which discovery could start a second one.
      assert [job] = all_enqueued(worker: ReencodeEnvelopes)
      assert job.args == %{"user_id" => u.id, "column" => "notes_content", "after" => a}
      assert job.priority == 3
      assert Engram.DataMigrations.jobs_in_flight?(ReencodeEnvelopes)
      assert byte_size(reload(Note, id: a).content_nonce) == 13
      assert byte_size(reload(Note, id: b).content_nonce) == 12

      assert drain_chain() > 1
      refute ReencodeEnvelopes.legacy_rows?(u.id)
    end

    test "unique: hand_off is not blocked by its own executing predecessor, and a duplicate enqueue is dropped",
         %{user: u, vault: v} do
      legacy_note!(u, v, "a.md", @big)
      legacy_note!(u, v, "b.md", @big)
      tune(budget_ms: 0, batch_size: 1)

      # Stand-in for the running predecessor, as Oban holds it while it runs.
      {:ok, me} = Oban.insert(ReencodeEnvelopes.new(%{"user_id" => u.id}))
      Repo.update_all(from(j in Oban.Job, where: j.id == ^me.id), set: [state: "executing"])

      assert :ok = ReencodeEnvelopes.perform(me)
      assert [%{args: %{"column" => "notes_content"}}] = all_enqueued(worker: ReencodeEnvelopes)

      # run_pass racing the chain: dropped by `unique` while the hop is pending.
      assert ReencodeEnvelopes.enqueue_missing() == 1
      assert length(all_enqueued(worker: ReencodeEnvelopes)) == 1
    end

    test "a rescued predecessor whose successor exists cancels without writing",
         %{user: u, vault: v} do
      note = legacy_note!(u, v, "a.md", @big)
      before = reload(Note, id: note.id)

      {:ok, successor} =
        Oban.insert(
          ReencodeEnvelopes.new(%{
            "user_id" => u.id,
            "column" => "notes_content",
            "after" => note.id
          })
        )

      rescued = %Oban.Job{id: successor.id - 1, args: %{"user_id" => u.id}}
      assert {:cancel, :superseded} = ReencodeEnvelopes.perform(rescued)
      assert reload(Note, id: note.id) == before
    end

    # Discovery can insert a second chain while the first one starts running
    # (its executing snapshot is taken before the insert). The later starter
    # yields to the lower-id executing job; ids break a tie, so two
    # simultaneous starters never both cancel.
    test "a job with a lower-id executing job for the same user cancels as a duplicate",
         %{user: u, vault: v} do
      note = legacy_note!(u, v, "a.md", @big)
      before = reload(Note, id: note.id)

      {:ok, running} = Oban.insert(ReencodeEnvelopes.new(%{"user_id" => u.id}))
      Repo.update_all(from(j in Oban.Job, where: j.id == ^running.id), set: [state: "executing"])

      starter = %Oban.Job{id: running.id + 1, args: %{"user_id" => u.id}}
      assert {:cancel, :duplicate} = ReencodeEnvelopes.perform(starter)
      assert reload(Note, id: note.id) == before
    end

    test "a job proceeds when only a higher-id job for the same user is executing",
         %{user: u, vault: v} do
      note = legacy_note!(u, v, "a.md", @big)

      {:ok, later} = Oban.insert(ReencodeEnvelopes.new(%{"user_id" => u.id}))
      Repo.update_all(from(j in Oban.Job, where: j.id == ^later.id), set: [state: "executing"])

      starter = %Oban.Job{id: later.id - 1, args: %{"user_id" => u.id}}
      assert :ok = ReencodeEnvelopes.perform(starter)
      assert byte_size(reload(Note, id: note.id).content_nonce) == 13
    end

    test "a rotation locked BETWEEN batches stops further writes", %{user: u, vault: v} do
      [a, b] =
        Enum.sort([legacy_note!(u, v, "a.md", @big).id, legacy_note!(u, v, "b.md", @big).id])

      tune(batch_size: 1)
      handler = "lock-on-second-batch-#{System.unique_integer([:positive])}"
      seen = :counters.new(1, [])

      :telemetry.attach(
        handler,
        [:engram, :reencode_envelopes, :batch],
        fn _e, _m, _meta, _c ->
          :counters.add(seen, 1, 1)
          if :counters.get(seen, 1) == 2, do: {:ok, _} = RotationLock.acquire(u.id)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:snooze, _} = run(u)
      assert byte_size(reload(Note, id: a).content_nonce) == 13
      assert byte_size(reload(Note, id: b).content_nonce) == 12
    end

    test "chunk_by_bytes packs by stored bytes, a lone row over budget is its own chunk" do
      sizes = [{:a, 40}, {:b, 50}, {:c, 500}, {:d, 10}, {:e, 10}]

      assert ReencodeEnvelopes.chunk_by_bytes(sizes, 100) == [[:a, :b], [:c], [:d, :e]]
      assert ReencodeEnvelopes.chunk_by_bytes(sizes, 1) == [[:a], [:b], [:c], [:d], [:e]]
      assert ReencodeEnvelopes.chunk_by_bytes([], 100) == []
    end

    test "a batch is split by the byte budget and each chunk commits on its own",
         %{user: u, vault: v} do
      huge = String.duplicate(@big, 50)

      ids =
        for {path, body} <- [{"a.md", @big}, {"b.md", @big}, {"c.md", huge}],
            do: legacy_note!(u, v, path, body).id

      # Every row is over a 1-byte budget, so one chunk per row; the huge one
      # still progresses.
      tune(chunk_bytes: 1)
      handler = "reencode-chunks-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:engram, :reencode_envelopes, :chunk],
        fn _e, m, meta, _c ->
          send(parent, {:chunk, meta.column, m.count, Repo.in_transaction?()})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert :ok = run(u)

      for _ <- ids, do: assert_received({:chunk, :notes_content, 1, false})
      refute_received {:chunk, :notes_content, _, _}

      for id <- ids, do: assert(byte_size(reload(Note, id: id).content_nonce) == 13)
    end

    test "reads only the key, AAD id and the one ct + nonce pair", %{user: u, vault: v} do
      legacy_note!(u, v, "a.md", @big)
      handler = "reencode-sql-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:engram, :repo, :query],
        fn _e, _m, meta, _c -> send(parent, {:sql, meta.query}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      assert :ok = run(u)
      :telemetry.detach(handler)

      selects =
        Stream.repeatedly(fn ->
          receive do
            {:sql, q} -> q
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)
        |> Enum.filter(&(&1 =~ ~r/^SELECT .*content_ciphertext/))

      assert selects != []

      for q <- selects,
          do: refute(q =~ ~r/title_ciphertext|path_ciphertext|crdt_state_ciphertext/)
    end
  end

  describe "enqueue_missing/0" do
    test "enqueues only users with legacy rows", %{user: u, vault: v} do
      {:ok, other} = Engram.Fixtures.user_with_dek_fixture()
      legacy_note!(u, v, "a.md", @big)

      assert ReencodeEnvelopes.enqueue_missing() == 1

      assert_enqueued(
        worker: ReencodeEnvelopes,
        args: %{"user_id" => u.id},
        queue: :crypto_backfill,
        priority: 3
      )

      refute_enqueued(worker: ReencodeEnvelopes, args: %{"user_id" => other.id})
    end
  end

  describe "under FORCE RLS" do
    # CONTROL: without it a green result below is ambiguous between "scoped"
    # and "the role drop never engaged".
    test "control: the dropped role with no tenant sees none of the user's notes",
         %{user: u, vault: v} do
      legacy_note!(u, v, "a.md", @big)

      assert 0 ==
               as_prod_role_committing(fn ->
                 Repo.one(from(n in Note, where: n.user_id == ^u.id, select: count(n.id)),
                   skip_tenant_check: true
                 )
               end)
    end

    test "discovery finds the user and the worker's writes land", %{user: u, vault: v} do
      note = legacy_note!(u, v, "a.md", @big)

      assert as_prod_role_committing(fn -> ReencodeEnvelopes.legacy_rows?(u.id) end)
      assert :ok = as_prod_role_committing(fn -> run(u) end)
      assert byte_size(reload(Note, id: note.id).content_nonce) == 13
    end
  end
end
