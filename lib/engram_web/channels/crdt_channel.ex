defmodule EngramWeb.CrdtChannel do
  @moduledoc """
  Base64-in-JSON Yjs sync transport (posture C, file-level), spec §12a.

  ONE topic per vault: `crdt:{user_id}:{vault_id}`. The document is
  identified by `doc_id = "{note_id}"` inside each `crdt_msg`
  payload; `b64` base64-decodes to a standard y-protocols messageSync frame.
  doc_id IS the note_id; the channel validates it belongs to the vault,
  lazily starts + observes the singleton `CrdtDoc` room per doc, and relays
  y-protocols broadcasts back out as `crdt_msg` events tagged with the
  originating `doc_id`. Auth mirrors SyncChannel.

  The same topic also carries the per-vault **index** room (#1150) as
  `crdt_index_msg`. Those frames have NO `doc_id` — the vault is implicit in the
  topic and there is exactly one index room per connection — and the wire is
  gated on `:crdt_index_enabled` (off by default) until #1151 gives that room a
  checkpoint. See `docs/context/crdt-index-room.md`.
  """

  use Phoenix.Channel

  alias Engram.Crypto.HMAC
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.{Notes, Vaults}
  alias Engram.Notes.CrdtBridge
  alias Engram.Notes.CrdtCheckpoint
  alias Engram.Notes.CrdtIndexRegistry
  alias Engram.Notes.CrdtRegistry
  alias Engram.Notes.CrdtTransport
  alias Yex.Sync.SharedDoc

  require Logger

  # socket assigns:
  #   rooms    :: %{doc_id => %{room: pid, note_id: binary, ref: reference}}
  #   room_doc :: %{room_pid => doc_id}  (reverse map for broadcast routing)

  # 5 MB decoded-frame ceiling — stops a single client from flooding RDS with
  # INSERT payloads that dwarf normal Yjs updates (which are sub-KB).
  @max_frame_bytes 5_000_000

  # Base64 expands ~4/3, so a b64 string longer than this cannot decode to a
  # frame within the cap — reject before allocating the decoded copy.
  @max_b64_bytes div(@max_frame_bytes * 4, 3) + 8

  # 240 frames / 10 s ≈ 24 msg/s sustained — well above human typing speed with
  # a 2 s client debounce, and low enough to stop scripted floods.
  # Overridable via :crdt_msg_rate_limit_override (unit tests put_env it; CI/E2E
  # set it from a CI-gated env in runtime.exs). See effective_msg_limit/0 below;
  # prod never sets it and uses @msg_limit.
  @msg_limit 240
  @msg_scale_ms 10_000

  # Liveness-probe timeout before unobserving a drained room (see release_room/1).
  # Generous enough that a room merely busy in a NIF still answers, short enough
  # that a genuinely wedged one cannot hold this channel for y_ex's 5 s default.
  # Overridable (like @default_max_rooms) so the wedged-room test can assert
  # against a short probe instead of racing a 1 s wall-clock on a loaded runner.
  @room_probe_ms 1_000

  # Ceiling on the per-socket drained-doc_id set (see remember_drained/3).
  @max_drained 1_024

  @drain_event [:engram, :crdt, :room_drain]

  # Per-socket ceiling on distinct rooms (notes) a single connection may enroll.
  # Each room pins a server Y.Doc + checkpoint timer, so an unbounded client
  # (buggy or hostile) could STEP1 endlessly and exhaust node RAM + the DB pool.
  # ponytail: sized as a high ABUSE ceiling, not a working limit — 4096 clears a
  # 2400-note vault under today's enroll-everything client with headroom. Tighten
  # toward the real active-set (~256) once lazy enrollment is the plugin default.
  # Runtime-overridable via config so it can be lowered without a redeploy.
  @default_max_rooms 4096

  # Handshake (STEP1/STEP2) budget — separate from @msg_limit so connect-time
  # enrollment (one STEP1 per note) can never starve edit frames (the
  # 2026-07-07 incident trigger on a ~230-note vault). 2400/10s enrolls a
  # 2400-note vault inside one window; bounded, not exempt (see frame_class).
  @hs_limit 2400

  # Account-wide ceiling = @msg_limit × this. A user may run several devices,
  # each with the full per-device budget, but the account total is capped so a
  # single account can't multiply its budget without bound by opening many
  # sockets or forging device ids (the WS transport has no connect-level
  # limiter). 10 ≈ "up to ten busy devices per account" before the ceiling bites.
  @account_multiplier 10

  # Default page size for crdt_catchup_since when the client sends no `limit`.
  # Matches the seq feeds' internal 500-row cap (larger values clamp to it).
  @catchup_page_limit 500

  # Trust-boundary cap on crdt_create_batch's `creates` list. Without this,
  # check_rate(:handshake) is spent once per BATCH regardless of its size, so
  # one oversized message amplifies past the per-note handshake budget.
  # Matches the client's own ≤100 chunk constraint.
  @max_batch_creates 100

  @impl true
  def join("crdt:" <> ids, params, socket) do
    proto = Map.get(params, "crdt_proto", 1)

    if proto < Engram.Notes.CrdtBridge.doc_schema_version() do
      {:error, %{reason: "crdt_proto_too_old", min: Engram.Notes.CrdtBridge.doc_schema_version()}}
    else
      join_authenticated("crdt:" <> ids, assign(socket, :client_type, client_type(params)))
    end
  end

  # Trust boundary: client_type is client-supplied and only ever feeds a
  # string equality in Notes.crdt_rename_rewrites?/1. Bound the shape here;
  # anything non-binary or oversized degrades to nil (= untagged, which takes
  # the Notes.untagged_crdt_client_type/0 compromise default). Unknown-but-
  # present strings pass through deliberately — a future client that tags
  # itself anything other than "obsidian" gets server rewrites (safe default).
  defp client_type(%{"client_type" => t}) when is_binary(t) and byte_size(t) <= 32, do: t
  defp client_type(_params), do: nil

  defp join_authenticated("crdt:" <> ids, socket) do
    user = socket.assigns.current_user

    user_id_str = to_string(user.id)

    # T3.7 (#1092): the crdt: channel is the live write path — refuse to open it
    # while a DEK rotation holds the user's lock. check/1 re-reads the row so a
    # reconnect mid-rotation is caught even if the socket's user struct predates
    # the lock. In-flight sockets are drained separately (UserDekRotation).
    case RotationGate.check(user.id) do
      {:error, :rotation_in_progress} -> {:error, %{reason: "rotation_in_progress"}}
      # :ok, or {:error, :user_not_found} — let the vault-auth path decide
      # (a missing user falls through to "unauthorized", not a rotation reason).
      _ -> join_vault("crdt:" <> ids, user, user_id_str, socket)
    end
  end

  defp join_vault("crdt:" <> ids, user, user_id_str, socket) do
    case String.split(ids, ":") do
      [^user_id_str, vid_str] ->
        case Ecto.UUID.cast(vid_str) do
          {:ok, vault_id} ->
            case Vaults.get_vault(user, vault_id) do
              {:ok, vault} ->
                case Vaults.check_api_key_access(socket.assigns[:current_api_key], vault) do
                  :ok ->
                    Logger.info(
                      "crdt join",
                      Metadata.with_category(:info, :websocket,
                        conn_id: socket.assigns[:conn_id],
                        device_id: socket.assigns[:device_id],
                        topic: socket.topic,
                        # Skew tripwire for the Notes.untagged_crdt_client_type/0
                        # default, flipped to "web" in #1301. An untagged socket
                        # now gets a SERVER-side link rewrite on rename, which is
                        # wrong for a pre-1.20.0 plugin (it rewrites its own links
                        # — both sides editing one Y-doc is the double-rewrite the
                        # one-rewriter invariant forbids). Before this field the
                        # gate's own input was unobservable, so "has the skew
                        # drained?" had no answer. nil is materialised as the
                        # literal "untagged" rather than left absent: a MISSING
                        # field is indistinguishable from a log line predating
                        # this change, which would make the tripwire query lie.
                        # Safe to echo — client_type/1 above already bounds it to
                        # a ≤32-byte binary, and this is a JSON field, not a Loki
                        # stream label, so an odd value costs no index cardinality.
                        client_type: socket.assigns[:client_type] || "untagged",
                        user_id: HMAC.hash_user_id(to_string(user.id))
                      )
                    )

                    # ONE drain subscription for the whole connection (#1152).
                    # Per-room would cost a subscription per note the client
                    # enrolls — 309 bytes each, ~725 KB per socket on a
                    # 2400-note vault — which is the very memory pressure the
                    # drain exists to relieve. Nothing extra is needed to route
                    # it: the drain carries the room pid, and handle_info
                    # already no-ops on a pid this channel does not hold.
                    :ok =
                      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(vault.id))

                    {:ok,
                     assign(socket,
                       vault: vault,
                       rooms: %{},
                       room_doc: %{},
                       # doc_ids released by an idle drain (#1152), so the
                       # re-spin does not re-announce crdt_doc_ready. See
                       # start_and_observe_room.
                       drained: MapSet.new()
                     )}

                  _ ->
                    {:error, %{reason: "api_key_vault_forbidden"}}
                end

              _ ->
                {:error, %{reason: "vault_not_found"}}
            end

          :error ->
            {:error, %{reason: "unauthorized"}}
        end

      _ ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("crdt_msg", %{"doc_id" => doc_id, "b64" => b64}, socket) do
    # Classify (O(1), first 4 b64 chars) BEFORE the rate check so sync
    # handshakes ride their own, larger bucket than edit frames: connect-time
    # enrollment fires one STEP1 (+ tiny STEP2 echo) per note, so on a
    # ~230-note vault a single per-frame budget let enrollment starve the
    # user's real edits for the whole window (2026-07-07 cross-file-overwrite
    # incident trigger). The full base64 decode runs only AFTER the limiter
    # allows the frame, so an over-budget flood is still rejected at ETS-lookup
    # cost, never at MB-scale decode cost.
    with :ok <- check_rate(socket, frame_class_b64(b64)),
         {:ok, frame} <- decode_frame(b64),
         :ok <- guard_frame(frame),
         {:ok, socket, %{room: room}} <- ensure_room(socket, doc_id),
         :ok <- relay_frame(room, frame) do
      # ACK the push. Clients attach reply handlers to distinguish delivery
      # from loss; with no ack every successful push "times out" client-side —
      # the web SPA re-handshook every open note every ~3.5s forever
      # (2026-07-14). Routed-to-room is the honest ack point: the frame is in
      # the owner process's mailbox and the room's update_v1 path persists it.
      {:reply, {:ok, %{}}, socket}
    else
      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}

      {:error, :implausible_state_vector} ->
        # A crafted syncStep1 whose state vector would OOM-abort the whole VM
        # in the y_ex NIF (P0 #989). Rejected before it reaches SharedDoc.
        log_dropped(socket, doc_id, :implausible_state_vector)
        {:reply, {:error, %{reason: "implausible_state_vector"}}, socket}

      {:error, :frame_too_large} ->
        log_dropped(socket, doc_id, :frame_too_large)
        {:reply, {:error, %{reason: "frame_too_large"}}, socket}

      {:error, :room_limit} ->
        # This socket hit the per-connection room cap (abuse backstop). Reply so
        # the client stops hammering; log_dropped emits an alertable :sync warn.
        log_dropped(socket, doc_id, :room_limit)
        {:reply, {:error, %{reason: "room_limit"}}, socket}

      {:error, :not_found} = err ->
        # Unknown note_id: the frame is undeliverable, and the SENDER is the
        # one who must act — this is the create-race cross-wire signature
        # (client keyed to an id the server never adopted, 2026-07-07). Reply
        # so the plugin can trigger its live id-map reconcile immediately
        # (ensureNoteIdMapped, plugin v1.11.22) instead of talking into the
        # void until a cold-start reconcile (#955).
        log_dropped(socket, doc_id, err)
        {:reply, {:error, %{reason: "note_not_found", doc_id: doc_id}}, socket}

      {:error, :room_unavailable} = err ->
        # The room auto-exited out from under every observe_with_retry attempt.
        # This used to fall through to the reply-less clause below, on the
        # reasoning that the sender "has no actionable heal" — defensible when a
        # room only vanished on a crash. The drain (#1152) makes teardown the
        # STEADY STATE, so this is now a routine race, and a retry is exactly
        # the right heal: the next attempt re-resolves through ensure_room and
        # lands on a fresh room. Reply so the client can take it, instead of
        # dropping the edit and leaving the push to time out client-side.
        #
        # Deliberately NOT fixed by widening observe_with_retry's budget: a room
        # checkpoints inside terminate/2, so it can hold its :global name for far
        # longer than the retry sleep, and every extra millisecond spent looping
        # there blocks EVERY other note on this socket. Bounce it to the client,
        # which can retry without holding the channel.
        log_dropped(socket, doc_id, err)
        {:reply, {:error, %{reason: "room_unavailable", doc_id: doc_id}}, socket}

      err ->
        # Surface drops rather than swallowing them silently — a dropped frame
        # (bad base64, or a non-UUID doc_id from a stale path-keyed client)
        # means a lost edit. These stay reply-less: a non-UUID doc_id may be a
        # cleartext path, and echoing it back would leak it.
        log_dropped(socket, doc_id, err)
        {:noreply, socket}
    end
  end

  # Per-vault INDEX room frames (#1150). No `doc_id`: the vault is implicit in
  # the channel topic and there is exactly one index room per connection, so
  # addressing it by id would be a second way to name the same thing — and a
  # doc_id-addressable index room would bypass note_in_vault? validation.
  #
  # Rides the existing channel — no new transport, per the issue — and is rate
  # limited EXACTLY like a note frame: `frame_class_b64/1` puts step1 and small
  # step2 on the handshake lane and everything else, including every
  # `sync_update`, on the edit lane.
  #
  # An earlier comment here claimed index frames ride the handshake bucket
  # outright, on the reasoning that index sync is once-per-connect. That is true
  # of the handshake and false of the writes #1151 will add: a rename or create
  # writes `filemeta_v0`, which is a `sync_update`, which bills the user's edit
  # budget. Deciding whether that is right belongs to #1151, where those writes
  # exist and their volume is known — putting ALL index traffic on the handshake
  # lane just moves the starvation risk onto handshakes, which is the shape
  # behind the 2026-07-07 cross-file-overwrite incident.
  @impl true
  def handle_in("crdt_index_msg", %{"b64" => b64}, socket) do
    with :ok <- index_enabled(),
         :ok <- check_rate(socket, frame_class_b64(b64)),
         {:ok, frame} <- decode_frame(b64),
         :ok <- guard_frame(frame),
         {:ok, socket, room} <- ensure_index_room(socket),
         :ok <- relay_frame(room, frame) do
      {:reply, {:ok, %{}}, socket}
    else
      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}

      {:error, :index_disabled} ->
        {:reply, {:error, %{reason: "index_disabled"}}, socket}

      {:error, reason} ->
        # The index is not yet load-bearing (nothing reads it back until #1151 /
        # Engram-obsidian#362), but a silently dropped frame here would become a
        # drift class the moment it is — so it is logged like any lost edit.
        log_index_dropped(socket, reason)
        {:reply, {:error, %{reason: "index_frame_rejected"}}, socket}
    end
  end

  # These four frames carry no b64 payload, so frame_class_b64 doesn't apply —
  # they ride the :handshake lane (see check_rate/2 below). All four are
  # connect/catchup-time operations (one create/delete per note mutation, one
  # catchup call per note during enrollment), the exact shape @hs_limit was
  # sized for, and NOT the continuous edit stream @msg_limit protects — so
  # sharing that lane is intentional, not accidental reuse. They are still
  # bounded (not exempt): the 2400/10s ceiling applies same as real STEP1s.
  @impl true
  def handle_in("crdt_create", %{"doc_id" => doc_id, "path" => path}, socket) do
    with :ok <- check_rate(socket, :handshake),
         {:ok, note_id} <- cast_doc_id(doc_id),
         :ok <- validate_create_path(path) do
      user = socket.assigns.current_user
      vault = socket.assigns.vault

      case Notes.genesis_crdt_note(user, vault, note_id, path,
             origin: socket.assigns[:client_type]
           ) do
        {:ok, note} ->
          {:reply, {:ok, %{doc_id: note.id}}, socket}

        {:adopted, note} ->
          # Unchanged behaviour for the single create: the client's crdtCreate
          # promise resolves to the authoritative id and pushFile's ADOPT then
          # transfers the local body onto that lineage. Only the BATCH leg has to
          # distinguish this from a create (it reports frame-applied, not id).
          {:reply, {:ok, %{doc_id: note.id}}, socket}

        {:error, :id_conflict, note} ->
          {:reply, {:error, %{reason: "id_conflict", doc_id: note.id}}, socket}

        {:error, :version_conflict, note} ->
          {:reply, {:error, %{reason: "version_conflict", doc_id: note.id}}, socket}

        {:error, {:notes_cap_reached, limit, _count}} ->
          {:reply, {:error, %{reason: "notes_cap_reached", limit: limit}}, socket}

        {:error, :recently_deleted} ->
          # Delete-wins (#970): a stale device tried to un-delete a note within
          # the delete window. The delete stands; the client trashes its local
          # copy on this reply instead of wedging on a resurrect forever.
          {:reply, {:error, %{reason: "recently_deleted"}}, socket}

        {:error, %Ecto.Changeset{} = cs} ->
          # Covers the unique-constraint case (resurrecting a tombstoned id
          # onto a path already owned by a different live note) as well as
          # any other changeset validation failure — a clean reply either way.
          log_create_failed(socket, note_id, "changeset: #{inspect(cs.errors)}")
          {:reply, {:error, %{reason: "create_failed"}}, socket}

        {:error, reason} ->
          # Catch-all for the crypto/KMS error class (a first-write user whose
          # DEK wrap fails, an encrypt or filter-key error): genesis_crdt_note/4
          # can return a bare {:error, term} that matches none of the arms above.
          # Without this the case raised CaseClauseError and crashed the channel.
          # {:error, term()} is in genesis_crdt_note/4's @spec, so dialyzer sees
          # this arm as reachable (it was wrongly removed before on a lying spec).
          #
          # error_kind/1, never inspect(reason): this is precisely the crypto/KMS
          # class, whose error terms can embed a wrapped DEK or an AWS response
          # body, and RedactFilter scrubs metadata keys only, never the message.
          log_create_failed(socket, note_id, inspect(Engram.Telemetry.error_kind(reason)))
          {:reply, {:error, %{reason: "create_failed"}}, socket}
      end
    else
      {:error, :rate_limited} -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
      {:error, :bad_doc_id} -> {:reply, {:error, %{reason: "bad_doc_id"}}, socket}
      {:error, :bad_path} -> {:reply, {:error, %{reason: "bad_path"}}, socket}
    end
  end

  # Bulk genesis-with-content (single-push-path, Task 1). One frame creates N
  # brand-new notes AND seeds each note's initial content in one round trip:
  # each entry carries a `sync_update` Y-frame that the room applies + persists,
  # so a fresh vault push no longer needs a create call plus a separate edit
  # frame per note. Rides the :handshake lane (connect-time enrollment shape,
  # NOT the continuous edit stream). Partial failure is per-entry: one bad entry
  # returns an error result but the batch reply is still :ok so the good entries
  # commit — the client reconciles per doc_id, never re-pushing the whole batch.
  #
  # Processed in three phases so a 100-entry batch's wall-clock isn't 100
  # serial (DB write + SharedDoc round-trip) chains — the reply contract is
  # unchanged (goes out after ALL entries complete, per-entry results in input
  # order):
  #   1. parallel (Task.async_stream): validation + the genesis DB write —
  #      touches no socket state.
  #   2. serial, in the channel process: room enrollment — mutates socket
  #      assigns, and SharedDoc.observe/Process.monitor must register THIS
  #      channel pid (a task pid would swallow the room's {:yjs, ...} fan-out).
  #   3. parallel: per-room seed + synchronous checkpoint materialize (each
  #      room is its own GenServer; seed is atomic in-room). Awaited before
  #      the reply so materialized content is durable when the ack lands.
  @impl true
  def handle_in("crdt_create_batch", %{"creates" => creates}, socket) when is_list(creates) do
    if length(creates) > @max_batch_creates do
      {:reply, {:error, %{reason: "too_many_creates", max: @max_batch_creates}}, socket}
    else
      case check_rate(socket, :handshake) do
        :ok ->
          user = socket.assigns.current_user
          vault = socket.assigns.vault
          client_type = socket.assigns[:client_type]

          prepared =
            creates
            |> Task.async_stream(
              fn entry ->
                entry_guard(entry, fn -> prepare_create(entry, user, vault, client_type) end)
              end,
              max_concurrency: batch_concurrency(),
              ordered: true,
              # Per-entry work is internally bounded (DB timeouts, the 5s
              # SharedDoc call timeout) — matching the old serial shape,
              # where no per-entry deadline existed either.
              timeout: :infinity
            )
            |> Enum.map(fn {:ok, res} -> res end)

          {entries, socket} =
            Enum.map_reduce(prepared, socket, fn
              {:created, note_id, frame}, sock ->
                case ensure_room(sock, note_id) do
                  {:ok, sock, %{room: room}} ->
                    {{:enrolled, note_id, frame, room}, sock}

                  {:error, :room_limit} ->
                    {{:result, %{doc_id: note_id, status: "error", reason: "room_limit"}}, sock}

                  other ->
                    # Same discipline as prepare_create's catch-all: this arm is
                    # the last thing between a room-enrollment failure and an
                    # unexplainable create_failed on the client, and the row is
                    # already committed by the time we get here, so a silent drop
                    # leaves a 0-byte note nobody can account for.
                    log_enroll_failed(sock, note_id, other)

                    {{:result, %{doc_id: note_id, status: "error", reason: "create_failed"}},
                     sock}
                end

              {:result, _} = res, sock ->
                {res, sock}
            end)

          results =
            entries
            |> Task.async_stream(
              fn
                {:enrolled, note_id, frame, room} = entry ->
                  entry_guard(entry, fn ->
                    seed_and_checkpoint(user, vault, note_id, frame, room)
                    {:result, %{doc_id: note_id, status: "ok"}}
                  end)

                {:result, _} = res ->
                  res
              end,
              max_concurrency: batch_concurrency(),
              ordered: true,
              timeout: :infinity
            )
            |> Enum.map(fn {:ok, {:result, res}} -> res end)

          {:reply, {:ok, %{results: results}}, socket}

        {:error, :rate_limited} ->
          {:reply, {:error, %{reason: "rate_limited"}}, socket}
      end
    end
  end

  @impl true
  def handle_in("crdt_delete", %{"doc_id" => doc_id}, socket) do
    with :ok <- check_rate(socket, :handshake),
         {:ok, note_id} <- cast_doc_id(doc_id) do
      user = socket.assigns.current_user
      vault = socket.assigns.vault
      device_id = socket.assigns[:device_id]
      # Idempotent: a :not_found means the row is already gone — the desired
      # end state — so we still reply :ok. origin_device_id (#970) lets THIS
      # device drop its own note_changed echo of the delete.
      _ = Notes.delete_note_by_id(user, vault, note_id, origin_device_id: device_id)
      {:reply, {:ok, %{doc_id: note_id}}, socket}
    else
      {:error, :rate_limited} -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
      {:error, :bad_doc_id} -> {:reply, {:error, %{reason: "bad_doc_id"}}, socket}
    end
  end

  # Single-path catch-up (Phase B): replay the seq-ordered op-log over the
  # socket from a client cursor. Reuses `list_changes_by_seq` — the same
  # seq-ordered, all-or-fails-on-decrypt feed `/sync/changes` serves — so each
  # op carries FULL content (not an SV-diff) and is causally complete: it can
  # never pend the way `crdt_catchup_delta` did (the e2e test_85 deaf-note bug).
  # Tombstones ride the same feed (deletes replay as ops). Paginated: the client
  # advances its cursor by `next_seq` and re-requests until `has_more` is false.
  @impl true
  def handle_in("crdt_catchup_since", payload, socket) do
    with :ok <- check_rate(socket, :handshake),
         {:ok, cursor} <- cast_cursor(Map.get(payload, "cursor_seq", 0)) do
      # Composite keyset cursor: `cursor_id` pairs with `cursor_seq` so the next
      # page continues at `(seq, id) > (cursor_seq, cursor_id)` instead of the
      # seq-only `seq > cursor_seq`. An attachment move writes two rows at ONE
      # seq (#614); a seq-only cursor paging between them skips the second (#312).
      # Invalid/absent cursor_id degrades to seq-only (nil) rather than rejecting.
      cursor_id = cast_cursor_id(Map.get(payload, "cursor_id"))

      limit =
        case Map.get(payload, "limit") do
          # Clamp to the feed cap: merged_changes_page warns callers to bound
          # limit to @catchup_page_limit or rows past the cap silently drop
          # (SyncController does the same). An unclamped client `limit` was a
          # pre-existing silent-loss path.
          n when is_integer(n) and n > 0 -> min(n, @catchup_page_limit)
          # Match the feed page cap when the client sends no limit (prior
          # behaviour: opts = [] → list_changes_by_seq defaulted to its max).
          _ -> @catchup_page_limit
        end

      # Merged notes + attachments seq feed (each row carries its real
      # `:note`/`:attachment` type). seq is vault-global so the integer cursor
      # paginates both feeds as one ordered stream. The client's applySyncChange
      # already dispatches per type → attachments apply through the same path.
      %{page: changes, has_more: has_more, next: next} =
        Engram.Sync.merged_changes_page(
          socket.assigns.current_user,
          socket.assigns.vault,
          cursor,
          cursor_id,
          limit,
          :all
        )

      {next_seq, next_id} =
        case next do
          {seq, id} -> {seq, id}
          _ -> {nil, nil}
        end

      {:reply,
       {:ok, %{changes: changes, has_more: has_more, next_seq: next_seq, next_id: next_id}},
       socket}
    else
      {:error, :rate_limited} -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
      {:error, :bad_cursor} -> {:reply, {:error, %{reason: "bad_cursor"}}, socket}
    end
  end

  # Channel-wide fallback (MUST stay last — Elixir matches handle_in top-down).
  # Every crdt_* frame above pattern-matches its required keys, so a frame
  # missing one (e.g. crdt_create with no "path") would otherwise raise
  # FunctionClauseError and crash the whole channel. Reply so the client learns
  # the frame was malformed instead of silently losing the socket.
  #
  # Gated on the same :handshake rate budget as every real frame above — an
  # unguarded fallback let malformed/unknown frames flood the channel outside
  # any budget.
  @impl true
  def handle_in(_event, _payload, socket) do
    case check_rate(socket, :handshake) do
      :ok -> {:reply, {:error, %{reason: "bad_frame"}}, socket}
      {:error, :rate_limited} -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end

  # Concurrency for the crdt_create_batch phase-1 and phase-3 streams. Bounded
  # by the DB POOL, not the scheduler count: each entry opens its own
  # `Repo.with_tenant` TRANSACTION and pins a pooled connection for the whole of
  # it, so N concurrent entries hold N of the pool's connections for as long as
  # they run.
  #
  # Sizing this off System.schedulers_online() starved the pool (default
  # POOL_SIZE=10) during e2e bulk first sync: entries died on a ~183ms
  # DBConnection queue timeout, and because Task.async_stream LINKS its tasks to
  # the caller, that exit killed the channel process itself — after which the
  # socket had no channel for the topic and every later client frame came back
  # "unmatched topic" (Phoenix socket.ex). One pool timeout took out the whole
  # connection, not one create.
  #
  # A quarter of the pool keeps the batch from monopolising it: the same node is
  # concurrently serving other channels, the checkpoint timers and the seq feed.
  # The parallelism win here is overlapping the SharedDoc round-trip with the DB
  # write, which saturates well below the pool size anyway.
  @doc false
  # Public only so a test can pin the pool bound — the regression that caused
  # this was a plausible-looking `System.schedulers_online()`, and nothing else
  # in the module would catch a refactor back to it.
  def batch_concurrency do
    :engram
    |> Application.get_env(Engram.Repo, [])
    |> Keyword.get(:pool_size, 10)
    |> div(4)
    |> max(1)
  end

  # Contain a per-entry failure to that entry. `crdt_create_batch` documents
  # partial failure as per-entry ("one bad entry returns an error result but the
  # batch reply is still :ok"), but an unhandled raise/exit in a Task.async_stream
  # task propagates through the link and takes the channel down instead — turning
  # one transient DB hiccup into a dead topic the client retries against forever.
  # This maps such a failure onto the `create_failed` result the contract already
  # defines. NOT a silent swallow: every occurrence is logged with the reason.
  @doc false
  # Public only so a test can pin containment directly; the failures it catches
  # (pool timeout, dead room) are not injectable through the channel API.
  def entry_guard(entry, fun) do
    fun.()
  rescue
    e ->
      log_entry_failure(entry, Exception.message(e))
  catch
    :exit, reason ->
      log_entry_failure(entry, "exited: #{inspect(reason)}")
  end

  defp log_entry_failure(entry, reason) do
    doc_id = entry_doc_id(entry)

    Logger.warning(
      "crdt_create_batch entry failed: #{reason}",
      Metadata.with_category(:warning, :websocket, doc_id: doc_id)
    )

    {:result, %{doc_id: doc_id, status: "error", reason: "create_failed"}}
  end

  defp entry_doc_id({:enrolled, note_id, _frame, _room}), do: note_id
  defp entry_doc_id(%{"doc_id" => doc_id}), do: doc_id
  defp entry_doc_id(_), do: nil

  # Phase-1 half of a crdt_create_batch entry: everything that needs NO socket
  # state — validation, frame decode/guard, the genesis DB write. Runs inside
  # Task.async_stream, so it must not touch socket assigns or the channel
  # mailbox. Returns `{:created, note_id, frame}` for phase 2/3, or
  # `{:result, map}` when this entry's result is already final.
  defp prepare_create(
         %{"doc_id" => doc_id, "path" => path, "b64" => b64},
         user,
         vault,
         client_type
       ) do
    with {:ok, note_id} <- cast_doc_id(doc_id),
         :ok <- validate_create_path(path),
         {:ok, frame} <- decode_frame(b64),
         :ok <- guard_frame(frame),
         {:ok, note} <-
           Notes.genesis_crdt_note(user, vault, note_id, path, origin: client_type) do
      # note.id, NOT the note_id we sent: genesis re-mints when the client's id is
      # already owned by another of this user's vaults (the vault-copy case).
      # Forwarding the sent id here stranded the whole batch leg of that fix --
      # phase 2's ensure_room resolves by note_in_vault?, which is false for the
      # foreign id, so every re-minted entry fell into the create_failed arm below,
      # its content frame was dropped, and the row committed empty. The single
      # crdt_create above always replied note.id; this leg has to match it.
      {:created, note.id, frame}
    else
      {:adopted, note} ->
        # The path was already owned by a live note under a different id, so this
        # entry's content frame was NOT applied to it. Reporting "ok" would have
        # the plugin mark the file pushed (adoptCreateAck stamps the LOCAL body as
        # the baseline) while the body never reached the server. id_conflict is
        # the existing contract for exactly this, and the plugin already routes it
        # to pushFile's full ADOPT, which transfers the body onto that lineage.
        {:result, %{doc_id: note.id, status: "error", reason: "id_conflict"}}

      {:error, :id_conflict, note} ->
        {:result, %{doc_id: note.id, status: "error", reason: "id_conflict"}}

      {:error, :version_conflict, note} ->
        {:result, %{doc_id: note.id, status: "error", reason: "version_conflict"}}

      {:error, :recently_deleted} ->
        {:result, %{doc_id: doc_id, status: "error", reason: "recently_deleted"}}

      {:error, {:notes_cap_reached, limit, _}} ->
        {:result, %{doc_id: doc_id, status: "error", reason: "notes_cap_reached", limit: limit}}

      {:error, :bad_doc_id} ->
        {:result, %{doc_id: doc_id, status: "error", reason: "bad_doc_id"}}

      {:error, :bad_path} ->
        {:result, %{doc_id: doc_id, status: "error", reason: "bad_path"}}

      {:error, :implausible_state_vector} ->
        {:result, %{doc_id: doc_id, status: "error", reason: "implausible_state_vector"}}

      {:error, :frame_too_large} ->
        {:result, %{doc_id: doc_id, status: "error", reason: "frame_too_large"}}

      other ->
        # Never swallow the reason: this arm is the only thing standing between
        # a genuine create failure and an unexplainable "create_failed" on the
        # client. Same discipline as log_entry_failure/2 below.
        #
        # Narrowed to error_kind/1 rather than inspect(other): `other` here is
        # frequently {:error, %Ecto.Changeset{}}, and inspecting the changeset
        # whole dumps its `changes` -- every ciphertext blob on the note -- into
        # Loki. Only metadata keys are redacted, never the message body.
        Logger.warning(
          "crdt_create_batch prepare failed: #{inspect(prepare_error_kind(other))}",
          Metadata.with_category(:warning, :websocket,
            doc_id: doc_id,
            user_id: user.id,
            vault_id: vault.id
          )
        )

        {:result, %{doc_id: doc_id, status: "error", reason: "create_failed"}}
    end
  end

  # Malformed entry (missing a required key) — never crash the batch.
  defp prepare_create(entry, _user, _vault, _client_type) do
    doc_id = if is_map(entry), do: Map.get(entry, "doc_id"), else: nil
    {:result, %{doc_id: doc_id, status: "error", reason: "bad_frame"}}
  end

  # Phase-3 half: seed the room's doc with the client's genesis frame + the
  # synchronous checkpoint materialize. Safe under Task.async_stream — talks
  # only to the room GenServer + the DB, never to socket state.
  #
  # Genesis seeds an EMPTY note. Apply the client's full-state frame ONLY when
  # the room doc has no content yet, and do the check + apply ATOMICALLY inside
  # the room process (seed_genesis_if_empty/3) so two concurrent creates of the
  # same note can't both observe an empty doc and both apply. A second create
  # for an already-seeded note (a client retry/re-push — observed ~9s apart in
  # e2e test_82) must NOT re-apply: the create-time checkpoint FLATTENS the doc
  # to a fresh server lineage, so the frame's original client lineage no longer
  # merges as a no-op — Yjs appends it and the body DOUBLES (#846; test_82 saw
  # a deterministic 38B = 19B "original" twice, blocking the peer's real edit
  # from converging). Post-genesis edits flow through the live room / seq-replay
  # op-log, never a re-sent create, so skipping a non-empty doc loses nothing.
  defp seed_and_checkpoint(user, vault, note_id, frame, room) do
    if seed_genesis_if_empty(room, note_id, frame) == :seeded do
      # Materialize the genesis content to notes.content SYNCHRONOUSLY so the
      # seq-ordered catch-up feed (the single convergence path) carries it the
      # instant the row is visible, instead of waiting ~250ms for the room's
      # checkpoint timer. Before this, a seq-replay catch-up racing that timer
      # read content="" and 0-byte-materialized the note (e2e test_03/09/10/86
      # regressed under load once the plugin routed convergence through
      # crdt_catchup_since). Runs ONLY for the create that actually seeded — a
      # :skipped create must not re-checkpoint, or the checkpoint's
      # union_with_row_state would re-merge the divergent lineage and re-double
      # notes.content. Runs the ONE checkpoint materializer, idempotent with the
      # timer's later checkpoint (equal content_hash hits the "Text unchanged"
      # no-op branch). Best-effort: a materialize failure leaves the timer as the
      # backstop, so a raise here must never fail the create.
      try do
        doc = SharedDoc.get_doc(room)
        captured_version = CrdtCheckpoint.current_version(user.id, note_id)

        _ =
          CrdtCheckpoint.checkpoint(user.id, vault.id, note_id, doc,
            captured_version: captured_version
          )
      rescue
        e ->
          # Still best-effort (timer checkpoint is the backstop), but never
          # silent — this was the one unlogged rescue in this module. Only
          # the bounded error_kind escapes: the checkpoint wraps crypto
          # decrypt/encrypt calls, and their raw errors can carry secrets
          # (same invariant as Engram.Logger.DecryptFailure).
          Logger.warning(
            "crdt create checkpoint materialize failed",
            Metadata.with_category(:warning, :websocket,
              doc_id: note_id,
              error_kind: Engram.Telemetry.error_kind(e)
            )
          )

          :ok
      end
    end

    :ok
  end

  # Apply the client's genesis frame to the room's doc ONLY if the doc is still
  # empty, doing the check-and-apply ATOMICALLY inside the room GenServer. A plain
  # `get_doc` check followed by `send_yjs_message` is a read-then-write across two
  # separate room messages: two concurrent first-creates of the same note could
  # both read empty and both apply, doubling the body (#846). `SharedDoc.update_doc`
  # runs the fun in-room, serialized against every other message, so the second
  # create's fun observes the first's applied content and skips. The doc's
  # `monitor_update_v1` fires on `apply_update`, so the tail-log append + the
  # `note_yjs_update` fan-out are unchanged — the same in-room raw-apply idiom as
  # `CrdtTransport.apply_in_room` (the REST write path). Returns `:seeded` when THIS
  # call applied the frame, `:skipped` when the doc was already non-empty, `:error`
  # when the room is gone/malformed. `update_doc` is a synchronous
  # GenServer.call: the room runs the fun (which sends `{ref, result}` to us)
  # BEFORE it sends the reply, and message order between two processes is
  # preserved — so on a normal return the tagged message is already in our
  # mailbox. The bounded `after 5_000` is defense-in-depth against that
  # ordering assumption ever breaking (e.g. y_ex turning update_doc into a
  # cast), not a wait we expect to hit; a room that dies or times out
  # mid-call EXITS the call instead and is caught below, and the per-call ref
  # means a stale message from an earlier timed-out call can never satisfy a
  # later receive. A frame that is not a plain `sync_update` (never sent for
  # a genesis create) falls back to the guarded sync path.
  defp seed_genesis_if_empty(room, note_id, frame) do
    case Yex.Sync.message_decode(frame) do
      {:ok, {:sync, {:sync_update, update}}} ->
        parent = self()
        ref = make_ref()

        SharedDoc.update_doc(room, fn doc ->
          result =
            if CrdtBridge.text_of(doc) == "" do
              _ = Yex.apply_update(doc, update)
              :seeded
            else
              :skipped
            end

          send(parent, {ref, result})
          :ok
        end)

        receive do
          {^ref, result} -> result
        after
          5_000 -> :error
        end

      _ ->
        if CrdtBridge.text_of(SharedDoc.get_doc(room)) == "" do
          SharedDoc.send_yjs_message(room, frame)
          :seeded
        else
          :skipped
        end
    end
  catch
    :exit, reason ->
      Logger.warning(
        "crdt genesis seed room apply exited",
        Metadata.with_category(:warning, :sync, note_id: note_id, reason: inspect(reason))
      )

      :error
  end

  # A cursor is a non-negative seq. A malformed one (string, float, negative)
  # replies bad_cursor rather than raising into a FunctionClauseError that would
  # crash the whole channel — same defensive contract as cast_doc_id.
  defp cast_cursor(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp cast_cursor(_), do: {:error, :bad_cursor}

  # Untrusted composite-cursor id from the client. Only a valid UUID pairs with
  # the seq for the keyset; anything else (absent, garbage) degrades to seq-only
  # (nil) rather than rejecting — the id is a pagination refinement, not auth.
  defp cast_cursor_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp cast_cursor_id(_), do: nil

  defp cast_doc_id(doc_id) do
    case Ecto.UUID.cast(doc_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :bad_doc_id}
    end
  end

  # nil / non-binary / blank-after-trim path is rejected before it ever
  # reaches genesis_crdt_note/4 — path may be cleartext, so the reply never
  # echoes the raw value back.
  defp validate_create_path(p) when is_binary(p) do
    if String.trim(p) == "", do: {:error, :bad_path}, else: :ok
  end

  defp validate_create_path(_), do: {:error, :bad_path}

  @impl true
  def terminate(reason, socket) do
    Logger.info(
      "crdt leave",
      Metadata.with_category(:info, :websocket,
        conn_id: socket.assigns[:conn_id],
        device_id: socket.assigns[:device_id],
        topic: socket.topic,
        reason: inspect(reason)
      )
    )

    :ok
  end

  @impl true
  def handle_info({:yjs, frame, room}, socket) do
    cond do
      # Index frames come back on their own event (no doc_id) — checked FIRST so
      # an index room can never be mistaken for a note room whose pid was reused.
      room == socket.assigns[:index_room] ->
        push(socket, "crdt_index_msg", %{"b64" => Base.encode64(frame)})
        {:noreply, socket}

      doc_id = Map.get(socket.assigns.room_doc, room) ->
        push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(frame)})
        {:noreply, socket}

      true ->
        {:noreply, socket}
    end
  end

  # The room has gone idle and is asking its observers to let go (#1152). The
  # last unobserve trips the room's auto_exit, which checkpoints on terminate.
  #
  # What makes this safe is that the release and the eviction happen in the SAME
  # handle_info. A `sync_update` frame is a GenServer.cast
  # (deps/y_ex/lib/server/doc_server_worker.ex:26), so casting at a dead room
  # returns :ok and silently drops the edit — but this callback is atomic with
  # respect to the channel's mailbox, so no frame can be processed between the
  # two. A frame BEHIND this message re-resolves through ensure_room onto a
  # fresh room; one AHEAD of it already reached the room while it was live.
  # (Their relative order inside this function is therefore free, which is why
  # the release can now run first and report whether it actually succeeded.)
  #
  # ONLY forget the room if it is really gone. A room that failed to release is
  # still holding this channel in its observer_process map, so auto_exit can
  # never fire for it; dropping the pid here would also make every backed-off
  # re-ask a no-op ("not ours"), pinning the room for the life of the socket —
  # the unbounded residency this whole feature exists to prevent.
  @impl true
  def handle_info({:crdt_room_drain, room}, socket) do
    case Map.get(socket.assigns.room_doc, room) do
      nil ->
        # Not ours (a room we already released, or another channel's).
        {:noreply, socket}

      doc_id ->
        case release_room(room) do
          :retry ->
            {:noreply, socket}

          :gone ->
            case Map.get(socket.assigns.rooms, doc_id) do
              %{ref: ref} -> Process.demonitor(ref, [:flush])
              _ -> :ok
            end

            socket =
              socket
              |> assign(:rooms, Map.delete(socket.assigns.rooms, doc_id))
              |> assign(:room_doc, Map.delete(socket.assigns.room_doc, room))
              # Remember we let this one go, so the re-spin stays quiet (see the
              # announce in start_and_observe_room).
              |> assign(:drained, remember_drained(socket.assigns.drained, doc_id))

            {:noreply, socket}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    # The index room dying must clear its cache too, or the next frame casts at
    # a dead pid and returns :ok — the same silent-drop class the note-room
    # monitor exists to prevent.
    socket =
      if socket.assigns[:index_room] == pid,
        do: assign(socket, :index_room, nil),
        else: socket

    case Map.get(socket.assigns.room_doc, pid) do
      nil ->
        {:noreply, socket}

      doc_id ->
        socket =
          socket
          |> assign(:rooms, Map.delete(socket.assigns.rooms, doc_id))
          |> assign(:room_doc, Map.delete(socket.assigns.room_doc, pid))

        {:noreply, socket}
    end
  end

  @doc """
  Let go of `room` in response to a drain (#1152).

  Returns `:gone` when the caller may forget the room (released, or already
  dead), and `:retry` when it must NOT — the room is alive and still counts
  this channel as an observer, so forgetting it would strand the room with an
  observer it can never shed. The caller keeps the cached pid and the timer's
  backed-off re-ask tries again.

  `SharedDoc.unobserve/1` is a `GenServer.call` with y_ex's default 5 s timeout
  and no timeout knob, so a room that is dead — or alive but wedged — would
  either EXIT this channel or stall it for 5 s. Three guards, cheapest first:

    1. already dead → nothing to release;
    2. not answering within `#{@room_probe_ms}` ms → skip. Nothing is lost by
       skipping: `auto_exit` is driven by the room's own observer bookkeeping,
       so a room too wedged to answer was never going to exit on this unobserve
       anyway. The timer's backed-off re-ask picks it up when it recovers;
    3. otherwise unobserve — a room that answered the probe answers this too.

  The probe is `update_doc/3` with a no-op fun: PUBLIC API that takes a timeout,
  where `unobserve/1` does not. Reaching for `GenServer.call(room, {:unobserve,
  self()}, …)` instead would hard-code y_ex's private message shape, which fails
  silently on a dep bump; this costs one extra round-trip on a path that only
  runs at idle-drain frequency.

  `catch :exit` still backstops the gap between each check and the call.

  Public (`@doc false`-ish) because the dead/wedged paths are unreachable
  through the channel API — same reason `CrdtRegistry.observe_with_retry/3` is.
  """
  @spec release_room(pid()) :: :gone | :retry
  def release_room(room) do
    cond do
      locally_dead?(room) ->
        emit_drain(:skipped_dead)
        :gone

      not room_responsive?(room) ->
        # NOT routine, and not the same event as a dead room: this channel is
        # still in the room's observer_process map, so the room cannot auto_exit
        # until we succeed on a later re-ask. Loud, because a wedged room is an
        # incident and the counter alone cannot say how long it stayed wedged.
        Logger.warning(
          "crdt room #{inspect(room)} did not answer the drain probe; will re-ask",
          Engram.Logger.Metadata.with_category(:warning, :sync)
        )

        emit_drain(:skipped_unresponsive)
        :retry

      true ->
        SharedDoc.unobserve(room)
        emit_drain(:released)
        :gone
    end
  catch
    # The room died between a check and the call. Count it — otherwise this
    # drain is neither released nor skipped, and requests silently exceed
    # outcomes on the dashboard, which reads exactly like the leak this counter
    # exists to detect.
    #
    # A `{:timeout, _}` exit is the one case where the room is still ALIVE and
    # still holding us as an observer, so it must be retried, not forgotten.
    :exit, {:timeout, _} ->
      emit_drain(:skipped_unresponsive)
      :retry

    :exit, _ ->
      emit_drain(:skipped_dead)
      :gone
  end

  # Paired with the timer's :requested/:reasked counts, this is the signal that
  # answers "is the drain actually working in prod": requests far exceeding
  # releases means rooms are being asked to drain and not going away, which is
  # the unbounded-residency failure the whole feature exists to prevent. Without
  # it, #1152's "resident room count bounded under a soak" is unverifiable.
  # Cardinality contract: bounded phase atoms only — NEVER note/vault/user ids.
  defp emit_drain(phase) do
    :telemetry.execute(@drain_event, %{count: 1}, %{phase: phase})
    :ok
  end

  @doc """
  True only for a pid on THIS node that is already dead.

  `Process.alive?/1` is LOCAL-ONLY: it raises `ArgumentError` on a remote pid,
  and `ArgumentError` is `:error` class, so `release_room/1`'s `catch :exit`
  would NOT contain it. Rooms are `:global`-registered, so a channel on this
  node routinely observes a room on another one (clustering live since
  2026-06-23) — unguarded, this crashed the channel on every drain of a remote
  room.

  Remote rooms simply skip the fast path: `room_responsive?/1` is a
  GenServer.call, which exits catchably against a dead remote pid and is
  timeout-bounded regardless, so correctness never depended on this check.

  `self_node` is injectable so the remote branch is testable on a single node —
  the `:cluster`-tagged test that uses a real peer does not run in CI.
  """
  @spec locally_dead?(pid(), node()) :: boolean()
  def locally_dead?(room, self_node \\ node()),
    do: node(room) == self_node and not Process.alive?(room)

  defp room_responsive?(room) do
    SharedDoc.update_doc(room, fn _doc -> :ok end, room_probe_ms())
    true
  catch
    :exit, _ -> false
  end

  # `|| @room_probe_ms`, NOT `get_env/3` with a default: the three-arg form only
  # falls back when the key is ABSENT, so any writer that leaves the key set to
  # nil (e.g. a test restoring a previously-unset override) would feed `nil` to
  # GenServer.call/3 and crash the channel. Matches effective_msg_limit/0 above.
  defp room_probe_ms, do: Application.get_env(:engram, :crdt_room_probe_ms) || @room_probe_ms

  # A note_id is a non-sensitive UUID and is REQUIRED to diagnose which note
  # lost a dropped edit (redacting it under :path blocked the 2026-07-06
  # incident triage), so log a well-formed doc_id under the un-redacted
  # :note_id key. A doc_id that is NOT a UUID came from a stale path-keyed
  # client and may be a real cleartext path — keep those under the redacted
  # :path key so nothing sensitive ever leaks. The message body never carries
  # the id either way.
  # A create that fails for an unmodelled reason (crypto/KMS, changeset) still
  # replies the generic "create_failed" the wire contract defines — but the
  # REASON must reach the server log, or the client's retry loop is the only
  # evidence anything went wrong and the cause is undiagnosable from prod.
  defp log_create_failed(socket, note_id, reason) do
    Logger.warning(
      "crdt_create failed: #{reason}",
      Metadata.with_category(:warning, :websocket,
        note_id: note_id,
        user_id: socket.assigns.current_user.id,
        vault_id: socket.assigns.vault.id
      )
    )
  end

  # `other` in prepare_create's with/else is always a 2-tuple {:error, term}, so
  # error_kind/1 applied to it returns the literal :error and every failure logs
  # identically -- the swallow the arm exists to prevent. Unwrap first, then
  # classify the INNER term, which is what carries the useful distinction (a
  # changeset vs a KMS failure vs a filter-key error) without forwarding a raw
  # term that could carry key material.
  # Total by construction: every arm reaching prepare_create's else is a
  # {:error, term} (dialyzer rejects a fallback clause here as uncoverable).
  defp prepare_error_kind({:error, reason}), do: Engram.Telemetry.error_kind(reason)

  # ensure_room/2 only ever fails as {:error, atom}, so that reason is safe to
  # name verbatim. Anything else goes through error_kind/1 rather than inspect,
  # per Engram.Telemetry's "never forward the raw reason": an arbitrary error
  # term can carry key material, and only metadata keys are redacted.
  defp log_enroll_failed(socket, note_id, error) do
    reason =
      case error do
        {:error, atom} when is_atom(atom) -> atom
        other -> Engram.Telemetry.error_kind(other)
      end

    Logger.warning(
      "crdt_create_batch room enrollment failed: #{inspect(reason)}",
      Metadata.with_category(:warning, :websocket,
        note_id: note_id,
        user_id: socket.assigns.current_user.id,
        vault_id: socket.assigns.vault.id
      )
    )
  end

  # The index room accepts arbitrary client writes into a per-vault Y.Map that
  # has NO persistence (#1151), and therefore no checkpoint timer, no idle drain
  # and no LRU tracking — its only bound is `auto_exit` when the last socket
  # closes. Until #1151 gives it a checkpoint, an authenticated client could sit
  # on a connection growing one doc for the life of its session, against the
  # same 1 GB task this feature exists to protect.
  #
  # No client sends these yet (Engram-obsidian#362/#363), so the wire ships OFF
  # and the tests turn it on. "Deliberately inert" describes the SERVER; it is
  # not a property of an endpoint anyone can push to.
  defp index_enabled do
    if Application.get_env(:engram, :crdt_index_enabled, false),
      do: :ok,
      else: {:error, :index_disabled}
  end

  # y_ex answers `{:error, :unknown_message}` for a frame its decoder rejects
  # (deps/y_ex/lib/server/doc_server_worker.ex:30-37). Discarding that and
  # replying `{:ok, %{}}` anyway tells the client its edit was delivered when
  # y_ex threw it away — the same silent-drop class as casting into a dead room,
  # one step further down the pipe. guard_frame/1 does NOT cover this: it checks
  # state-vector plausibility, not that the frame is a well-formed Yjs message.
  defp relay_frame(room, frame) do
    case SharedDoc.send_yjs_message(room, frame) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rejected_by_ydoc, reason}}
    end
  end

  # NOT log_dropped/3: that keys the id as `note_id`, and an index frame has no
  # note. Handing it the vault id filed a VAULT under `note_id:`, silently
  # poisoning the one Loki query this metadata exists for — tracing a lost edit
  # back to its note. The vault is already carried in the attribution.
  defp log_index_dropped(socket, reason) do
    Logger.warning(
      "crdt_channel: dropped crdt_index_msg → #{inspect(reason)}",
      Metadata.with_category(:warning, :sync,
        user_id: socket.assigns.current_user.id,
        vault_id: socket.assigns.vault.id
      )
    )
  end

  defp log_dropped(socket, doc_id, reason) do
    id_meta =
      case Ecto.UUID.cast(doc_id) do
        {:ok, note_id} -> [note_id: note_id]
        :error -> [path: doc_id]
      end

    # Attribute the drop to a user + vault so a lost edit can be traced to who
    # hit it (the 2026-07-06 drops carried neither, so they were unattributable).
    attribution = [
      user_id: socket.assigns.current_user.id,
      vault_id: socket.assigns.vault.id
    ]

    Logger.warning(
      "crdt_channel: dropped crdt_msg → #{inspect(reason)}",
      Metadata.with_category(:warning, :sync, attribution ++ id_meta)
    )
  end

  # Rate-limit per DEVICE (not per account) so a single user's multiple devices
  # (desktop + laptop + web app, or two e2e Obsidian instances sharing one
  # session user) each get the full budget instead of self-DoSing against one
  # shared bucket. TWO layers:
  #
  #   1. per-device — `crdt_msg:<user_id>:<device>`. The `user_id` prefix is
  #      SERVER-derived, so the client-supplied device/conn id can only REFINE
  #      within its own tenant: it can never collide with another user's bucket
  #      (no cross-user griefing) nor spend anything but its own allowance.
  #   2. per-account ceiling — `crdt_msg:acct:<user_id>` at @account_multiplier×.
  #      Caps total account throughput so forging device ids / opening many
  #      sockets can't multiply the budget without bound.
  #
  # Both must allow. Per-device is checked first so a device that's already over
  # its own budget doesn't also consume from the account ceiling.
  # Classify WITHOUT decoding the payload: the first 4 base64 chars decode to
  # the frame's first 3 bytes. Yjs v1 wire layout (Yex.Sync doctests):
  # <<0, 0, ..>> STEP1, <<0, 1, ..>> STEP2, <<0, 2, ..>> update — all subtype
  # values < 128, so single-byte varints and the prefix match is exact.
  #
  # STEP1 is non-mutating (server just replies with a diff) and rides the
  # handshake lane unconditionally. STEP2 MUTATES the doc exactly like an
  # update (y_ex routes both into apply_update), so only SMALL STEP2 frames —
  # the near-empty echo replies connect enrollment produces in bulk — get the
  # handshake lane; a large STEP2 is a state-bearing mutation and pays the
  # edit budget. Without the size gate a client could relabel every edit as
  # STEP2 and mutate at 10x the intended cap.
  @hs_step2_max_b64 4096

  defp frame_class_b64(<<prefix::binary-size(4), _::binary>> = b64) do
    case Base.decode64(prefix) do
      {:ok, <<0, 0, _>>} -> :handshake
      {:ok, <<0, 1, _>>} when byte_size(b64) <= @hs_step2_max_b64 -> :handshake
      _ -> :edit
    end
  end

  # Shorter than 4 b64 chars cannot carry a valid handshake prefix; the edit
  # lane is the conservative default.
  defp frame_class_b64(_), do: :edit

  defp check_rate(socket, class) do
    {key_prefix, limit} =
      case class do
        # Handshakes get a 10x-larger bucket, NOT an exemption: STEP2 carries
        # full doc state, so an unbounded handshake lane would be a flood
        # vector. 2400/10s enrolls a 2400-note vault in one window while still
        # capping abuse; edits keep their own untouched budget either way.
        :handshake -> {"crdt_hs", effective_hs_limit()}
        :edit -> {"crdt_msg", effective_msg_limit()}
      end

    user_id = socket.assigns.current_user.id
    device = socket.assigns[:device_id] || socket.assigns[:conn_id] || "u"

    with {:allow, _} <-
           EngramWeb.RateLimiter.hit(
             "#{key_prefix}:#{user_id}:#{device}",
             @msg_scale_ms,
             limit,
             :other
           ),
         {:allow, _} <-
           EngramWeb.RateLimiter.hit(
             "#{key_prefix}:acct:#{user_id}",
             @msg_scale_ms,
             limit * @account_multiplier,
             :other
           ) do
      :ok
    else
      {:deny, _} -> {:error, :rate_limited}
    end
  end

  defp decode_frame(b64) when byte_size(b64) > @max_b64_bytes, do: {:error, :frame_too_large}

  defp decode_frame(b64) do
    case Base.decode64(b64) do
      {:ok, frame} when byte_size(frame) > @max_frame_bytes -> {:error, :frame_too_large}
      {:ok, frame} -> {:ok, frame}
      :error -> {:error, :bad_base64}
    end
  end

  # A syncStep1 frame carries a client state vector that reaches the y_ex NIF
  # (SharedDoc.send_yjs_message -> encode_state_as_update). A crafted vector
  # OOM-aborts the ENTIRE BEAM node, uncatchable — reuse the REST transport's
  # plausibility guard to reject it before it is applied (P0 #989). Non-step1
  # frames pass through unchanged.
  defp guard_frame(frame) do
    if CrdtTransport.safe_wire_frame?(frame), do: :ok, else: {:error, :implausible_state_vector}
  end

  # Lazily start + observe the room for `doc_id`, caching it in assigns. On the
  # first reference, validates doc_id (the note_id) belongs to the vault, then
  # calls CrdtRegistry.ensure_started and SharedDoc.observe so {:yjs, frame, room}
  # broadcasts arrive as handle_info messages in this channel process.
  defp ensure_room(socket, doc_id) do
    case Map.fetch(socket.assigns.rooms, doc_id) do
      {:ok, entry} ->
        {:ok, socket, entry}

      :error ->
        # Abuse backstop: refuse a new room once this socket already holds the max,
        # so one connection can't pin unbounded Y.Docs + pool connections. Reply-
        # carrying (see handle_in) so the client backs off. High ceiling for now.
        if map_size(socket.assigns.rooms) >= max_rooms() do
          {:error, :room_limit}
        else
          start_and_observe_room(socket, doc_id)
        end
    end
  end

  # Lazily start + observe this vault's index room, caching the pid. Mirrors
  # ensure_room/2 but needs no doc_id resolution: the vault IS the address.
  defp ensure_index_room(%{assigns: %{index_room: room}} = socket) when is_pid(room) do
    {:ok, socket, room}
  end

  defp ensure_index_room(socket) do
    %{vault: vault, current_user: user} = socket.assigns

    with {:ok, room} <- CrdtIndexRegistry.ensure_observed(user.id, vault.id) do
      # Same monitor rationale as note rooms: without it, a dead index room stays
      # cached and every later frame casts into a corpse, returning :ok.
      _ref = Process.monitor(room)
      {:ok, assign(socket, :index_room, room), room}
    end
  end

  defp start_and_observe_room(socket, doc_id) do
    %{vault: vault} = socket.assigns
    user = socket.assigns.current_user

    with {:ok, note_id} <- resolve_note_id(user, vault, doc_id),
         {:ok, room} <- CrdtRegistry.ensure_observed(user.id, vault.id, note_id) do
      # Watch the room: if it dies (crash, node loss), evict it from the cache so
      # the next crdt_msg re-creates it. Without this, send_yjs_message casts to a
      # dead pid return :ok and every subsequent edit is silently dropped.
      # NOTE: no per-room drain subscribe. The connection subscribes ONCE to its
      # vault's drain topic in join/3 — see the comment there for why per-room
      # was self-defeating.
      #
      # Keep the ref: the drain releases rooms that do NOT die (another observer
      # still holds it, or this socket re-spins fast enough to cancel auto_exit),
      # and each such cycle would otherwise leave a monitor behind on both this
      # channel and the room — unbounded within a long-lived socket.
      entry = %{room: room, note_id: note_id, ref: Process.monitor(room)}

      socket =
        socket
        |> assign(:rooms, Map.put(socket.assigns.rooms, doc_id, entry))
        |> assign(:room_doc, Map.put(socket.assigns.room_doc, room, doc_id))

      # Announce to all OTHER clients on this vault's crdt: channel that a
      # room is now active for doc_id. Recipients send a sync-step-1 (state
      # vector) which the server answers with step-2 (the diff they're
      # missing), so any device that doesn't yet have this note gets it.
      # Carry the note's path (best-effort) so a receiver can materialize an
      # empty note live rather than waiting for the pull — matches the
      # CrdtDeliver announce contract; the plugin treats "path" as optional, so
      # a failed lookup just omits it (never crash the room-open).
      #
      # SKIPPED when this socket previously released the room to an idle drain
      # (#1152). The announce is a DISCOVERY signal, and a re-spin discovers
      # nothing: every peer already learned about this note when it was first
      # announced. Re-announcing would make every drain->edit cycle fan a
      # syncStep1 out of every other device on the vault, against budgets that
      # are already tight (@hs_limit here, the plugin's 240/10s crdt_msg limit
      # in Engram-obsidian#159) — and handshake starvation is the documented
      # trigger for the wrong-mint cross-file overwrite class. The drain makes
      # re-spin routine rather than crash-only, so what used to be rare noise
      # would become a per-edit storm.
      #
      # Scoped to the drain path on purpose: a crash/node-loss re-spin still
      # announces exactly as before, since that peer state is genuinely unknown.
      {announce?, socket} = consume_drained(socket, doc_id)

      path =
        case Notes.get_note_by_id(user, vault, note_id) do
          {:ok, %{path: p}} when is_binary(p) -> p
          _ -> nil
        end

      if announce? or not backstopped?(path) do
        payload =
          if path, do: %{"doc_id" => doc_id, "path" => path}, else: %{"doc_id" => doc_id}

        broadcast_from!(socket, "crdt_doc_ready", payload)
      end

      {:ok, socket, entry}
    end
  end

  # Suppressing the re-announce is only safe where SOMETHING ELSE re-signals.
  # For `.md` that is `CrdtCheckpoint`, which calls `CrdtDeliver.announce_ready/4`
  # on the next content-changing checkpoint (eager flush, ~250 ms).
  #
  # That call is itself path-gated to `.md` (crdt_deliver.ex:134). So for any
  # other extension — `.canvas` today, which syncs through these same rooms with
  # no extension gate — the suppressed announce is the ONLY re-attach signal a
  # detached peer would get. Two devices on a canvas, room drains, both detach:
  # the one whose user is drawing re-spins the room, and the one who is only
  # WATCHING is attached to nothing and told nothing. It stays frozen until its
  # own user happens to draw.
  #
  # So suppress exactly what the backstop covers, and no more. If the `.md` gate
  # in announce_ready/4 ever widens, widen this with it.
  defp backstopped?(path), do: is_binary(path) and String.ends_with?(path, ".md")

  # `{announce?, socket}` — false exactly once per drain, so a LATER drain of the
  # same doc_id is independently suppressed rather than the note going
  # permanently silent.
  defp consume_drained(socket, doc_id) do
    if MapSet.member?(socket.assigns.drained, doc_id) do
      {false, assign(socket, :drained, MapSet.delete(socket.assigns.drained, doc_id))}
    else
      {true, socket}
    end
  end

  @doc """
  Record `doc_id` as drained, bounded at `cap`.

  Entries are consumed by the matching re-spin, but a note that is drained and
  never re-opened leaves one behind for the life of the socket — and
  `@default_max_rooms` bounds CONCURRENT rooms, not cumulative ones, while
  drain-churn is the intended steady state. So the set is capped.

  Overflow CLEARS rather than evicting one entry: it costs no ordering
  bookkeeping, and the degradation is safe in the only direction that matters —
  a forgotten doc_id just means its re-spin announces, which is exactly the
  pre-drain behaviour. Never incorrectness, only lost suppression.
  """
  @spec remember_drained(MapSet.t(), String.t(), pos_integer()) :: MapSet.t()
  def remember_drained(drained, doc_id, cap \\ @max_drained) do
    drained = MapSet.put(drained, doc_id)
    if MapSet.size(drained) > cap, do: MapSet.new(), else: drained
  end

  # doc_id IS the note_id (client-minted UUIDv7). Validate the note exists in
  # this vault before starting/observing its room. No path_hmac indirection.
  defp resolve_note_id(user, vault, doc_id) do
    case Ecto.UUID.cast(doc_id) do
      {:ok, note_id} ->
        if Notes.note_in_vault?(user, vault.id, note_id) do
          {:ok, note_id}
        else
          {:error, :not_found}
        end

      :error ->
        {:error, :bad_doc_id}
    end
  end

  # Per-socket room ceiling. Read from config at call time (not compiled in) so
  # ops can lower it live via Application.put_env under abuse, no redeploy.
  defp max_rooms, do: Application.get_env(:engram, :max_rooms_per_socket, @default_max_rooms)

  # Both limits are overridable via app env (a cached ETS read, so per-message
  # cheap). Two writers set it, never prod:
  #   - unit tests: Application.put_env(:engram, :crdt_msg_rate_limit_override, n)
  #     (crdt_channel_test.exs) so a test need not push 241 frames.
  #   - CI/E2E release stacks: config/runtime.exs sets it from the CI-gated
  #     CRDT_MSG_RATE_LIMIT_OVERRIDE env (Engram.RuntimeConfig), because the
  #     harness's compressed workload legitimately exceeds the per-account budget.
  # Prod never sets either (CI != true, no put_env), so effective_* falls back to
  # the @constant there — the limiter stays un-weakenable in production.
  defp effective_msg_limit,
    do: Application.get_env(:engram, :crdt_msg_rate_limit_override) || @msg_limit

  defp effective_hs_limit,
    do: Application.get_env(:engram, :crdt_hs_rate_limit_override) || @hs_limit
end
