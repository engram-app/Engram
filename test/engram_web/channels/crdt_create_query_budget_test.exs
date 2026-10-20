defmodule EngramWeb.CrdtCreateQueryBudgetTest do
  # Pins the SQL cost of one first-sync `crdt_create` carrying a genesis body.
  # The channel handles creates inline, so per-create statements bound
  # first-sync throughput (#1877). Exact counts for the stated cache state
  # (request caches cleared, then warmed by one create): update them when a
  # reduction lands; a rise means a new round trip crept onto the hot path.
  use EngramWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Crypto, Repo, TenantQueryCounter, Vaults}
  alias Engram.Notes.CrdtBridge

  # 57 -> 50 (Task 7b): the seed's checkpoint inserts one NoteCommitted
  # dispatcher job instead of the embed clamp read plus three unique inserts.
  # 50 -> 51: the seed's checkpoint reads the rotation lock from the DB
  # (#1341: the cached user may not have seen another node's lock).
  # 51 -> 46, 7 -> 6: the relocate-claim probe no longer opens its own
  # transaction to classify the id; a create that claims nothing classifies once.
  # 46 -> 42, 6 -> 5: the vault_populated probe runs inside the row
  # transaction instead of opening its own after commit.
  # 42 -> 26, 5 -> 1: the genesis seed runs inside the row transaction
  # (#1409 open half), so its with_tenant legs join it instead of opening
  # their own.
  # 26 -> 24: link targets resolve on read, so a create no longer enqueues a
  # RebindNoteLinks job (insert + pg_notify).
  # 24 -> 15: the genesis body goes into the INSERT (the channel decodes the
  # frame first), so the seed's in-transaction checkpoint (row and tail
  # reads, version read, second seq, notes UPDATE, revision, read-back) is
  # gone. One notes version per create instead of two.
  @statements 15
  @tenant_txns 1
  @subscription_reads 0

  defp frame_for_content(content) do
    doc = CrdtBridge.new_doc()
    :ok = CrdtBridge.ingest_plaintext(doc, content)
    {:ok, update} = Yex.encode_state_as_update(doc)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_update, update}})
    Base.encode64(frame)
  end

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Budget", Ecto.UUID.generate())

    {:ok, _, socket} =
      subscribe_and_join(
        user_socket(user),
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        %{
          "crdt_proto" => 2,
          "client_type" => "obsidian"
        }
      )

    Sandbox.allow(Repo, self(), socket.channel_pid)

    # Request caches cleared, then warmed by the vault's first note, so the
    # measured create is a steady-state one.
    Engram.DataCase.clear_request_caches()
    create(socket, "warm.md", "# warm\n\nbody")
    %{socket: socket}
  end

  defp create(socket, path, body) do
    ref =
      push(socket, "crdt_create", %{
        "doc_id" => Ecto.UUID.generate(),
        "path" => path,
        "b64" => frame_for_content(body)
      })

    assert_reply ref, :ok, %{genesis: "stored"}, 5_000
  end

  test "one seeded crdt_create stays inside its statement budget", %{socket: socket} do
    body = "---\ntags: [a]\n---\n# N\n\n" <> String.duplicate("Some [[Link]] text. ", 70)

    queries =
      TenantQueryCounter.count_matching_queries(
        fn -> create(socket, "F/n.md", body) end,
        fn _ -> true end,
        socket.channel_pid
      )

    tenant_txns = Enum.count(queries, &(&1 =~ "set_config('app.current_tenant', $1"))
    subscription_reads = Enum.count(queries, &(&1 =~ ~s(FROM "subscriptions")))

    assert length(queries) == @statements, "#{length(queries)} statements"
    refute Enum.any?(queries, &(&1 =~ ~s(UPDATE "notes"))), "the create rewrote its own row"
    assert tenant_txns == @tenant_txns, "#{tenant_txns} tenant transactions"
    assert subscription_reads == @subscription_reads, "#{subscription_reads} tier reads"
  end

  # Lock order: every note writer (append, move, rename, get_note_for_update)
  # takes the vault row lock (`UPDATE vaults ... change_seq`) BEFORE it writes a
  # note row. A create that inserted first and locked after reversed that order
  # and deadlocked against them (Postgres 40P01), so the lock must come first.
  test "the create takes the vault seq lock before its insert", %{socket: socket} do
    queries =
      TenantQueryCounter.count_matching_queries(
        fn -> create(socket, "F/order.md", "# order") end,
        fn _ -> true end,
        socket.channel_pid
      )

    insert_at = Enum.find_index(queries, &(&1 =~ ~s(INSERT INTO "notes")))
    seq_at = Enum.find_index(queries, &(&1 =~ "change_seq = change_seq + 1"))

    assert insert_at && seq_at
    assert seq_at < insert_at, Enum.join(queries, "\n")
  end
end
