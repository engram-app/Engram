defmodule EngramWeb.CrdtChannelFileTimesTest do
  @moduledoc """
  The optional `mtime` / `ctime` (epoch seconds) the plugin attaches to
  `crdt_create`, `crdt_msg` and `crdt_doc_update`.

  Edit frames never write the DB for a time: the room keeps the latest valid
  mtime and first ctime in memory and the checkpoint that already runs writes
  them (mtime only forward, first ctime wins, bad values dropped). A time never
  touches content, hash, version or seq, and never triggers a checkpoint.
  """
  use EngramWeb.ChannelCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Crypto, FileTime, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, Note}

  @t1 1_700_000_000.0
  @t2 1_700_000_500.0
  @stable [:version, :content_hash, :seq]

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    on_exit(fn -> EngramWeb.RateLimiter.reset_buckets!() end)

    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "FileTimesTest", Ecto.UUID.generate())

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "base"}, actor: "api")

    {:ok, _, joined} =
      subscribe_and_join(
        user_socket(user),
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        %{"crdt_proto" => 2}
      )

    Sandbox.allow(Repo, self(), joined.channel_pid)
    %{socket: joined, user: user, vault: vault, note: note}
  end

  defp row(id) do
    Repo.one(
      from(n in Note,
        where: n.id == ^id,
        select: %{
          mtime_at: n.mtime_at,
          ctime_at: n.ctime_at,
          eff_updated: n.eff_updated,
          version: n.version,
          content_hash: n.content_hash,
          seq: n.seq
        }
      ),
      skip_tenant_check: true
    )
  end

  defp secs(nil), do: nil
  defp secs(at), do: DateTime.to_unix(at, :microsecond) / 1_000_000

  defp frame_b64(doc, prefix) do
    Yex.Text.insert(Yex.Doc.get_text(doc, "content"), 0, prefix)
    update_b64(doc)
  end

  defp update_b64(doc) do
    {:ok, update} = Yex.encode_state_as_update(doc)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_update, update}})
    Base.encode64(frame)
  end

  defp server_doc(socket, id) do
    ref = push(socket, "crdt_doc_state", %{"doc_id" => id})
    assert_reply ref, :ok, %{b64: b64}
    {:ok, doc} = CrdtBridge.doc_from_state(Base.decode64!(b64))
    doc
  end

  defp doc_update(socket, id, b64, times) do
    ref = push(socket, "crdt_doc_update", Map.merge(%{"doc_id" => id, "b64" => b64}, times))
    assert_reply ref, :ok, %{doc_id: ^id}, 3000
  end

  defp edit(socket, id, times) do
    doc_update(socket, id, frame_b64(server_doc(socket, id), "E-"), times)
  end

  # Polls until `fun` is truthy: times land at the room's checkpoint.
  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() -> true
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  defp settle, do: Process.sleep(500)

  # Handshake a client doc over `crdt_msg`: leaves a room resident. The server
  # also pushes its own syncStep1 (and an earlier handshake leaves one in the
  # mailbox), so skip pushes until the syncStep2 arrives.
  defp handshake_room(socket, doc_id) do
    client = CrdtBridge.new_doc()
    {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
    push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(frame)})
    :ok = Yex.apply_update(client, await_step2(doc_id))
    client
  end

  defp await_step2(doc_id) do
    assert_push "crdt_msg", %{"doc_id" => ^doc_id, "b64" => b64}, 3000

    case Yex.Sync.message_decode(Base.decode64!(b64)) do
      {:ok, {:sync, {:sync_step2, update}}} -> update
      _other -> await_step2(doc_id)
    end
  end

  test "create with times stores both", %{socket: socket} do
    id = Ecto.UUID.generate()

    ref =
      push(socket, "crdt_create", %{
        "doc_id" => id,
        "path" => "new.md",
        "mtime" => @t2,
        "ctime" => @t1
      })

    assert_reply ref, :ok, %{doc_id: ^id}
    assert %{mtime_at: m, ctime_at: c} = row(id)
    assert secs(m) == @t2
    assert secs(c) == @t1
  end

  test "create adopting an existing note keeps its first ctime and takes a newer mtime",
       %{socket: socket, user: user, vault: vault, note: note} do
    assert {:ok, 1} = Notes.put_frame_times(user, vault, note.id, @t1, @t1)

    other = Ecto.UUID.generate()

    ref =
      push(socket, "crdt_create", %{
        "doc_id" => other,
        "path" => "p.md",
        "mtime" => @t2,
        "ctime" => @t2
      })

    assert_reply ref, :ok, %{doc_id: adopted}
    assert adopted == note.id
    assert %{mtime_at: m, ctime_at: c} = row(note.id)
    assert {secs(m), secs(c)} == {@t2, @t1}
  end

  test "an edit (crdt_doc_update) stores its mtime at the checkpoint", %{
    socket: socket,
    note: note
  } do
    edit(socket, note.id, %{"mtime" => @t1})
    assert eventually(fn -> secs(row(note.id).mtime_at) == @t1 end)
    assert is_integer(row(note.id).eff_updated)
  end

  # Delete-the-line test: without the `crdt_msg` capture this stays nil.
  test "an edit over crdt_msg stores its time at the checkpoint", %{socket: socket, note: note} do
    client = handshake_room(socket, note.id)
    b64 = frame_b64(client, "M-")

    ref =
      push(socket, "crdt_msg", %{
        "doc_id" => note.id,
        "b64" => b64,
        "mtime" => @t2,
        "ctime" => @t1
      })

    assert_reply ref, :ok, %{}
    assert eventually(fn -> secs(row(note.id).mtime_at) == @t2 end)
    assert secs(row(note.id).ctime_at) == @t1
  end

  test "a room lost before its checkpoint does not swallow the ctime on the next edit",
       %{socket: socket, note: note} do
    client = handshake_room(socket, note.id)
    b64 = frame_b64(client, "A-")
    ref = push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => b64, "ctime" => @t1})
    assert_reply ref, :ok, %{}

    # Killed before any checkpoint: the in-memory ctime dies with the room.
    Engram.Notes.CrdtRegistry.terminate_room(note.id)
    assert is_nil(row(note.id).ctime_at)

    client2 = handshake_room(socket, note.id)

    ref =
      push(socket, "crdt_msg", %{
        "doc_id" => note.id,
        "b64" => frame_b64(client2, "B-"),
        "ctime" => @t1
      })

    assert_reply ref, :ok, %{}
    assert eventually(fn -> secs(row(note.id).ctime_at) == @t1 end)
  end

  # Through the real checkpoint (no mock): a content change while the room
  # holds a time. Failed outright on c76fcf5f3 (virtual mtime/ctime reached
  # update_all and the checkpoint raised, leaving version at 1).
  test "a content checkpoint holding a time stores it, bumps version once, does not raise",
       %{socket: socket, note: note} do
    before = row(note.id)
    edit(socket, note.id, %{"mtime" => @t2, "ctime" => @t1})

    assert eventually(fn -> row(note.id).version == before.version + 1 end)
    after_ = row(note.id)
    assert {secs(after_.mtime_at), secs(after_.ctime_at)} == {@t2, @t1}
    assert after_.eff_updated == trunc(@t2)
    settle()
    assert row(note.id).version == before.version + 1
  end

  test "an older mtime does not regress it", %{socket: socket, note: note} do
    edit(socket, note.id, %{"mtime" => @t2})
    assert eventually(fn -> secs(row(note.id).mtime_at) == @t2 end)
    edit(socket, note.id, %{"mtime" => @t1})
    settle()
    assert secs(row(note.id).mtime_at) == @t2
  end

  test "ctime is kept once set", %{socket: socket, note: note} do
    edit(socket, note.id, %{"ctime" => @t2})
    assert eventually(fn -> secs(row(note.id).ctime_at) == @t2 end)
    edit(socket, note.id, %{"ctime" => @t1})
    settle()
    assert secs(row(note.id).ctime_at) == @t2
  end

  test "bad, zero, negative and far-future values are ignored", %{socket: socket, note: note} do
    future = System.os_time(:second) + 3 * 86_400

    for bad <- ["x", nil, 0, -5, future, 1.0e300, %{}, [1]] do
      edit(socket, note.id, %{"mtime" => bad, "ctime" => bad})
    end

    settle()
    assert %{mtime_at: nil, ctime_at: nil} = row(note.id)
  end

  test "an old plugin payload with no times leaves stored times alone", %{
    socket: socket,
    note: note
  } do
    edit(socket, note.id, %{"mtime" => @t1, "ctime" => @t1})
    assert eventually(fn -> secs(row(note.id).mtime_at) == @t1 end)
    edit(socket, note.id, %{})
    settle()
    assert %{mtime_at: m, ctime_at: c} = row(note.id)
    assert {secs(m), secs(c)} == {@t1, @t1}
  end

  test "identical content with a new time is a no-op: no write, no version, hash or seq change",
       %{socket: socket, note: note} do
    edit(socket, note.id, %{"mtime" => @t1})
    assert eventually(fn -> secs(row(note.id).mtime_at) == @t1 end)
    settle()
    before = row(note.id)

    # The server's own state replayed: the same content, carrying a newer time.
    doc_update(socket, note.id, update_b64(server_doc(socket, note.id)), %{
      "mtime" => @t2,
      "ctime" => @t2
    })

    settle()
    after_ = row(note.id)
    # A time alone never triggers a checkpoint, so nothing was written.
    assert after_ == before
  end

  test "a checkpoint carrying a time but no content change leaves version, hash and seq",
       %{socket: socket, note: note} do
    before = row(note.id)

    # Insert then delete in one update: the doc changes (so a checkpoint runs)
    # but the projected text does not.
    doc = server_doc(socket, note.id)
    text = Yex.Doc.get_text(doc, "content")
    Yex.Text.insert(text, 0, "zz")
    Yex.Text.delete(text, 0, 2)
    doc_update(socket, note.id, update_b64(doc), %{"mtime" => @t2, "ctime" => @t1})

    assert eventually(fn -> secs(row(note.id).mtime_at) == @t2 end)
    after_ = row(note.id)
    assert secs(after_.ctime_at) == @t1
    assert Map.take(after_, @stable) == Map.take(before, @stable)
  end

  test "edit frames make no notes write from the channel, however many carry times",
       %{socket: socket, note: note} do
    client = handshake_room(socket, note.id)
    test_pid = self()
    channel = socket.channel_pid
    handler = "file-times-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:engram, :repo, :query],
      fn _e, _m, meta, _ ->
        if self() == channel and String.contains?(to_string(meta.query), ~s(UPDATE "notes")),
          do: send(test_pid, {:channel_notes_write, meta.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    for i <- 1..10 do
      ref =
        push(socket, "crdt_msg", %{
          "doc_id" => note.id,
          "b64" => frame_b64(client, "k#{i}"),
          "mtime" => @t1 + i,
          "ctime" => @t1
        })

      assert_reply ref, :ok, %{}
    end

    refute_received {:channel_notes_write, _}
    assert eventually(fn -> secs(row(note.id).mtime_at) == @t1 + 10 end)
  end

  test "put_frame_times never moves version, hash or seq and is tenant scoped",
       %{user: user, vault: vault, note: note} do
    before = row(note.id)
    assert {:ok, 1} = Notes.put_frame_times(user, vault, note.id, @t1, @t1)
    assert Map.take(row(note.id), @stable) == Map.take(before, @stable)

    # Control: another user cannot write this note's times.
    other = insert(:user)
    {:ok, other} = Crypto.ensure_user_dek(other)
    assert {:ok, 0} = Notes.put_frame_times(other, vault, note.id, @t2, @t2)
    assert secs(row(note.id).mtime_at) == @t1
  end

  test "FileTime.from_frame bounds" do
    now = ~U[2026-11-21 00:00:00Z]
    assert %DateTime{} = FileTime.from_frame(@t1, now)
    assert %DateTime{} = FileTime.from_frame(@t1 * 1000, now)

    for bad <- [0, -1, "1", nil, 1.0e300, 1_900_000_000] do
      assert is_nil(FileTime.from_frame(bad, now))
    end
  end

  test "FileTime.advance: mtime only forward, ctime only when none" do
    a = ~U[2023-11-14 22:13:20.000000Z]
    b = ~U[2023-11-14 22:21:40.000000Z]

    assert FileTime.advance(%{mtime_at: nil, ctime_at: nil}, {a, a}) == %{
             mtime: secs(a),
             ctime: secs(a)
           }

    assert FileTime.advance(%{mtime_at: b, ctime_at: b}, {a, a}) == %{}
    assert FileTime.advance(%{mtime_at: a, ctime_at: a}, {b, b}) == %{mtime: secs(b)}
    assert FileTime.advance(%{mtime_at: nil, ctime_at: nil}, {nil, nil}) == %{}
  end
end
