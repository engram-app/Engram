# Genesis Seed Detached Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `crdt_create` carry a note's initial body and write it with a detached `Yex.Doc`, so importing a vault creates zero `SharedDoc` rooms.

**Architecture:** `crdt_create` gains an optional `b64` genesis frame. When genesis actually creates the row and no live room exists for it, the channel applies the frame to a throwaway `Yex.Doc` and calls `CrdtCheckpoint.checkpoint/5` directly, then reads the row back to confirm the write landed. The reply carries `seeded: true|false`; the plugin skips its `crdt_msg` body seed only when the server says `true`, so every failure path falls back to today's behaviour.

**Tech Stack:** Elixir 1.17 / Phoenix 1.8 channels, `y_ex` (Yjs NIF), Ecto/Postgres, ExUnit. Plugin side: TypeScript, Bun, Yjs.

**Spec:** Engram vault `50 Engineering/_Superpowers Specs/2026-08-18-bulk-vault-import-design.md`

**Issue:** engram-app/Engram#1409

## Global Constraints

- **Identity-as-CRDT is inviolable.** The Y-doc is the sole authority for note content. Never write `notes.content` directly; always go through `CrdtCheckpoint.checkpoint/5`.
- **Do not change `CrdtCheckpoint.checkpoint/5`'s contract.** It must keep never raising and returning `:ok` on skip. Its room-terminate caller depends on that.
- **Do not add a REST ingest path.** `POST /api/notes/batch` was deliberately removed; do not resurrect it or anything shaped like it.
- **Do not batch the per-file calls.** The plugin retired `crdt_create_batch` on purpose for per-file failure isolation (`sync.ts:7329`). Batching is explicitly out of scope.
- **`crdt_create` without `b64` must behave byte-for-byte as it does today.** Old plugin builds run against new servers.
- **Never version-bump.** release-please owns `mix.exs` and the plugin manifest.
- **Backend gates before push:** `mix format`, `mix credo --strict`, `mix dialyzer`, and the targeted test files with `--warnings-as-errors`. Do NOT run the full suite locally; CI owns it.
- **Work happens in the worktree** `engram/.worktrees/feat-genesis-seed-detached` on branch `feat/genesis-seed-detached`. Plugin work gets its own worktree and its own PR.

---

## File Structure

**Backend (repo `engram`)**

| File | Responsibility | Change |
|---|---|---|
| `lib/engram_web/channels/crdt_channel.ex` | Channel transport. Owns the `crdt_create` handler. | Modify: accept optional `b64`, add `maybe_seed_detached/4` + two small private helpers. |
| `test/engram_web/channels/crdt_channel_test.exs` | Channel behaviour tests. Already has `frame_for_content/1` and `assert_note_content_eventually/4`. | Modify: new `describe "crdt_create with b64"` block. |
| `lib/engram/notes.ex` | `genesis_crdt_note/5` docstring says content arrives via `crdt_msg`. | Modify: docstring only. No logic change. |

Everything the seed needs already exists (`CrdtCheckpoint.checkpoint/5`, `CrdtBridge.new_doc/0`, `CrdtRegistry.lookup/1`, `decode_frame/1`, `guard_frame/1`). No new modules.

**Plugin (repo `engram-obsidian-sync`)**

| File | Responsibility | Change |
|---|---|---|
| `src/channel.ts` | Socket RPC wrappers. `crdtCreate` at 484. | Modify: optional `b64` arg, return `{docId, seeded}`. |
| `src/main.ts` | Port wiring at 2244. | Modify: forward the new arg. |
| `src/sync.ts` | `pushFile` genesis branch at 3206-3313. | Modify: build the genesis frame up front for non-live-bound notes; skip `routeModify` when `seeded`. |
| `tests/` | Plugin unit tests. | Create/modify: cover the seeded and not-seeded paths. |

---

## Phase 1a — Backend

### Task 1: `crdt_create` accepts and ignores an unknown `b64`

Establishes the payload shape without behaviour change, so Task 2's test is about seeding rather than about pattern matching.

