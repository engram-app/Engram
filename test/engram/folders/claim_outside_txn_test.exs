defmodule Engram.Folders.ClaimOutsideTxnTest do
  @moduledoc """
  A folder rename or batch move claims its paths in the `filemeta_v0` index
  OUTSIDE any transaction (docs/context/crdt-identity-authority.md).

  `Folders.rename/5` (REST, MCP `rename_folder`, the folder-op wire) and
  `Folders.batch_move/4` (REST batch move) used to claim from inside their
  `atomic/2` transaction: the snapshot write rolled back with the caller while
  a live-room write survived, so a rename the API reported as failed could
  still be executed later by projection.
  """
  use Engram.DataCase, async: false

  alias Engram.{Attachments, Crypto, Folders, Notes, Vaults}
  alias Engram.MCP.Handlers
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexRegistry, Identity}
  alias Yex.Sync.SharedDoc

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
    Mox.stub(Engram.MockStorage, :put, fn _key, _bin, _opts -> :ok end)
    Mox.stub(Engram.MockStorage, :delete, fn _key -> :ok end)

    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "ClaimTxn", Ecto.UUID.generate())

    test_pid = self()
    handler = "claim-in-txn-#{inspect(test_pid)}"

    :telemetry.attach(
      handler,
      [:engram, :crdt, :index_in_transaction],
      fn _event, _m, meta, _ -> send(test_pid, {:claim_in_txn, meta.op}) end,
      nil
    )

    :telemetry.attach(
      handler <> "-claims",
      [:engram, :crdt, :index_claim],
      fn _event, _m, meta, _ -> send(test_pid, {:index_write, meta.op, meta[:phase]}) end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      :telemetry.detach(handler <> "-claims")
      Application.delete_env(:engram, :checkpoint_interleave_hook)
    end)

    %{user: user, vault: vault}
  end

  # A server create writes no index entry (clients do), so each note claims its
  # own path here: "unchanged" is then an exact path, and a release reads nil.
  defp note(ctx, path) do
    {:ok, note} =
      Notes.upsert_note(ctx.user, ctx.vault, %{"path" => path, "content" => "x"}, actor: "api")

    :ok = Identity.claim(ctx.user, ctx.vault.id, [{path, note.id}])
    note
  end

  defp put_att(ctx, path) do
    {:ok, _} =
      Attachments.upsert_attachment(ctx.user, ctx.vault, %{
        "path" => path,
        "content_base64" => Base.encode64("x")
      })
  end

  # The path the live index room holds for `note_id`.
  defp live_path(room, note_id) do
    test_pid = self()

    :ok =
      SharedDoc.update_doc(room, fn doc ->
        map = doc |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.to_map()
        send(test_pid, {:live_map, map})
      end)

    assert_receive {:live_map, map}, 2_000
    Enum.find_value(map, fn {path, v} -> if v["note_id"] == note_id, do: path end)
  end

  test "MCP rename_folder claims outside the transaction", ctx do
    n = note(ctx, "Docs/n.md")

    assert {:ok, _msg, _} =
             Handlers.handle("rename_folder", ctx.user, ctx.vault, %{
               "old_folder" => "Docs",
               "new_folder" => "Archive"
             })

    refute_received {:claim_in_txn, _}
    assert {:ok, %{path: "Archive/n.md"}} = Notes.get_note_by_id(ctx.user, ctx.vault, n.id)
  end

  test "Folders.rename (REST and the folder-op wire) claims outside the transaction", ctx do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    n = note(ctx, "Docs/sub/n.md")

    assert {:ok, %{notes: _}} = Folders.rename(ctx.user, ctx.vault, "Docs", "Archive")

    refute_received {:claim_in_txn, _}
    assert live_path(room, n.id) == "Archive/sub/n.md"
  end

  test "Folders.batch_move (REST batch move) claims outside the transaction", ctx do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    {:ok, parent} = Notes.create_folder_marker(ctx.user, ctx.vault, "Docs")
    {:ok, child} = Notes.create_folder_marker(ctx.user, ctx.vault, "Docs/Sub")
    {:ok, _} = Notes.create_folder_marker(ctx.user, ctx.vault, "Dest")
    a = note(ctx, "Docs/a.md")
    b = note(ctx, "Docs/Sub/b.md")

    # Parent first, then its own child: the child moves twice, and the index
    # must end on its FINAL path.
    assert {:ok, _} =
             Folders.batch_move(ctx.user, ctx.vault, [parent.id, child.id], {:path, "Dest"})

    refute_received {:claim_in_txn, _}
    assert live_path(room, a.id) == "Dest/Docs/a.md"
    assert live_path(room, b.id) == "Dest/Sub/b.md"
    assert {:ok, %{path: "Dest/Sub/b.md"}} = Notes.get_note_by_id(ctx.user, ctx.vault, b.id)
  end

  # The rollback the old shape could not undo: with a live room the claim
  # survived the rolled-back transaction, so projection would later move the
  # note the API had just reported as not moved.
  test "a rename that rolls back leaves the live index where the rows are", ctx do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    n = note(ctx, "Docs/n.md")
    put_att(ctx, "Docs/a.png")
    put_att(ctx, "Archive/a.png")

    flush_index_writes()
    assert {:error, :conflict} = Folders.rename(ctx.user, ctx.vault, "Docs", "Archive")

    # Refused before any claim: no client sees a move and a revert.
    refute_received {:index_write, :claim, :ok}
    assert {:ok, %{path: "Docs/n.md"}} = Notes.get_note_by_id(ctx.user, ctx.vault, n.id)
    assert live_path(room, n.id) == "Docs/n.md"
  end

  # Writes a note into `Docs` each time a claim is made and the transaction is
  # not yet open (`:folder_claimed`), up to `times` times.
  defp race_notes_into_docs(ctx, times) do
    counter = :counters.new(1, [])
    test_pid = self()

    Application.put_env(:engram, :checkpoint_interleave_hook, fn
      :folder_claimed ->
        if :counters.get(counter, 1) < times do
          :counters.add(counter, 1, 1)
          n = note(ctx, "Docs/late#{:counters.get(counter, 1)}.md")
          send(test_pid, {:raced, n.id})
        end

      _ ->
        :ok
    end)

    on_exit(fn -> Application.delete_env(:engram, :checkpoint_interleave_hook) end)
  end

  test "a note written between the claim and the lock is picked up by one retry", ctx do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    n = note(ctx, "Docs/n.md")
    race_notes_into_docs(ctx, 1)

    assert {:ok, %{notes: _}} = Folders.rename(ctx.user, ctx.vault, "Docs", "Archive")

    assert_received {:raced, late_id}
    assert {:ok, %{path: "Archive/late1.md"}} = Notes.get_note_by_id(ctx.user, ctx.vault, late_id)
    assert live_path(room, late_id) == "Archive/late1.md"
    assert live_path(room, n.id) == "Archive/n.md"
    refute_received {:claim_in_txn, _}
  end

  test "a race on both attempts is a conflict and leaves the index unmoved", ctx do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    n = note(ctx, "Docs/n.md")
    race_notes_into_docs(ctx, 2)

    assert {:error, :conflict} = Folders.rename(ctx.user, ctx.vault, "Docs", "Archive")

    assert_received {:raced, _}
    assert_received {:raced, _}
    assert {:ok, %{path: "Docs/n.md"}} = Notes.get_note_by_id(ctx.user, ctx.vault, n.id)
    assert live_path(room, n.id) == "Docs/n.md"
  end

  defp flush_index_writes do
    receive do
      {:index_write, _, _} -> flush_index_writes()
    after
      0 -> :ok
    end
  end

  # Two identical renames (a client retry): B claims, then A runs to commit
  # before B takes the folder lock. B goes stale, and its undo must not move
  # the index back under A's committed rows (ABA on the claimed value).
  test "a duplicate concurrent rename does not revert the committed one", ctx do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    n = note(ctx, "Docs/n.md")
    counter = :counters.new(1, [])
    test_pid = self()

    Application.put_env(:engram, :checkpoint_interleave_hook, fn
      :folder_claimed ->
        if :counters.get(counter, 1) == 0 do
          :counters.add(counter, 1, 1)
          send(test_pid, {:a, Folders.rename(ctx.user, ctx.vault, "Docs", "Archive")})
        end

        :ok

      _ ->
        :ok
    end)

    _b = Folders.rename(ctx.user, ctx.vault, "Docs", "Archive")
    assert_received {:a, {:ok, _}}
    assert {:ok, %{path: "Archive/n.md"}} = Notes.get_note_by_id(ctx.user, ctx.vault, n.id)
    assert live_path(room, n.id) == "Archive/n.md"
  end

  test "the wire's stale id refuses before any claim", ctx do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    n = note(ctx, "Docs/n.md")
    flush_index_writes()

    assert {:error, :not_found} =
             Folders.rename(ctx.user, ctx.vault, "Docs", "Archive",
               expect: {Ecto.UUID.generate(), nil}
             )

    refute_received {:index_write, :claim, :ok}
    assert live_path(room, n.id) == "Docs/n.md"
  end

  test "a batch move races a note into its second folder and one retry takes it", ctx do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    {:ok, m1} = Notes.create_folder_marker(ctx.user, ctx.vault, "Docs")
    {:ok, m2} = Notes.create_folder_marker(ctx.user, ctx.vault, "Other")
    {:ok, _} = Notes.create_folder_marker(ctx.user, ctx.vault, "Dest")
    a = note(ctx, "Docs/a.md")
    _ = note(ctx, "Other/x.md")
    counter = :counters.new(1, [])
    test_pid = self()

    Application.put_env(:engram, :checkpoint_interleave_hook, fn
      :folder_claimed ->
        if :counters.get(counter, 1) == 0 do
          :counters.add(counter, 1, 1)
          send(test_pid, {:raced, note(ctx, "Other/late.md").id})
        end

        :ok

      _ ->
        :ok
    end)

    assert {:ok, _} = Folders.batch_move(ctx.user, ctx.vault, [m1.id, m2.id], {:path, "Dest"})

    assert_received {:raced, late_id}

    assert {:ok, %{path: "Dest/Other/late.md"}} =
             Notes.get_note_by_id(ctx.user, ctx.vault, late_id)

    assert live_path(room, late_id) == "Dest/Other/late.md"
    assert live_path(room, a.id) == "Dest/Docs/a.md"
  end

  test "a batch whose later folder has a known target conflict claims nothing", ctx do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    {:ok, m1} = Notes.create_folder_marker(ctx.user, ctx.vault, "Docs")
    {:ok, m2} = Notes.create_folder_marker(ctx.user, ctx.vault, "Other")
    a = note(ctx, "Docs/a.md")
    x = note(ctx, "Other/x.md")
    _ = note(ctx, "Dest/Other/y.md")
    flush_index_writes()

    assert {:error, {:conflict, _}} =
             Folders.batch_move(ctx.user, ctx.vault, [m1.id, m2.id], {:path, "Dest"})

    refute_received {:index_write, :claim, :ok}
    assert live_path(room, a.id) == "Docs/a.md"
    assert live_path(room, x.id) == "Other/x.md"
  end

  # The conflict appears only after the claim (a race), so the first folder's
  # rows move inside the transaction, roll back, and every claim is reconciled.
  test "a batch that fails on a later folder reconciles every claim", ctx do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    {:ok, m1} = Notes.create_folder_marker(ctx.user, ctx.vault, "Docs")
    {:ok, m2} = Notes.create_folder_marker(ctx.user, ctx.vault, "Other")
    a = note(ctx, "Docs/a.md")
    x = note(ctx, "Other/x.md")

    Application.put_env(:engram, :checkpoint_interleave_hook, fn
      :folder_claimed -> _ = note(ctx, "Dest/Other/y.md")
      _ -> :ok
    end)

    assert {:error, {:conflict, _}} =
             Folders.batch_move(ctx.user, ctx.vault, [m1.id, m2.id], {:path, "Dest"})

    assert {:ok, %{path: "Docs/a.md"}} = Notes.get_note_by_id(ctx.user, ctx.vault, a.id)
    assert live_path(room, a.id) == "Docs/a.md"
    assert live_path(room, x.id) == "Other/x.md"
  end

  # The other ordering of the ABA: an identical rename B has claimed and is
  # waiting for the lock while A (same claim) fails and reconciles the shared
  # entry back to the rows. B then commits; the index must end where B's rows
  # are, or projection would move B's committed rename back.
  test "an identical rename waiting while ours fails still ends with the index on its rows",
       ctx do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    n = note(ctx, "Docs/n.md")
    put_att(ctx, "Docs/a.png")
    counter = :counters.new(1, [])
    test_pid = self()

    Application.put_env(:engram, :checkpoint_interleave_hook, fn
      :folder_claimed ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          # B has claimed: A runs whole and fails on an attachment conflict
          # that appears after its precheck; then the conflict goes away.
          1 ->
            send(test_pid, {:a, Folders.rename(ctx.user, ctx.vault, "Docs", "Archive")})
            :ok = Attachments.delete_attachment(ctx.user, ctx.vault, "Archive/a.png")

          2 ->
            put_att(ctx, "Archive/a.png")

          _ ->
            :ok
        end

        :ok

      _ ->
        :ok
    end)

    assert {:ok, _} = Folders.rename(ctx.user, ctx.vault, "Docs", "Archive")
    assert_received {:a, {:error, :conflict}}
    assert {:ok, %{path: "Archive/n.md"}} = Notes.get_note_by_id(ctx.user, ctx.vault, n.id)
    assert live_path(room, n.id) == "Archive/n.md"
  end

  # Review 2, blocker 1: a later rename of the same note lands between the
  # folder op's commit and its index write that follows; the folder op must not
  # put the index back on its own path. `:claims_settle` is the point just
  # before a claimant's after-transaction index write.
  test "a later rename between a folder op's commit and its settle is kept", ctx do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    n = note(ctx, "Docs/n.md")
    counter = :counters.new(1, [])
    test_pid = self()

    Application.put_env(:engram, :checkpoint_interleave_hook, fn
      :claims_settle ->
        if :counters.get(counter, 1) == 0 do
          :counters.add(counter, 1, 1)
          send(test_pid, {:r, Notes.rename_note(ctx.user, ctx.vault, "Archive/n.md", "C/n.md")})
        end

        :ok

      _ ->
        :ok
    end)

    assert {:ok, _} = Folders.rename(ctx.user, ctx.vault, "Docs", "Archive")
    assert_received {:r, {:ok, _}}
    assert {:ok, %{path: "C/n.md"}} = Notes.get_note_by_id(ctx.user, ctx.vault, n.id)
    assert live_path(room, n.id) == "C/n.md"
  end

  # Review 2, blocker 2: B fails and has read the rows for its compensation;
  # an identical A then commits before B's index write. B must not write the
  # stale path. (With settle the row read happens inside the index step, so
  # the closest the test can get is just before that step.)
  test "an identical rename committing during a failed op's compensation is kept", ctx do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    n = note(ctx, "Docs/n.md")
    put_att(ctx, "Docs/a.png")
    counter = :counters.new(1, [])
    test_pid = self()

    Application.put_env(:engram, :checkpoint_interleave_hook, fn
      :folder_claimed ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == 1, do: put_att(ctx, "Archive/a.png")
        :ok

      :claims_settle ->
        if :counters.get(counter, 1) == 1 do
          :counters.add(counter, 1, 1)
          :ok = Attachments.delete_attachment(ctx.user, ctx.vault, "Archive/a.png")
          send(test_pid, {:a, Folders.rename(ctx.user, ctx.vault, "Docs", "Archive")})
        end

        :ok

      _ ->
        :ok
    end)

    assert {:error, :conflict} = Folders.rename(ctx.user, ctx.vault, "Docs", "Archive")
    assert_received {:a, {:ok, _}}
    assert {:ok, %{path: "Archive/n.md"}} = Notes.get_note_by_id(ctx.user, ctx.vault, n.id)
    assert live_path(room, n.id) == "Archive/n.md"
  end
end
