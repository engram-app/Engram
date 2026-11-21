defmodule EngramWeb.CrdtChannelFileTimesTest do
  @moduledoc """
  The optional `mtime` / `ctime` (epoch seconds) the plugin attaches to
  `crdt_create`, `crdt_msg` and `crdt_doc_update`. Times are metadata beside
  the CRDT write: mtime only moves forward, the first ctime stays, unusable
  values are ignored, and a time never touches content, hash or version.
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

  # Lets the room's checkpoint land so a later read is stable.
  defp settle, do: Process.sleep(400)

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

  test "edit with a newer mtime advances it", %{socket: socket, note: note} do
    edit(socket, note.id, %{"mtime" => @t1})
    assert secs(row(note.id).mtime_at) == @t1
    edit(socket, note.id, %{"mtime" => @t2})
    assert secs(row(note.id).mtime_at) == @t2
  end

  test "an older mtime does not regress it", %{socket: socket, note: note} do
    edit(socket, note.id, %{"mtime" => @t2})
    edit(socket, note.id, %{"mtime" => @t1})
    assert secs(row(note.id).mtime_at) == @t2
  end

  test "ctime is kept once set", %{socket: socket, note: note} do
    edit(socket, note.id, %{"ctime" => @t2})
    edit(socket, note.id, %{"ctime" => @t1})
    assert secs(row(note.id).ctime_at) == @t2
  end

  test "bad, zero, negative and far-future values are ignored", %{socket: socket, note: note} do
    future = System.os_time(:second) + 3 * 86_400

    for bad <- ["x", nil, 0, -5, future, 1.0e300, %{}, [1]] do
      edit(socket, note.id, %{"mtime" => bad, "ctime" => bad})
    end

    assert %{mtime_at: nil, ctime_at: nil} = row(note.id)
  end

  test "an old plugin payload with no times leaves stored times alone", %{
    socket: socket,
    note: note
  } do
    edit(socket, note.id, %{"mtime" => @t1, "ctime" => @t1})
    edit(socket, note.id, %{})
    assert %{mtime_at: m, ctime_at: c} = row(note.id)
    assert {secs(m), secs(c)} == {@t1, @t1}
  end

  test "identical content with a new time is a no-op: no version, hash or seq change",
       %{socket: socket, note: note} do
    edit(socket, note.id, %{"mtime" => @t1})
    settle()
    before = row(note.id)

    # The server's own state replayed: the same content, carrying a newer time.
    doc_update(socket, note.id, update_b64(server_doc(socket, note.id)), %{
      "mtime" => @t2,
      "ctime" => @t2
    })

    settle()
    after_ = row(note.id)
    assert secs(after_.mtime_at) == @t2
    assert Map.take(after_, @stable) == Map.take(before, @stable)
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
end