**Files:**
- Modify: `lib/engram_web/channels/crdt_channel.ex:336`
- Test: `test/engram_web/channels/crdt_channel_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `handle_in("crdt_create", payload, socket)` where `payload` is a map that always has `"doc_id"` and `"path"` and may have `"b64"`. Reply is `{:ok, %{doc_id: String.t(), seeded: boolean()}}`.

- [ ] **Step 1: Write the failing test**

Add to `test/engram_web/channels/crdt_channel_test.exs`, at the end of the existing `describe "crdt_create" do` block (which starts at line 55):

```elixir
    test "reply carries seeded: false when no b64 is sent", %{socket: socket} do
      id = Ecto.UUID.generate()
      ref = push(socket, "crdt_create", %{"doc_id" => id, "path" => "Notes/noseed.md"})
      assert_reply ref, :ok, %{doc_id: ^id, seeded: false}
    end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /home/open-claw/documents/code-projects/engram/.worktrees/feat-genesis-seed-detached
mix test test/engram_web/channels/crdt_channel_test.exs -k "seeded: false when no b64" 2>&1 | tail -30
```

Expected: FAIL. The reply is `%{doc_id: id}` with no `:seeded` key, so `assert_reply` does not match.

- [ ] **Step 3: Add the key to both success arms**

Leave the handler head at line 336 exactly as it is — Task 2 introduces the `payload` binding, and adding it now would fail `--warnings-as-errors` as an unused variable. This task only adds the reply key.

In `lib/engram_web/channels/crdt_channel.ex`, line 346-347 becomes:

```elixir
        {:ok, note} ->
          {:reply, {:ok, %{doc_id: note.id, seeded: false}}, socket}
```

Line 349-354 becomes:

```elixir
        {:adopted, note} ->
          # Unchanged behaviour for the single create: the client's crdtCreate
          # promise resolves to the authoritative id and pushFile's ADOPT then
          # transfers the local body onto that lineage. Only the BATCH leg has to
          # distinguish this from a create (it reports frame-applied, not id).
          #
          # seeded is ALWAYS false here even when the client sent a b64: adopting
          # means the path is owned by a different live note, and applying our
          # frame to it would overwrite that note's body. The ADOPT path transfers
          # the body deliberately; this must not shortcut it.
          {:reply, {:ok, %{doc_id: note.id, seeded: false}}, socket}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mix test test/engram_web/channels/crdt_channel_test.exs -k "seeded: false when no b64" --warnings-as-errors 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/channels/crdt_channel.ex test/engram_web/channels/crdt_channel_test.exs
