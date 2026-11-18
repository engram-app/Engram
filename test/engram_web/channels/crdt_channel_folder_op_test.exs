defmodule EngramWeb.CrdtChannelFolderOpTest do
  # The plugin's `folder_op` frame (#2523 S4) behind the `folder_ops` switch.
  use EngramWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Crypto, Folders, Repo, Vaults}
  alias Engram.Folders.Rows
  alias Engram.ServiceConfig

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    on_exit(fn -> EngramWeb.RateLimiter.reset_buckets!() end)

    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "FolderOpTest", Ecto.UUID.generate())
    {:ok, _} = Folders.create_markers(user, vault, ["A", "B"])
    %{user: user, vault: vault, a: id_of(user, vault, "A"), b: id_of(user, vault, "B")}
  end

  defp id_of(user, vault, path),
    do: Repo.with_tenant!(user.id, fn -> Rows.ids_by_path(user, vault.id, [path]) end)[path]

  defp join!(user, vault) do
    socket =
      socket(EngramWeb.UserSocket, "user_#{user.id}", %{
        current_user: user,
        current_api_key: nil,
        device_id: "dev-1"
      })

    {:ok, _, joined} =
      subscribe_and_join(socket, EngramWeb.CrdtChannel, "crdt:#{user.id}:#{vault.id}", %{
        "crdt_proto" => 2
      })

    Sandbox.allow(Repo, self(), joined.channel_pid)
    joined
  end

  # Every sync-topic broadcast still in the mailbox, as {event, payload}.
  defp drain(acc) do
    receive do
      %Phoenix.Socket.Broadcast{event: e, payload: p} -> drain([{e, p} | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp move(folder_id, parent_id, name),
    do: %{
      "op" => "move",
      "op_id" => "op-1",
      "folder_id" => folder_id,
      "parent_id" => parent_id,
      "name" => name
    }

  describe "switch off" do
    test "folder_op gets the unknown-event reply", %{user: user, vault: vault, a: a, b: b} do
      socket = join!(user, vault)

      ref = push(socket, "no_such_event", %{})
      assert_reply ref, :error, unknown

      ref = push(socket, "folder_op", move(a, b, "A"))
      assert_reply ref, :error, ^unknown
      assert id_of(user, vault, "A") == a
    end

    test "the crdt_create reply carries no folder_id", %{user: user, vault: vault} do
      socket = join!(user, vault)
      ref = push(socket, "crdt_create", %{"doc_id" => Ecto.UUID.generate(), "path" => "A/n.md"})
      assert_reply ref, :ok, reply
      refute Map.has_key?(reply, :folder_id)
      refute Map.has_key?(reply, :folders)
    end

    test "the join replies do not advertise folder_ops", %{user: user, vault: vault} do
      {:ok, reply, _} = subscribe_and_join(user_socket(user), "user:#{user.id}", %{})
      refute reply.features[:folder_ops]

      {:ok, reply, _} = join_sync(user_socket(user), user, vault)
      refute reply.features[:folder_ops]
    end
  end

  describe "switch on" do
    setup do
      ServiceConfig.put_override(:folder_ops, true)
      :ok
    end

    test "the join replies advertise folder_ops", %{user: user, vault: vault} do
      {:ok, reply, _} = subscribe_and_join(user_socket(user), "user:#{user.id}", %{})
      assert reply.features.folder_ops == true

      {:ok, reply, _} = join_sync(user_socket(user), user, vault)
      assert reply.features.folder_ops == true
    end

    test "move acks the op's seq and broadcasts with this device's id",
         %{user: user, vault: vault, a: a, b: b} do
      :ok = EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      socket = join!(user, vault)

      ref = push(socket, "folder_op", move(a, b, "A"))
      assert_reply ref, :ok, %{folder_id: ^a, seq: seq}
      assert seq == Vaults.current_seq(user.id, vault.id)
      assert id_of(user, vault, "B/A") == a

      assert_receive %Phoenix.Socket.Broadcast{event: "folder_changed", payload: changed}
      assert %{folder_id: ^a, parent_id: ^b, name: "A", seq: ^seq, device_id: "dev-1"} = changed
    end

    test "a replay of the same move acks the current seq without bumping it",
         %{user: user, vault: vault, a: a, b: b} do
      socket = join!(user, vault)

      ref = push(socket, "folder_op", move(a, b, "A"))
      assert_reply ref, :ok, %{seq: seq}

      ref = push(socket, "folder_op", move(a, b, "A"))
      assert_reply ref, :ok, %{seq: ^seq}
      assert Vaults.current_seq(user.id, vault.id) == seq
    end

    test "a rename in place keeps the parent", %{user: user, vault: vault, a: a} do
      socket = join!(user, vault)

      ref = push(socket, "folder_op", move(a, nil, "Renamed"))
      assert_reply ref, :ok, %{seq: _}
      assert id_of(user, vault, "Renamed") == a
    end

    test "A into B, then B into A, refuses the second as a cycle",
         %{user: user, vault: vault, a: a, b: b} do
      socket = join!(user, vault)

      ref = push(socket, "folder_op", move(a, b, "A"))
      assert_reply ref, :ok, _

      ref = push(socket, "folder_op", move(b, a, "B"))
      assert_reply ref, :error, %{reason: "cycle"}
      assert id_of(user, vault, "B/A") == a
    end

    test "a move into itself is a cycle", %{user: user, vault: vault, a: a} do
      socket = join!(user, vault)
      ref = push(socket, "folder_op", move(a, a, "A"))
      assert_reply ref, :error, %{reason: "cycle"}
    end

    test "a taken name is a conflict", %{user: user, vault: vault, a: a} do
      socket = join!(user, vault)
      ref = push(socket, "folder_op", move(a, nil, "B"))
      assert_reply ref, :error, %{reason: "conflict"}
    end

    # Collisions below the target (S/sub onto D/sub), which the gate cannot
    # see. A marker one raised a unique_violation from the cascade and crashed
    # the channel process (e2e run 44283703701): it merges now (#2468), and a
    # note one is a conflict. Either way the channel takes the next op.
    test "a landed marker merges and the channel stays up",
         %{user: user, vault: vault, b: b} do
      {:ok, _} = Folders.create_markers(user, vault, ["S/sub", "D/sub"])

      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{"path" => "S/sub/n.md", "content" => "x"},
          actor: "api"
        )

      s = id_of(user, vault, "S")
      socket = join!(user, vault)

      ref = push(socket, "folder_op", move(s, nil, "D"))
      assert_reply ref, :ok, _
      assert {:ok, _} = Engram.Notes.get_note(user, vault, "D/sub/n.md")

      live = user |> Engram.Notes.list_folder_markers(vault) |> Enum.map(& &1.folder)
      assert Enum.count(live, &(&1 == "D/sub")) == 1
      refute "S/sub" in live

      d = id_of(user, vault, "D")
      ref = push(socket, "folder_op", move(d, b, "D"))
      assert_reply ref, :ok, %{folder_id: ^d}
    end

    # REGRESSION GUARD (passes on its introducing commit): the merge
    # tombstones the moving S/sub marker, and no client must read that as a
    # deletion. Markers never ride the channel or the catch-up feed, so the
    # only delete legs are the moved note's own old-path ones, the same as a
    # rename with no collision: each carries the id that now lives at D/.
    test "a marker merge sends no deletion beyond the moved notes' old paths",
         %{user: user, vault: vault} do
      {:ok, _} = Folders.create_markers(user, vault, ["S/sub", "D/sub"])

      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{"path" => "S/sub/n.md", "content" => "x"},
          actor: "api"
        )

      before = Vaults.current_seq(user.id, vault.id)
      :ok = EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      socket = join!(user, vault)

      ref = push(socket, "folder_op", move(id_of(user, vault, "S"), nil, "D"))
      assert_reply ref, :ok, _
      assert_receive %Phoenix.Socket.Broadcast{event: "folder_changed"}, 1_000

      # Payloads mix atom and string keys; compare on strings.
      events = for {e, p} <- drain([]), do: {e, Map.new(p, fn {k, v} -> {to_string(k), v} end)}
      refute Enum.any?(events, &match?({"folder_changed", %{"deleted" => true}}, &1))

      deletes =
        for {"note_changed", %{"event_type" => "delete"} = p} <- events,
            do: {p["path"], p["id"] || p["note_id"]}

      assert [{"S/sub/n.md", note.id}] == deletes

      page = Engram.Sync.merged_changes_page(user, vault, before, nil, 100, :meta).page
      refute Enum.any?(page, &(&1[:kind] == "folder"))

      gone = for %{deleted: true, path: path} <- page, do: path
      assert gone == ["S/sub/n.md"], "catch-up page deletes: #{inspect(gone)}"

      assert [%{id: live_id}] = for(%{deleted: false, path: "D/sub/n.md"} = c <- page, do: c)
      assert live_id == note.id
    end

    test "a landed note is a conflict and the channel stays up",
         %{user: user, vault: vault, b: b} do
      for path <- ["S/sub/x.md", "D/sub/x.md"] do
        {:ok, _} =
          Engram.Notes.upsert_note(user, vault, %{"path" => path, "content" => "x"}, actor: "api")
      end

      s = id_of(user, vault, "S")
      socket = join!(user, vault)

      ref = push(socket, "folder_op", move(s, nil, "D"))
      assert_reply ref, :error, %{reason: "conflict"}
      assert id_of(user, vault, "S") == s

      ref = push(socket, "folder_op", move(s, b, "S"))
      assert_reply ref, :ok, %{folder_id: ^s}
    end

    test "an unknown folder or parent is not_found", %{user: user, vault: vault, a: a} do
      socket = join!(user, vault)

      ref = push(socket, "folder_op", move(Ecto.UUID.generate(), nil, "X"))
      assert_reply ref, :error, %{reason: "not_found"}

      ref = push(socket, "folder_op", move(a, Ecto.UUID.generate(), "A"))
      assert_reply ref, :error, %{reason: "not_found"}
    end

    # M2: ids from another vault of the same user, or another user's vault,
    # never resolve. The superuser suite bypasses RLS, so this pins the
    # `vault_id` filter itself; the RLS proof is FolderOpsRlsTest.
    test "a folder or parent from another vault or user is not_found, nothing changes",
         %{user: user, vault: vault, a: a} do
      vault2 = insert(:vault, user: user)
      other = insert(:user)
      {:ok, other} = Crypto.ensure_user_dek(other)
      {:ok, vault3, _} = Vaults.register_vault(other, "Theirs", Ecto.UUID.generate())

      foreign =
        for {u, v} <- [{user, vault2}, {other, vault3}] do
          {:ok, _} = Folders.create_markers(u, v, ["F"])
          {u, v, id_of(u, v, "F")}
        end

      socket = join!(user, vault)

      for {u, v, f} <- foreign do
        ref = push(socket, "folder_op", move(f, nil, "Stolen"))
        assert_reply ref, :error, %{reason: "not_found"}

        ref = push(socket, "folder_op", move(a, f, "A"))
        assert_reply ref, :error, %{reason: "not_found"}

        ref = push(socket, "folder_op", %{"op" => "create", "parent_id" => f, "name" => "In"})
        assert_reply ref, :error, %{reason: "not_found"}

        assert id_of(u, v, "F") == f
        assert id_of(u, v, "F/In") == nil
      end

      assert id_of(user, vault, "A") == a
      assert id_of(user, vault, "Stolen") == nil
    end

    # L2: a live folder row with no marker and no notes (the last note under a
    # path-made folder was deleted) is listed by the manifest, so it must move.
    test "a folder row with no marker and no notes moves", %{user: user, vault: vault} do
      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{"path" => "E/n.md", "content" => "x"},
          actor: "api"
        )

      :ok = Engram.Notes.delete_note(user, vault, "E/n.md")
      e = id_of(user, vault, "E")
      assert e

      socket = join!(user, vault)
      ref = push(socket, "folder_op", move(e, nil, "E2"))
      assert_reply ref, :ok, %{folder_id: ^e}
      assert id_of(user, vault, "E2") == e
    end

    test "a malformed op is a bad_frame", %{user: user, vault: vault} do
      socket = join!(user, vault)

      for payload <- [move("nope", nil, "A"), %{"op" => "zap"}] do
        ref = push(socket, "folder_op", payload)
        assert_reply ref, :error, %{reason: "bad_frame"}
      end
    end

    test "a name that is not one segment is invalid_name", %{user: user, vault: vault, a: a} do
      socket = join!(user, vault)

      for name <- ["x/y", "", "..", nil] do
        ref = push(socket, "folder_op", move(a, nil, name))
        assert_reply ref, :error, %{reason: "invalid_name"}

        ref = push(socket, "folder_op", %{"op" => "create", "parent_id" => nil, "name" => name})
        assert_reply ref, :error, %{reason: "invalid_name"}
      end

      assert id_of(user, vault, "A") == a
    end

    test "create of a name that exists returns that folder, not a conflict",
         %{user: user, vault: vault, a: a, b: b} do
      socket = join!(user, vault)

      ref = push(socket, "folder_op", %{"op" => "create", "parent_id" => nil, "name" => "A"})
      assert_reply ref, :ok, %{folder_id: ^a}

      # A folder only a note's path made (no marker) is found the same way.
      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{"path" => "B/Derived/n.md", "content" => "x"},
          actor: "api"
        )

      derived = id_of(user, vault, "B/Derived")
      assert derived

      ref = push(socket, "folder_op", %{"op" => "create", "parent_id" => b, "name" => "Derived"})
      assert_reply ref, :ok, %{folder_id: ^derived}
    end

    test "crdt_create replies with the note's folder_id", %{user: user, vault: vault, a: a} do
      socket = join!(user, vault)

      ref = push(socket, "crdt_create", %{"doc_id" => Ecto.UUID.generate(), "path" => "A/n.md"})
      assert_reply ref, :ok, %{folder_id: ^a}

      ref = push(socket, "crdt_create", %{"doc_id" => Ecto.UUID.generate(), "path" => "r.md"})
      assert_reply ref, :ok, %{folder_id: nil, folders: []}
    end

    test "crdt_create replies with the folder chain, root first", %{
      user: user,
      vault: vault,
      a: a
    } do
      socket = join!(user, vault)
      doc = Ecto.UUID.generate()

      ref = push(socket, "crdt_create", %{"doc_id" => doc, "path" => "A/Sub/Deep/n.md"})
      assert_reply ref, :ok, %{folder_id: deep, folders: chain}

      sub = id_of(user, vault, "A/Sub")
      assert deep == id_of(user, vault, "A/Sub/Deep")

      assert chain == [
               %{id: a, parent_id: nil, name: "A"},
               %{id: sub, parent_id: a, name: "Sub"},
               %{id: deep, parent_id: sub, name: "Deep"}
             ]
    end

    test "create is idempotent by path", %{user: user, vault: vault, b: b} do
      socket = join!(user, vault)
      create = %{"op" => "create", "op_id" => "op-2", "parent_id" => b, "name" => "New"}

      ref = push(socket, "folder_op", create)
      assert_reply ref, :ok, %{folder_id: id, seq: seq}
      assert id == id_of(user, vault, "B/New")

      ref = push(socket, "folder_op", create)
      assert_reply ref, :ok, %{folder_id: ^id, seq: ^seq}
    end
  end
end
