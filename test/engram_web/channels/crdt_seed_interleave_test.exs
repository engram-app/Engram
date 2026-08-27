defmodule EngramWeb.CrdtSeedInterleaveTest do
  @moduledoc """
  The channel-side sibling of `checkpoint_interleave_test.exs`, for the roomless
  genesis seed (#476, third wave).

  ## Why this is not in `crdt_channel_test.exs`

  It used to be, and it could not work there. `EngramWeb.ChannelCase` checks out
  ONE sandbox connection and `Sandbox.allow/3`s the channel process onto it, so
  the channel and the test share a single connection inside a single
  never-committed transaction.

  The interleave this test needs is a competing write committing *between* the
  checkpoint's row read and its write. Under that setup it is unreachable:

    * The hook parks the channel INSIDE `do_checkpoint`'s `Repo.with_tenant`
      transaction, so the parked channel is holding the shared connection.
    * The test's own competing write therefore QUEUES behind the park instead
      of committing during it.
    * The park expires (it must — anything past DBConnection's 15s checkout
      timeout deadlocks against the write waiting on that same connection), the
      hook returns, and the test's later release message reaches
      `Phoenix.Channel.Server.handle_info/2`, matches none of `CrdtChannel`'s
      clauses, and kills the channel with a `FunctionClauseError`.

  Whether the sandboxed version passed came down to whether that crash landed
  before or after its `assert_reply`. It was deterministic red on CI and
  reproduced on `origin/main`. The same reasoning `Engram.CheckpointInterleave`
  documents at length applies: a sandboxed version of this test proves nothing.

  ## What makes it work here

  `Sandbox.mode(Repo, :auto)` for the duration, so every process — this one, the
  channel, the room — draws its OWN real connection from the pool. The parked
  channel then holds only its own, and the competing write commits on another
  while the park is still held. Rows really commit, hence `cleanup/1`.
  """
  use ExUnit.Case, async: false

  import Engram.Factory
  import Phoenix.ChannelTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{CheckpointInterleave, Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.CrdtBridge

  @endpoint EngramWeb.Endpoint

  setup do
    # :auto gives every process its own pooled connection with no ownership,
    # which is the whole point — the channel must not be sharing ours. Restored
    # in on_exit; the file is async: false because this is Repo-global.
    # Restored to :manual explicitly, not to a captured previous value —
    # `Sandbox.mode/2` returns `:ok`, not the mode it replaced. :manual is what
    # config/test.exs establishes and what every other suite expects.
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    user_id = Ecto.UUID.generate()
    # Registered BEFORE the first committing write, per CheckpointInterleave:
    # these rows really commit and nothing else removes them.
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user =
      insert(:user,
        id: user_id,
        email: "seed-interleave-#{System.unique_integer([:positive])}@test.com"
      )

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "SeedInterleave", Ecto.UUID.generate())

    EngramWeb.RateLimiter.reset_buckets!()
    on_exit(fn -> EngramWeb.RateLimiter.reset_buckets!() end)

    {:ok, _, socket} =
      subscribe_and_join(
        socket(EngramWeb.UserSocket, "user_#{user.id}", %{
          current_user: user,
          current_api_key: nil
        }),
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        %{"crdt_proto" => 2}
      )

    %{user: user, vault: vault, socket: socket}
  end

  test "a write ABORTED by a concurrent one reports occupied, not absent", ctx do
    %{socket: socket, user: user, vault: vault} = ctx

    # The decline case catches a concurrent write at FOLD time. This one lands
    # it LATER — after the fold, inside `checkpoint/5`, in the gap
    # `:after_row_read` exists for — so the fenced write ABORTS rather than
    # declining.
    #
    # The outcome used to be derived from `wrote?`: the write CLAUSE ran, so the
    # answer was `:absent` = "the row is empty, you must push". It was the
    # opposite of true. The write aborted precisely BECAUSE the row had just
    # been filled, and the client then pushed a body into a history-less doc,
    # minting the rival lineage this path exists to prevent.
    id = Ecto.UUID.generate()
    on_exit(CheckpointInterleave.arm(:after_row_read))

    ref =
      push(socket, "crdt_create", %{
        "doc_id" => id,
        "path" => "Notes/aborted.md",
        "b64" => frame_for_content("client body")
      })

    # Pins the park to the CHANNEL process specifically. A foreign checkpoint
    # consuming it raises instead of handing back the wrong pid, which would
    # make the assertions below an unsynchronised race.
    parked = CheckpointInterleave.await_parked(:after_row_read, socket.channel_pid)

    # Commits on a DIFFERENT real connection while the channel holds its
    # transaction open. This is the write the checkpoint must not clobber, and
    # the thing the sandbox made impossible.
    {:ok, _} =
      Notes.upsert_note(user, vault, %{
        "path" => "Notes/aborted.md",
        "content" => "the concurrent body that won the fence"
      })

    CheckpointInterleave.release(:after_row_read, parked)

    assert_reply ref, :ok, %{doc_id: ^id, seeded: false, genesis: "occupied"}, 15_000

    # ...and the winner's body survives. An `absent` reply would have had the
    # client union a second lineage over exactly this.
    {:ok, stored} = Notes.get_note_by_id(user, vault, id)
    assert stored.content == "the concurrent body that won the fence"
  end

  # A base64 Yjs update that, applied to a fresh empty doc, ingests `content` as
  # full note plaintext — the frame a client sends as `crdt_create`'s `b64`.
  defp frame_for_content(content) do
    doc = CrdtBridge.new_doc()
    :ok = CrdtBridge.ingest_plaintext(doc, content)
    {:ok, update} = Yex.encode_state_as_update(doc)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_update, update}})
    Base.encode64(frame)
  end
end