git commit -m "feat(crdt): report seeded status on crdt_create replies"
```

---

### Task 2: Seed the body detached when `b64` is present

The core of the change.

**Files:**
- Modify: `lib/engram_web/channels/crdt_channel.ex` (handler at 336, new private helpers near `seed_and_checkpoint/5` at 773)
- Test: `test/engram_web/channels/crdt_channel_test.exs`

**Interfaces:**
- Consumes: Task 1's `seeded` reply key.
- Produces: `maybe_seed_detached(user, vault, note_id, b64_or_nil) :: boolean()`. Returns `true` only when the body is durably readable from the row afterwards.

- [ ] **Step 1: Write the failing test**

Add a new describe block after the existing `describe "crdt_create" do ... end` block:

```elixir
  describe "crdt_create with b64 (detached genesis seed)" do
    test "persists the body and creates NO room", %{socket: socket, user: user, vault: vault} do
      id = Ecto.UUID.generate()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/seeded.md",
          "b64" => frame_for_content("hello from genesis")
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: true}
      assert_note_content_eventually(user, vault, id, "hello from genesis")

      # The whole point: no SharedDoc actor was started for this note.
      assert CrdtRegistry.lookup(id) == nil
    end

    test "seeding the same note twice does not double the body", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # #846: a client retry re-sends the create. The create-time checkpoint
      # flattens the doc to a fresh server lineage, so a naive re-apply APPENDS
      # rather than merging as a no-op and the body doubles.
      id = Ecto.UUID.generate()
      frame = frame_for_content("once")
      payload = %{"doc_id" => id, "path" => "Notes/retry.md", "b64" => frame}

      ref1 = push(socket, "crdt_create", payload)
      assert_reply ref1, :ok, %{seeded: true}
      assert_note_content_eventually(user, vault, id, "once")

      ref2 = push(socket, "crdt_create", payload)
      assert_reply ref2, :ok, %{doc_id: ^id}

      assert {:ok, note} = Notes.get_note_by_id(user, vault, id)
      assert note.content == "once"
    end

    test "a live room for the note skips the detached seed", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # Two writers, one document. A detached write would be invisible to the
      # room, which later checkpoints its own in-memory doc over it.
      #
      # The realistic shape: the create is retried (it is idempotent) after the
      # user opened the note in an editor, so a room now exists for it.
      id = Ecto.UUID.generate()
      ref1 = push(socket, "crdt_create", %{"doc_id" => id, "path" => "Notes/live.md"})
      assert_reply ref1, :ok, %{doc_id: ^id}

      {:ok, _room} = CrdtRegistry.ensure_started(user.id, vault.id, id)
      on_exit(fn -> CrdtRegistry.terminate_room(id) end)

      ref2 =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/live.md",
          "b64" => frame_for_content("body")
        })

      assert_reply ref2, :ok, %{doc_id: ^id, seeded: false}
    end

    test "a detached seed materializes the same content as the same frame through a room", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # The equivalence this design rests on: "detached" must be a deployment
      # detail, not a second semantics. Same frame, two routes, one result.
      frame = frame_for_content("# Title\n\nshared body")

      detached_id = Ecto.UUID.generate()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => detached_id,
          "path" => "Notes/detached.md",
          "b64" => frame
        })

      assert_reply ref, :ok, %{seeded: true}

      roomed_id = Ecto.UUID.generate()
      ref2 = push(socket, "crdt_create", %{"doc_id" => roomed_id, "path" => "Notes/roomed.md"})
      assert_reply ref2, :ok, %{doc_id: ^roomed_id}
      push(socket, "crdt_msg", %{"doc_id" => roomed_id, "b64" => frame})

      assert_note_content_eventually(user, vault, roomed_id, "# Title\n\nshared body")
      assert_note_content_eventually(user, vault, detached_id, "# Title\n\nshared body")

      assert {:ok, detached} = Notes.get_note_by_id(user, vault, detached_id)
      assert {:ok, roomed} = Notes.get_note_by_id(user, vault, roomed_id)
      assert detached.content == roomed.content
    end

    test "a malformed b64 creates the row and reports seeded: false", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # The row must still exist: identity and content are separate concerns, and
      # the client's fallback is a crdt_msg seed against that row.
      id = Ecto.UUID.generate()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/bad.md",
          "b64" => "!!!not base64!!!"
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: false}
      assert Notes.note_in_vault?(user, vault, id)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/engram_web/channels/crdt_channel_test.exs -k "detached genesis seed" 2>&1 | tail -40
```

Expected: FAIL. The first two fail because `seeded` is always `false` and the content never lands; the live-room and malformed cases pass vacuously for now.

- [ ] **Step 3: Implement the seed**

In `lib/engram_web/channels/crdt_channel.ex`, change the handler head at line 336 to bind the payload:

```elixir
  def handle_in("crdt_create", %{"doc_id" => doc_id, "path" => path} = payload, socket) do
```

Replace the `{:ok, note}` arm from Task 1 with:

```elixir
        {:ok, note} ->
          seeded = maybe_seed_detached(user, vault, note.id, Map.get(payload, "b64"))
          {:reply, {:ok, %{doc_id: note.id, seeded: seeded}}, socket}
