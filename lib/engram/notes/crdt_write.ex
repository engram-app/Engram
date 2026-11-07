defmodule Engram.Notes.CrdtWrite do
  @moduledoc """
  The single CRDT write path for markdown content (Engram#2519, step 1).

  A REST or MCP write of a note's full text enters the Y-doc as ops: the
  incoming text is diffed hunk by hunk (`CrdtBridge.diff_hunks_into_text/2`)
  into the doc the writer's text was derived from, and the resulting Yjs
  delta is the write. The snapshot `Notes.upsert_note/4` stores is that doc's
  state, so it holds the delta; a live room receives the delta itself
  (`CrdtDeliver.deliver_out/6`, `delta:`), never a copy of the snapshot.

  Behind the `:crdt_write_apply_text` ServiceConfig switch, default OFF
  (`enabled?/0`, read once per write). Off, `upsert_note/4` and `rmw_note/5`
  run the snapshot merge exactly as before.

  ## Where the work runs

  `apply_text/4` computes everything (doc load, diff, encode) and writes
  nothing. `Notes` runs it where it prepared the snapshot merge before: before
  the vault seq lock on a plain write, before the transaction for an rmw's
  optimistic attempt (`prepare_expected/5`). The write itself is the existing
  fenced row update (`snapshot_fenced/2` on seq and nonce, a lost fence
  re-reads), so under the lock run only the writes, nothing here rescues, and
  a failure rolls the whole transaction back. Tail rows that land after the
  read stay in the tail and replay onto the stored state as concurrent ops.

  ## A live room

  With `room: true` (a plain write, holding no row lock) and a room resident,
  the diff runs INSIDE the room, against the room's doc: that doc holds edits
  whose tail append has not landed yet, so a text that already carries one
  (a batch-push echo) diffs to nothing there instead of inserting it twice.
  The room appends and broadcasts the delta itself; the returned state is what
  the row stores. Never under a row lock: the room's append resets
  `notes.crdt_head` on the note row, so it would wait on us. A room is never
  started (`CrdtRegistry.lookup/1` is non-creating).

  Durability on this route: the room appends the delta to the tail on its
  own connection, BEFORE the request's transaction commits. If the request
  then fails (a raise, a lost fence twice, a 409), the edit is still durable
  in the tail and in the room, though the reply says it failed. It is the
  edit the writer asked for, applied once, so a retry finds the doc holding
  the text and only brings the row up to it (an empty delta). A room that
  does not answer holds the request's pool connection for up to two room
  call timeouts (one retry).

  Writers with a base never take this route; see `Notes.crdt_ops_merge/5`
  for why, and for the duplicate it accepts.

  ## Cost per write

  O(note) for the doc load (one snapshot decrypt, the tail replay) and the
  encode, as on the snapshot path. The diff is a line diff bounded by a 20 ms
  deadline (`Engram.Native.text_hunks/2`), coarser past it, never wrong. No
  statement scans the vault.
  """

  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtBridge, CrdtPersistence, CrdtRegistry, CrdtRoom, Note}
  alias Engram.ServiceConfig

  require Logger

  @switch :crdt_write_apply_text

  @doc "Whether markdown content writes take this path (ServiceConfig, default off)."
  @spec enabled?() :: boolean()
  def enabled?, do: ServiceConfig.get(@switch, false) == true

  @doc """
  Author `new_text` (full note text, already scrubbed and size-checked) as
  Yjs ops on the markdown `note`, in the caller's tenant transaction. Writes
  nothing to the database.

  Options:

    * `base:` the doc `new_text` was derived from. `{:doc, doc}` (an rmw's
      authority, or the doc a matched `base_hash` names): the change is
      authored against it and Yjs merges it with anything that landed since.
      `:current` (default): the note's doc as loaded now, snapshot plus tail.
    * `room: true`: a `:current` write holding no row lock may diff inside a
      resident room (see the moduledoc).

  Returns `{:ok, %{state: state, text: text, delta: delta}}`: the full state
  to store, its projection, and the write's ops. When the doc already holds
  `new_text` (its tail or a room has it, the row does not yet) no op is minted
  and `delta` is the empty update, so the row is still brought up to what a
  read serves. An error means nothing was authored.
  """
  @spec apply_text(map(), Note.t(), String.t(), keyword()) ::
          {:ok, %{state: binary(), text: String.t(), delta: binary()}} | {:error, term()}
  def apply_text(user, %Note{} = note, new_text, opts \\ []) when is_binary(new_text) do
    case Keyword.get(opts, :base, :current) do
      {:doc, %Yex.Doc{} = doc} ->
        author(doc, new_text)

      :current ->
        with {:error, :room_gone} <- maybe_in_room(user, note, new_text, opts),
             {:ok, doc, _applied} <- CrdtPersistence.load_doc(note, user),
             do: author(doc, new_text)
    end
  end

  defp maybe_in_room(user, note, new_text, opts) do
    with true <- Keyword.get(opts, :room, false),
         room when is_pid(room) <- CrdtRegistry.lookup(note.id),
         {:ok, %{state: room_state} = authored} <- in_room(room, note, new_text) do
      with_row_state(user, note, room_state, authored)
    else
      {:error, _} = err -> err
      _no_room -> {:error, :room_gone}
    end
  end

  # Phase 0 monotonicity, as the checkpoint does: the stored state is the room
  # state folded onto the row's snapshot, so a room that missed a committed
  # write can never store a state without it.
  defp with_row_state(user, note, room_state, authored) do
    with {:ok, doc, _none} <- CrdtPersistence.load_doc(note, user, []),
         :ok <- Yex.apply_update(doc, room_state) do
      {:ok,
       %{authored | state: Yex.encode_state_as_update!(doc), text: CrdtBridge.project_doc(doc)}}
    end
  end

  # Mints no op when the doc already holds the text (an idempotent write must
  # not make the writer a new client: the third lineage mechanism); the delta
  # is then the empty update.
  defp author(doc, new_text) do
    sv = Yex.encode_state_vector!(doc)

    # One Yjs transaction for the frontmatter keys and every hunk: a room's
    # update_v1 then appends and broadcasts ONE update for the write.
    _ =
      if CrdtBridge.project_doc(doc) != new_text do
        Yex.Doc.transaction(doc, "crdt_write", fn ->
          CrdtBridge.ingest_plaintext(doc, new_text, diff: :hunks)
        end)
      end

    {:ok,
     %{
       state: Yex.encode_state_as_update!(doc),
       text: CrdtBridge.project_doc(doc),
       delta: Yex.encode_state_as_update!(doc, sv)
     }}
  end

  # The diff on the room's own doc, in the room process: the room's update_v1
  # appends and broadcasts it. The result comes back by tagged message (the
  # room discards the fun's return). A room that dies first applied nothing:
  # `{:error, :room_gone}` and the caller diffs the stored doc instead. A fun
  # that raises inside the room is an error: the room still owns the doc, so a
  # write beside it would fork the note.
  defp in_room(room, note, new_text) do
    parent = self()
    ref = make_ref()

    case CrdtRoom.update_doc(room, &send(parent, {ref, author(&1, new_text)}),
           metadata: [note_id: note.id]
         ) do
      :ok ->
        receive do
          {^ref, result} -> result
        after
          0 -> {:error, :room_gone}
        end

      {:error, {:room_raised, _}} = err ->
        err
    end
  catch
    # The room was gone before it ran anything: diff the stored doc instead.
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :room_gone}

    # A timeout or a crash: the room may still apply the delta later, so a
    # write beside it could insert the same text twice. Refuse; the writer
    # retries against whatever landed.
    :exit, reason ->
      Logger.error(
        "crdt write room apply exited",
        Metadata.with_category(:error, :sync,
          note_id: note.id,
          reason: Metadata.safe_exit_reason(reason)
        )
      )

      {:error, :room_unavailable}
  end

  @written_event [:engram, :notes, :crdt_write, :written]

  @doc false
  # The ONE post-write step of this path, run after the write commits and only
  # for a write that applied ops. The shared post-write hook of #2523 S1
  # (`Engram.Search.NameTerms.on_note_written/2`) is called from here once it
  # merges; until then it emits the event the seam test pins, so the call
  # site cannot silently disappear. `note` is the committed row.
  @spec on_written(map(), Note.t()) :: :ok
  def on_written(_user, %Note{id: id}) do
    :telemetry.execute(@written_event, %{count: 1}, %{note_id: id})
  end
end