```

Add these private functions immediately after `seed_and_checkpoint/5` (which ends at line 816):

```elixir
  # Genesis-time content seed WITHOUT a room (#1409). A brand-new note has no
  # collaborators — no awareness peers, no fan-out subscribers, nobody to
  # serialize against — so paying for a SharedDoc actor (plus its :global name,
  # checkpoint timer, observer monitor and LRU slot) to perform what is really an
  # insert is what made a 1,700-file import allocate ~2,000 processes and 324 MB.
  # A throwaway Yex.Doc runs the SAME apply-and-checkpoint code the room's
  # persistence layer runs, then goes out of scope.
  #
  # Returns whether the body is DURABLY READABLE afterwards, not whether we tried.
  # `CrdtCheckpoint.checkpoint/5` deliberately never raises and returns `:ok` even
  # when it skips (DEK rotation in progress, deleted user — see #1341), which is
  # correct for its room-terminate caller and actively wrong here: a `true` reply
  # makes the plugin stamp its local body as the synced baseline and stop, so a
  # skipped checkpoint would silently lose the file with no later bind to replay
  # from. Every `false` path falls back to the client's existing crdt_msg seed.
  defp maybe_seed_detached(_user, _vault, _note_id, nil), do: false

  defp maybe_seed_detached(user, vault, note_id, b64) when is_binary(b64) do
    with {:ok, frame} <- decode_frame(b64),
         :ok <- guard_frame(frame),
         {:ok, {:sync, {:sync_update, update}}} <- Yex.Sync.message_decode(frame),
         # Two writers, one document: a room holds the doc in memory and would
         # later checkpoint over anything written behind its back. CheckpointNote
         # snoozes on this exact condition (checkpoint_note.ex:50); a channel
         # cannot snooze, so we decline and let the client's crdt_msg path — which
         # goes THROUGH the room — do it.
         nil <- CrdtRegistry.lookup(note_id),
         {:ok, doc} <- apply_detached(update),
         expected = CrdtBridge.text_of(doc),
         {:ok, note} <- Notes.get_note_by_id(user, vault, note_id) do
      seed_empty_row(user, vault, note_id, doc, expected, note.content)
    else
      _ -> false
    end
  end

  # #846, the detached twin of seed_genesis_if_empty/3. The room path guards its
  # apply on the doc still being empty because the create-time checkpoint
  # FLATTENS the doc to a fresh server lineage: re-applying the client's original
  # lineage afterwards no longer merges as a no-op, Yjs APPENDS it, and the body
  # doubles. `crdt_create` is idempotent and clients do retry it, so the detached
  # path needs the same guard — taken against the row, which is the durable
  # equivalent of the room's in-memory doc.
  #
  # Already exactly this body: an idempotent retry with nothing to write. Report
  # true — the client's file IS synced, which is what `seeded` means.
  defp seed_empty_row(_user, _vault, _note_id, _doc, expected, expected), do: true

  defp seed_empty_row(user, vault, note_id, doc, expected, "") do
    captured_version = CrdtCheckpoint.current_version(user.id, note_id)

    _ =
      CrdtCheckpoint.checkpoint(user.id, vault.id, note_id, doc,
        captured_version: captured_version
      )

    seed_landed?(user, vault, note_id, expected)
  end

  # The row already carries a DIFFERENT body — a concurrent write landed between
  # genesis and here. Merging two lineages is exactly what a room is for; decline
  # and let the client's crdt_msg seed go through one.
  defp seed_empty_row(_user, _vault, _note_id, _doc, _expected, _row_content), do: false

  defp maybe_seed_detached(_user, _vault, _note_id, _b64), do: false

  # A crafted update can abort inside the y_ex NIF. Contain it: a bad frame costs
  # this note its seed (the client re-sends over crdt_msg), never the channel.
  defp apply_detached(update) do
    doc = CrdtBridge.new_doc()

    case Yex.apply_update(doc, update) do
      :ok -> {:ok, doc}
      _ -> :error
    end
  rescue
    e ->
      Logger.warning(
        "crdt genesis detached seed apply failed",
        Metadata.with_category(:warning, :sync, error_kind: Engram.Telemetry.error_kind(e))
      )

      :error
  end

  # Read-back, not a rotation pre-check: `checkpoint/5` can skip for reasons
  # beyond rotation and reports none of them, so the only honest signal is
  # whether the row now projects the body we applied. One indexed primary-key
  # read is noise next to the SharedDoc process this replaces. A re-seed of an
  # already-correct row returns true (idempotent), which is what the #846 retry
  # case needs.
  defp seed_landed?(user, vault, note_id, expected) do
    case Notes.get_note_by_id(user, vault, note_id) do
      {:ok, %{content: ^expected}} -> true
      _ -> false
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/engram_web/channels/crdt_channel_test.exs -k "detached genesis seed" --warnings-as-errors 2>&1 | tail -30
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Run the whole channel test file for regressions**

```bash
mix test test/engram_web/channels/crdt_channel_test.exs --warnings-as-errors 2>&1 | tail -20
```

Expected: PASS, no failures. This file covers `crdt_create_batch`, `crdt_msg` and the drain, all of which share the helpers touched here.

- [ ] **Step 6: Commit**

```bash
git add lib/engram_web/channels/crdt_channel.ex test/engram_web/channels/crdt_channel_test.exs
git commit -m "feat(crdt): seed genesis content on a detached doc, no room

A 1,700-file import created ~1,700 SharedDoc rooms because the body
arrived as a separate crdt_msg. crdt_create now optionally carries the
genesis frame and applies it to a throwaway Yex.Doc.

Refs #1409"
```

---

### Task 3: Pin the rotation silent-skip

Hazard 2 from the spec, as its own test because it is the failure this design is most likely to ship blind.

**Files:**
- Test: `test/engram_web/channels/crdt_channel_test.exs`

**Interfaces:**
- Consumes: `maybe_seed_detached/4` from Task 2.
- Produces: nothing new.

- [ ] **Step 1: Write the test**

Add inside the `describe "crdt_create with b64 (detached genesis seed)"` block:

```elixir
    test "a DEK rotation in progress reports seeded: false and leaves the row empty", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # CrdtCheckpoint.checkpoint/5 returns :ok when it SKIPS for rotation
      # (#1341). Building the reply from that :ok would tell the plugin the file
      # is synced while nothing was written — and a fresh import has no later
      # bind to replay from, so the note would just be empty forever.
      id = Ecto.UUID.generate()

      {:ok, _} =
        user
        |> Ecto.Changeset.change(dek_rotation_locked_at: DateTime.utc_now())
        |> Repo.update()

      ref =
        push(socket, "crdt_create", %{
          "doc_id" => id,
          "path" => "Notes/rotating.md",
          "b64" => frame_for_content("must not be reported as synced")
        })

      assert_reply ref, :ok, %{doc_id: ^id, seeded: false}

      assert {:ok, note} = Notes.get_note_by_id(user, vault, id)
      assert note.content == ""
    end
```

- [ ] **Step 2: Run it**

```bash
mix test test/engram_web/channels/crdt_channel_test.exs -k "DEK rotation in progress reports" --warnings-as-errors 2>&1 | tail -30
```

Expected: PASS. The read-back in `seed_landed?/4` already covers this; the test pins it so a future refactor to a cheaper "did we call checkpoint" signal fails loudly.

If it FAILS, do not weaken the test. The read-back is the contract.

- [ ] **Step 3: Commit**

```bash
git add test/engram_web/channels/crdt_channel_test.exs
git commit -m "test(crdt): pin that a rotation-skipped seed reports seeded: false"
```

---

### Task 4: Correct the `genesis_crdt_note/5` docstring

It currently states the opposite of what is now true, and it is the first thing anyone reads on this path.

**Files:**
- Modify: `lib/engram/notes.ex:819-824`

**Interfaces:**
- Consumes: nothing. Produces: nothing. Documentation only.

- [ ] **Step 1: Replace the docstring**

```elixir
  @doc """
  Create/resurrect/adopt a BARE note row for a client-minted id over CRDT
  (crdt_create). This function never writes content: it never merges empty
  content against an existing row and never content-broadcasts.

  Content is applied SEPARATELY by the caller, either as a detached genesis seed
  when `crdt_create` carried a `b64` frame (#1409, the import path — no room), or
  as a later `crdt_msg` through the note's live room (the editor path). See docs
  spec 2026-07-15-crdt-create-genesis-bare-row-design.
  """
```

- [ ] **Step 2: Verify it compiles clean**

```bash
mix compile --warnings-as-errors 2>&1 | tail -5
```

Expected: no warnings.

- [ ] **Step 3: Commit**

```bash
git add lib/engram/notes.ex
git commit -m "docs(notes): genesis content can arrive detached, not only via crdt_msg"
```

---

### Task 5: Backend gates and PR

**Files:** none changed.

- [ ] **Step 1: Run the local gate set**

Sequentially, never concurrently — parallel dialyzer starves the DB and fabricates test failures.

```bash
cd /home/open-claw/documents/code-projects/engram/.worktrees/feat-genesis-seed-detached
mix format
mix credo --strict 2>&1 | tail -20
mix dialyzer 2>&1 | tail -20
mix test test/engram_web/channels/ test/lint/ --warnings-as-errors 2>&1 | tail -20
```

Expected: format clean, credo clean, dialyzer `done (passed successfully)`, tests 0 failures. `test/lint/` is included because those are full-suite-only meta-tests a targeted run would otherwise skip.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin feat/genesis-seed-detached
gh pr create --title "feat(crdt): seed genesis content detached, no room per import file" --body "$(cat <<'EOF'
Importing a 1,700-file vault created ~1,700 `SharedDoc` rooms: `crdt_create` made the row, then the body arrived as a separate `crdt_msg`, and `crdt_msg` calls `ensure_room`. Measured in prod on 2026-08-18: process count 757 -> 2,744, process memory 41 MB -> 324 MB against an 820 MB limit, run queue 9 on 0.5 vCPU.

`crdt_create` now optionally carries the genesis frame as `b64` and applies it to a throwaway `Yex.Doc`, then checkpoints. No `SharedDoc`, no `:global` name, no timer, no monitor, no LRU slot. Rooms are created only when a note is opened in an editor.

Two hazards this handles explicitly:

- **A live room for the note.** A detached write would be invisible to it and later overwritten. Declined, same condition `CheckpointNote` snoozes on.
- **`checkpoint/5` returns `:ok` when it skips** (DEK rotation, #1341). Building the reply from that would report a file synced that was never written, with no later bind to replay from. The reply is built from a read-back instead.

`seeded: false` is always a safe answer: the client falls back to its existing `crdt_msg` seed. Omitting `b64` behaves exactly as today, so older plugin builds are unaffected.

Paired plugin PR sends the frame. Merge this first.

Refs #1409
EOF
)"
```

- [ ] **Step 3: Confirm CI is green before merging**

```bash
gh pr checks --watch
```

Never merge on red, including diagnosed flakes.

---

## Phase 1b — Plugin

Ships after the backend PR merges. The server tolerates a client that never sends `b64`, so there is no deploy ordering hazard in the other direction.

### Task 6: `channel.crdtCreate` sends the frame and returns the seeded flag

**Files:**
- Modify: `src/channel.ts:480-489`
- Modify: `src/main.ts:2244`

**Interfaces:**
- Consumes: the backend reply `{doc_id: string, seeded: boolean}`.
- Produces: `crdtCreate(docId: string, path: string, b64?: string): Promise<{docId: string; seeded: boolean}>`. Note this changes the return type from `Promise<string>`; every caller must be updated in this task.

- [ ] **Step 1: Write the failing test**

In `tests/channel-crdt.test.ts` (the existing home of `crdtCreate` channel coverage), add a case asserting the payload carries `b64` and the result destructures. Reuse that file's existing socket/reply harness rather than the illustrative `makeChannel` below:

```ts
it("crdtCreate forwards the genesis frame and returns the seeded flag", async () => {
	const sent: Array<Record<string, unknown>> = [];
	const channel = makeChannel({
		onSend: (payload) => sent.push(payload as Record<string, unknown>),
		reply: { doc_id: "server-id", seeded: true },
	});

	const res = await channel.crdtCreate("local-id", "A.md", "BASE64FRAME");

	expect(sent[0]).toMatchObject({ doc_id: "local-id", path: "A.md", b64: "BASE64FRAME" });
	expect(res).toEqual({ docId: "server-id", seeded: true });
});
```

Match the existing harness in the channel test file rather than inventing `makeChannel` if a helper already exists there; reuse it.

- [ ] **Step 2: Run it**

```bash
cd <plugin-worktree> && bun test tests/channel-crdt.test.ts 2>&1 | tail -20
```

Expected: FAIL, `crdtCreate` takes two args and returns a string.

- [ ] **Step 3: Implement**

Replace `src/channel.ts:480-489`:

```ts
	/** Genesis a server row over the socket. Returns the server's authoritative
	 *  doc_id — on ADOPT (path already owned by a different live note) the server
	 *  returns a DIFFERENT id, which Task 3 uses to remap the local note and avoid
	 *  orphaning edits.
	 *
	 *  `b64` is an optional genesis frame (#1409). When present the server applies
	 *  it to a detached Y.Doc and checkpoints it WITHOUT opening a room, which is
	 *  what keeps a full-vault import from allocating one OTP process per file.
	 *  `seeded` reports whether the body is durably readable server-side; it is
	 *  false on adopt, on a live room, on a malformed frame, and on any checkpoint
	 *  skip. A false ALWAYS means "fall back to the crdt_msg seed", never "retry
	 *  the create". */
	async crdtCreate(
		docId: string,
		path: string,
		b64?: string,
	): Promise<{ docId: string; seeded: boolean }> {
		const res = (await this.sendRequest("crdt_create", {
			doc_id: docId,
			path,
			...(b64 === undefined ? {} : { b64 }),
		})) as { doc_id: string; seeded?: boolean };
		return { docId: res.doc_id, seeded: res.seeded === true };
	}
```

`res.seeded === true` rather than a truthiness check: an older server omits the key, and the safe default is "not seeded".

Update the port wiring at `src/main.ts:2244`:

```ts
					create: (id, path, b64) => channel.crdtCreate(id, path, b64),
```

- [ ] **Step 4: Run tests and typecheck**

```bash
bun test tests/channel-crdt.test.ts 2>&1 | tail -20
bun run build 2>&1 | tail -20
```

Expected: test passes. `bun run build` runs `tsc` and WILL fail on `sync.ts`, whose `crdtCreate` call still expects a string. That is the correct signal; Task 7 fixes it. Do not commit until Task 7 compiles.

- [ ] **Step 5: Hold the commit**

The port type change and its only consumer land together, so this task's diff is committed at the end of Task 7.

---

### Task 7: `pushFile` builds the frame and skips the redundant seed

**Files:**
- Modify: `src/sync.ts:1034` (the `crdtCreate` field type), `src/sync.ts:3206-3313` (the genesis branch)

**Interfaces:**
- Consumes: `crdtCreate(docId, path, b64?) => Promise<{docId, seeded}>` from Task 6.
- Produces: no new exports.

- [ ] **Step 1: Update the port field type**

At `src/sync.ts:1034`:

```ts
	private crdtCreate:
		| ((docId: string, path: string, b64?: string) => Promise<{ docId: string; seeded: boolean }>)
		| null = null;
```

- [ ] **Step 2: Write the failing test**

Add to `tests/sync.test.ts` (which already covers `pushFile`'s genesis branch). Reuse that file's existing engine and file fixtures rather than the illustrative stubs below:

```ts
it("skips the crdt_msg body seed when the server seeded the note at genesis", async () => {
	const routeModifyCalls: string[] = [];
	const engine = makeEngineWithGenesisStub({
		crdtCreate: async () => ({ docId: "note-1", seeded: true }),
		onRouteModify: (id: string) => routeModifyCalls.push(id),
	});

	await engine.pushFile(fileFixture("A.md", "body"));

	expect(routeModifyCalls).toEqual([]);
});

it("falls back to the crdt_msg body seed when the server did not seed", async () => {
	const routeModifyCalls: string[] = [];
	const engine = makeEngineWithGenesisStub({
		crdtCreate: async () => ({ docId: "note-1", seeded: false }),
		onRouteModify: (id: string) => routeModifyCalls.push(id),
	});

	await engine.pushFile(fileFixture("A.md", "body"));

	expect(routeModifyCalls).toEqual(["note-1"]);
});
```

- [ ] **Step 3: Run to verify failure**

```bash
bun test tests/sync.test.ts -t "genesis" 2>&1 | tail -30
```

Expected: FAIL.

- [ ] **Step 4: Implement**

In the genesis branch at `src/sync.ts:3206`, build the frame before the create call. Only for notes that are NOT live-bound: for a live-bound note the frozen `content` can lag the user's unflushed keystrokes, which is exactly why the existing code does a live `cachedRead` inside `routeModify`.

Immediately before line 3222 (`const serverId = await this.crdtCreate(...)`):

```ts
							// #1409: hand the body to the create so the server can write it
							// with a detached Y.Doc instead of opening a room per file. Only
							// for idle notes — a live-bound note's frozen `content` can lag
							// unflushed keystrokes, so it keeps the routeModify path, which
							// rereads and goes through the room the editor is already using.
							const genesisFrame = this.isLiveBound(normalizePath(pushedPath))
								? undefined
								: genesisFrameFor(content);
```

Replace line 3222 and the `serverId` binding:

```ts
							const { docId: serverId, seeded } = await this.crdtCreate(
								noteId,
								pushedPath,
								genesisFrame,
							);
```

Then guard the seed at line 3300. Replace the `consumed = await routeModify(...)` call with:

```ts
									// The server already applied our genesis frame and confirmed
									// the body is durably readable, so re-sending it over crdt_msg
									// would open the very room this exists to avoid. `seeded` is
									// false on every uncertain path (adopt, live room, bad frame,
									// checkpoint skip), so this only short-circuits on a positive
									// confirmation.
									consumed = seeded
										? content
										: await routeModify(
												{
													crdtEligible: true,
													noteId: effectiveId,
													readContent: () => this.app.vault.cachedRead(file),
												},
												this.crdt,
												MAX_CRDT_NOTE_BYTES,
											);
```

`consumed = content` on the seeded path because `adoptCreateAck` uses `consumed` as the baseline to stamp, and `content` is exactly what the server now holds.

Add the frame builder to `src/crdt/note-seed.ts`, next to `seedContentInto` (line 65), exported:

```ts
/** Encode `content` as a base64 `messageSync` update frame — the genesis body a
 *  brand-new note hands to `crdt_create` so the server can persist it with a
 *  detached doc instead of opening a room (#1409).
 *
 *  Routes through `seedContentInto`, NOT `seedOnce`: frontmatter lives in its own
 *  Y.Map, and seeding the raw string into the body Y.Text would ship the YAML
 *  block as literal body text on every imported note. `encodeUpdateFrame` is the
 *  same codec the live crdt_msg path uses, so the two are byte-identical. */
export function genesisFrameFor(content: string): string {
	const doc = new Y.Doc();
	try {
		seedContentInto(doc, doc.getText(CONTENT_KEY), content, false);
		return encodeUpdateFrame(Y.encodeStateAsUpdate(doc));
	} finally {
		doc.destroy();
	}
}
```

Imports needed in `note-seed.ts`: `CONTENT_KEY` from `./frontmatter-codec` (already imported there) and `encodeUpdateFrame` from `./wire`. `Y` is already imported.

**Canvas files keep the old path.** `seedContentInto` is the markdown seeder; canvas docs have their own shape (`canvasIsEmpty`, `note-seed.ts:29`). Gate the fast path on markdown so a canvas note falls through to `routeModify` unchanged:

```ts
							const genesisFrame =
								file.extension === "md" && !this.isLiveBound(normalizePath(pushedPath))
									? genesisFrameFor(content)
									: undefined;
```

Use this in place of the `genesisFrame` binding shown earlier in this step.

- [ ] **Step 5: Run tests, lints and build**

```bash
bun test 2>&1 | tail -20
./node_modules/.bin/biome ci 2>&1 | tail -20
bun run lint:obsidian 2>&1 | tail -10
bun run lint:css 2>&1 | tail -10
bun run build 2>&1 | tail -20
```

Expected: all clean. `biome` must be the local binary, not `bunx` (which resolves a different version). `lint:obsidian` and `lint:css` are CI-only gates that do not run in the default lint task.

- [ ] **Step 6: Commit both tasks**

```bash
git add src/channel.ts src/main.ts src/sync.ts src/crdt/note-seed.ts tests/channel-crdt.test.ts tests/sync.test.ts
git commit -m "feat(crdt): send the genesis body with crdt_create

An idle new note now hands its body to crdt_create, which the server
writes with a detached doc. Live-bound notes keep the routeModify path.
Falls back to the crdt_msg seed whenever the server reports seeded=false.

Refs #1409"
```

---

### Task 8: Pair the branches in e2e and open the plugin PR

The backend and plugin changes only exercise each other end to end when e2e runs them together.

**Files:** none changed.

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin feat/genesis-seed-detached
gh pr create --title "feat(crdt): send the genesis body with crdt_create" --body "Pairs with engram#<backend PR number>. Refs #1409"
```

- [ ] **Step 2: Pair the branches**

Follow `docs/context/oauth-e2e-pairing-and-token-binding.md` to run the plugin branch against the backend branch. Both PRs go red until they are paired; that is expected and is not a defect in either.

- [ ] **Step 3: Add the e2e room-count assertion**

In the e2e suite, extend the existing bulk first-sync test to assert the room count does not scale with file count:

```
after a first sync of N notes with no editor open,
  the server's resident CRDT room count is 0
```

Use whatever room-count probe `crdt_channel_drain_test.exs` and the drain e2e already use rather than adding a new endpoint.

- [ ] **Step 4: Confirm both PRs are green, then merge backend first**

---

## Deferred: Phase 2 — runtime-configurable Oban queues

The spec's deployment-topology section is deliberately NOT in this plan. It is independent of the import fix (which is a channel handler on the web path), and the spec gates it on the measurement below. It gets its own plan once that measurement says enrichment is the next ceiling.

## Measurement, before merging Phase 1a

Per the spec, sizing is validated against a post-fix baseline, because the 2026-08-18 profile was dominated by the since-fixed `LangDetect` per-chunk bug.

- [ ] Deploy #1413 and #1417 to staging.
- [ ] Run a 1,700-file import against staging.
- [ ] Capture: peak process count, peak process memory, `crdt_room_drain_total`, checkpoint failure count, and the wall-time split across ingest / embed / index.
- [ ] Record the numbers on #1409. The ingest-vs-enrichment split is what decides whether Phase 2 is needed at all.
