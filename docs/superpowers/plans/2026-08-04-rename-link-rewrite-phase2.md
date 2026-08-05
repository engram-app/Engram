# Rename/Move Link-Rewrite Propagation — Phase 2 Implementation Plan (CRDT-origin renames)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Issues:** engram#648, engram#1231 · **Depends on:** Phase 1 (this branch, PR #1240 — `Engram.Links.Rewriter` + `Engram.Workers.RewriteNoteLinks` wired into `Notes.rename_note/4` and `Attachments.move_attachment/4`)

## Goal

CRDT-origin renames get server-side link rewrites with the same ONE-REWRITER INVARIANT as Phase 1: a rename that Obsidian originated must NEVER trigger a server rewrite (Obsidian's "Automatically update internal links" owns those); a web-originated rename must trigger exactly one. The sync socket declares `client_type` (`"obsidian" | "web"`) at join; `CrdtChannel` threads it to the identity projection (`genesis_relocate_live` in `notes.ex`), which enqueues `RewriteNoteLinks` only when origin ≠ obsidian.

**Deliberate temporary compromise (ships in this PR, removed later by a one-line flip):** the backend gate ships BEFORE the plugin tag is required. An UNTAGGED crdt join is treated as plugin-origin (no enqueue) so version-skewed old plugins never double-rewrite. The default lives in ONE named module attribute (`@untagged_crdt_client_type` in `Engram.Notes`) with a loud comment; after the tagged plugin release has been out one release cycle, flipping the attribute to `"web"` restores the spec's safe default. We do NOT model the release-cycle wait in code. A PRESENT-but-unknown tag (e.g. a future `"mobile"`) is not a version-skewed plugin — it enqueues (spec: "absent/unknown ⇒ enqueue" applies un-compromised to unknown-but-present).

## Architecture

**The rename call chain (verified in code):** a CRDT-origin rename does NOT arrive through `crdt_msg` update processing. Web and plugin both rename by sending `crdt_create` with a KNOWN live id at a new path — `CrdtChannel.handle_in("crdt_create", ...)` (`crdt_channel.ex:216`) or a `crdt_create_batch` entry via `prepare_create/3` (`crdt_channel.ex:520`) → `Notes.genesis_crdt_note/4` (`notes.ex:706`) → `classify_by_id` `{:live, note}` branch → `same_path?` false → `genesis_relocate_live/5` (`notes.ex:877`, the "Phase E2 rename-as-move" seam, whose own comment calls it "the primary rename path for web/plugin"). Threading is therefore two hops: socket assign at join → `genesis_crdt_note` opts → `genesis_relocate_live` param. No N-layer plumbing, no channel-side enqueue keyed on observed relocates.

**The OLD-PATH problem (verified):** `genesis_relocate_live` relocates via `move_note/5` (`notes.ex:1255`), which is an in-place `Repo.update` on the prior row (repoint path/path_hmac, `deleted_at: nil`) — it inserts **NO tombstone row at the old path**. Only REST's `do_rename_note_inner` (`notes.ex:~1930`, "Insert a soft-deleted tombstone for the OLD path") creates one. Phase 1's worker recovers the plaintext old path exclusively from that tombstone (`tombstone_old_path/4` → `{:discard, :old_path_unrecoverable}` when absent) — so a CRDT-relocate job with Phase 1 args alone would always discard. And the plaintext old path is genuinely required at run time: `Rewriter.build_target/5` threads it into `plan_edits/5`, where `Links.pre_rename_winner?/6` (`links.ex:332`) injects `{renamed_id, old_path}` into the pre-rename candidate set and resolves possibly path-qualified occurrence text against candidate PATHS — an HMAC cannot do that.

**Fallback old-path source:** the enqueue site (`genesis_relocate_live`) has the old plaintext path in scope (`decrypted.path`). Args may not carry plaintext (T3.2), so the job additionally carries `old_path_ciphertext` + `old_path_nonce`: user-DEK AES-GCM via the existing `Engram.Crypto.Envelope.encrypt/3` / `decrypt/4` (already aliased in `notes.ex:11`), AAD-bound to the target row id via `Crypto.aad_for_row/3` (binary-table clause, `crypto.ex:56`). The worker tries the tombstone first (REST jobs unchanged, zero risk to shipped Phase 1 behavior), then the args ciphertext, then discards. We deliberately do NOT add a tombstone insert to the relocate flow: that would re-enter the delete-wins/#614/seq-feed machinery (the relocate path's "no tombstone-first dance" is load-bearing for #970) for a problem an opaque arg solves.

**Not in scope:** attachments (no CRDT create path — REST-only, Phase 1 covers them), folder renames, `genesis_resurrect`'s rename-restore leg (see Grounding Gaps), the flag flip itself, e2e additions (see e2e Consideration).

## Tech Stack

Elixir 1.17+ / Phoenix 1.8+ (Channels), Ecto + Postgres (RLS tenant scoping), Oban + `Oban.Testing`, `Engram.Crypto.Envelope` (AES-GCM), ExUnit + `Engram.Fixtures` + `EngramWeb.ChannelCase`. Paired client edits: TypeScript (plugin repo, Bun/Jest-compatible tests; frontend, Vite + vitest).

## Global Constraints

- **TDD mandatory**: write the failing test, run it, confirm the exact failure, then implement. Never modify a test to make bad code pass.
- **Sequential gauntlet before push**: `mix format` → `mix credo --strict` → `mix dialyzer` → full `mix test --warnings-as-errors` — SEQUENTIALLY, never concurrently (concurrent dialyzer starves the DB pool → fake failures).
- **No version bumps**: release-please owns `mix.exs` and the plugin manifest; do not touch either.
- **Oban job args carry ids + base64 HMACs/ciphertexts only** — never plaintext path/title/content/tags/folder/old_path/name. `test/engram/workers/no_plaintext_args_test.exs` lints worker sources for banned keys; the new keys `old_path_ciphertext`/`old_path_nonce` do not trip its boundary-anchored regex (`(?<![A-Za-z_])(?:"old_path"\s*=>|old_path:)(?![A-Za-z_])`) — keep it green, never `noqa` it.
- **Tenant scoping**: unchanged from Phase 1 — the worker's queries already run `skip_tenant_check: true` with explicit `user_id`/`vault_id` filters; nothing in this phase adds a query.
- **`client_type` is a trust-boundary input**: client-supplied at socket join. Validate shape (binary, bounded length) at the channel; it only ever feeds a string equality — never a query, never a log without category metadata.
- **Rewrite failures never fail or roll back the rename** — enqueue via `Engram.Notes.Enqueue.enqueue/2` (non-raising: logs + telemetry on failure). The crypto hard-matches in the enqueue helper follow the exact precedent of the `RebindNoteLinks` enqueues already inside `genesis_relocate_live` (`Links.basename_hmac/2` hard-matches `dek_filter_key`); the DEK was just used successfully by `decrypt_or_raise!` lines earlier.
- **Suppression triggers** (`# credo:disable`, `@dialyzer :nowarn`, skipped tests, swallowed exceptions): STOP and state the underlying problem before adding any.
- **No schema changes, no migrations.**
- **Branch**: `feat/rename-link-rewrite` (this worktree). Never a `ci/` prefix (gets NO CI).
- **One PR** for all backend+frontend changes (frontend lives in this repo); the plugin change is a separate PR in `engram-app/Engram-obsidian` (Task 6) and must merge/release AFTER the backend gate ships (the untagged default makes the skew safe in that order — and only that order).

---

### Task 1 — Origin gate: flag + predicate in `Engram.Notes`

The gate is one named module attribute plus one pure public function, so the later flip is a one-line diff and tests can pin the compromise explicitly.

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/lib/engram/notes.ex`
- Test: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/test/engram/notes_crdt_origin_gate_test.exs` (new)

**Interfaces**
- Produces: `Engram.Notes.untagged_crdt_client_type/0 :: String.t()` (the flip flag, `@doc false`) and `Engram.Notes.crdt_rename_rewrites?/1 :: String.t() | nil -> boolean()`.
- Consumed by: Task 3 (`genesis_relocate_live`) and the flag-pinning test.

**Steps**

- [ ] Write the failing test file `test/engram/notes_crdt_origin_gate_test.exs`:

```elixir
defmodule Engram.NotesCrdtOriginGateTest do
  # Pure gate logic — no DB. The gate decides whether a CRDT-origin rename
  # (relocate via genesis_crdt_note) enqueues the server-side link rewrite.
  use ExUnit.Case, async: true

  alias Engram.Notes

  test "obsidian-tagged renames NEVER enqueue (Obsidian rewrites its own links)" do
    refute Notes.crdt_rename_rewrites?("obsidian")
  end

  test "web-tagged renames enqueue exactly via the gate" do
    assert Notes.crdt_rename_rewrites?("web")
  end

  test "a PRESENT-but-unknown tag enqueues (spec safe default — not a skewed plugin)" do
    assert Notes.crdt_rename_rewrites?("mobile")
  end

  test "untagged (nil) takes the flip flag — currently plugin-origin, NO enqueue" do
    # TEMPORARY COMPROMISE PIN (#648 Phase 2): version-skewed plugins that
    # predate the client_type join tag must not double-rewrite, so untagged
    # defaults to "obsidian" until the tagged plugin release has been out one
    # release cycle. The flip (this assertion changing to "web" / assert) is a
    # ONE-LINE change to @untagged_crdt_client_type in Engram.Notes. If this
    # test fails because the flag flipped, update BOTH asserts below together.
    assert Notes.untagged_crdt_client_type() == "obsidian"
    refute Notes.crdt_rename_rewrites?(nil)
  end
end
```

- [ ] Run it: `mix test test/engram/notes_crdt_origin_gate_test.exs` — confirm failure is `UndefinedFunctionError` for `Notes.crdt_rename_rewrites?/1`.
- [ ] Implement in `lib/engram/notes.ex`, directly above `genesis_relocate_live/5` (notes.ex:877 region) so the gate and its consumer read together:

```elixir
  # ── Phase 2 (#648/#1231) — CRDT-origin rename rewrite gate ─────────────────
  #
  # TEMPORARY COMPROMISE — REMOVE BY FLIPPING TO "web" (one line, this
  # attribute only): an UNTAGGED crdt socket is treated as plugin-origin so a
  # version-skewed plugin that predates the client_type join tag never
  # double-rewrites (Obsidian rewrites its own links; the server rewriting too
  # would violate the one-rewriter invariant). Once the plugin release that
  # tags itself "obsidian" has been out for one release cycle, flip this to
  # "web" so untagged defaults to enqueue — the spec's safe default.
  # Pinned by test/engram/notes_crdt_origin_gate_test.exs. Tracked in #648.
  @untagged_crdt_client_type "obsidian"

  @doc false
  @spec untagged_crdt_client_type() :: String.t()
  def untagged_crdt_client_type, do: @untagged_crdt_client_type

  @doc """
  ONE-REWRITER INVARIANT gate for CRDT-origin renames (relocates reached via
  `genesis_crdt_note/5`): `"obsidian"` never triggers a server rewrite; any
  other PRESENT tag does; an ABSENT tag (nil) takes the
  `untagged_crdt_client_type/0` compromise default (see attribute comment).
  """
  @spec crdt_rename_rewrites?(String.t() | nil) :: boolean()
  def crdt_rename_rewrites?(client_type) do
    (client_type || @untagged_crdt_client_type) != "obsidian"
  end
```

- [ ] Run the test file again — 4 passing.
- [ ] `mix format` the touched files; commit: `feat: crdt rename rewrite origin gate (untagged=obsidian compromise)`.

---

### Task 2 — Worker: encrypted-args old-path fallback

CRDT relocates leave no tombstone (see Architecture), so `RewriteNoteLinks` gains an optional second old-path source: `old_path_ciphertext`/`old_path_nonce` args, decrypted with the user DEK, AAD-bound to `target_id`. Tombstone stays the first source — REST jobs and any in-flight Phase 1 args are untouched.

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/lib/engram/workers/rewrite_note_links.ex`
- Test: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/test/engram/workers/rewrite_note_links_test.exs` (extend)

**Interfaces**
- Consumes: `Engram.Crypto.Envelope.decrypt/4` (`{:ok, binary} | :error`), `Engram.Crypto.get_dek/1`, `Engram.Crypto.aad_for_row/3` (binary table+column clause).
- Produces: `RewriteNoteLinks.new_for/7` — `new_for(user_id, vault_id, kind, target_id, old_path_hmac_b64, old_basename_hmac_b64, opts \\ [])` with `opts[:old_path_ciphertext]` / `opts[:old_path_nonce]` (both base64 strings, present together or not at all).
- AAD contract (shared with Task 3's enqueue): `Crypto.aad_for_row("oban_rewrite_note_links", "old_path", target_id)`.

**Steps**

- [ ] Extend `test/engram/workers/rewrite_note_links_test.exs`. Add a ciphertext-args helper next to the existing `args_for/3` and three tests (the file already has `seed_source!/4`, `authoritative!/2`, `old_path_hmac_b64/2`, `use Oban.Testing`):

```elixir
  # Phase 2: CRDT relocates leave NO tombstone at the old path (move_note is
  # an in-place repoint) — the job carries the old path as user-DEK AES-GCM
  # ciphertext instead, AAD-bound to the target row id.
  defp ciphertext_args(user, vault, target, old_path) do
    {:ok, dek} = Engram.Crypto.get_dek(user)
    aad = Engram.Crypto.aad_for_row("oban_rewrite_note_links", "old_path", target.id)
    {ct, nonce} = Engram.Crypto.Envelope.encrypt(old_path, dek, aad)

    %{
      "user_id" => user.id,
      "vault_id" => vault.id,
      "target_kind" => "note",
      "target_id" => target.id,
      "old_path_hmac" => old_path_hmac_b64(user, old_path),
      "old_basename_hmac" =>
        Base.encode64(Links.basename_hmac(user, Links.basename_key(old_path))),
      "old_path_ciphertext" => Base.encode64(ct),
      "old_path_nonce" => Base.encode64(nonce)
    }
  end

  test "recovers old_path from encrypted args when NO tombstone exists (CRDT relocate)",
       %{user: user, vault: vault} do
    # Relocate via the CRDT genesis path, NOT rename_note — proves the
    # no-tombstone premise instead of assuming it.
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
    source = seed_source!(user, vault, "S.md", "see [[Old]]")
    {:ok, _moved} = Notes.genesis_crdt_note(user, vault, note.id, "Fresh.md")

    # Premise pin: the relocate left no soft-deleted row anywhere.
    tombs =
      Repo.one(
        from(n in Engram.Notes.Note,
          where: n.user_id == ^user.id and not is_nil(n.deleted_at),
          select: count(n.id)
        ),
        skip_tenant_check: true
      )

    assert tombs == 0

    assert :ok = perform_job(RewriteNoteLinks, ciphertext_args(user, vault, note, "Old.md"))
    assert authoritative!(user, source.id) =~ "[[Fresh]]"
    refute authoritative!(user, source.id) =~ "[[Old]]"
  end

  test "AAD binds the ciphertext to the target id — foreign ciphertext discards",
       %{user: user, vault: vault} do
    {:ok, a} = Notes.upsert_note(user, vault, %{"path" => "A-old.md", "content" => "a"})
    {:ok, b} = Notes.upsert_note(user, vault, %{"path" => "B.md", "content" => "b"})
    {:ok, _} = Notes.genesis_crdt_note(user, vault, a.id, "A-new.md")

    # Ciphertext minted for target A, replayed onto a job for target B.
    args =
      user
      |> ciphertext_args(vault, a, "A-old.md")
      |> Map.put("target_id", b.id)

    assert {:discard, :old_path_unrecoverable} = perform_job(RewriteNoteLinks, args)
  end

  test "garbage ciphertext args discard without raising", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "G-old.md", "content" => "g"})
    {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "G-new.md")

    args =
      user
      |> ciphertext_args(vault, note, "G-old.md")
      |> Map.put("old_path_ciphertext", Base.encode64("not a real ciphertext"))

    assert {:discard, :old_path_unrecoverable} = perform_job(RewriteNoteLinks, args)
  end
```

  (Note: `genesis_crdt_note/4` still has arity 4 here — these tests exercise the worker with hand-built args and do not depend on Task 3's enqueue. Add `alias Engram.Repo` + `import Ecto.Query, only: [from: 2]` at the top of the test module if not already present.)

- [ ] Run: `mix test test/engram/workers/rewrite_note_links_test.exs`. Confirm the first new test fails at `{:discard, :old_path_unrecoverable}` (worker ignores the ciphertext keys today); the AAD/garbage tests may vacuously pass — that is fine, they pin behavior once the fallback exists.
- [ ] Implement in `lib/engram/workers/rewrite_note_links.ex`:
  - Add `alias Engram.Crypto.Envelope` to the alias block.
  - Extend `new_for/6` → `new_for/7`:

```elixir
  @spec new_for(binary(), binary(), :note | :attachment, binary(), String.t(), String.t(), keyword()) ::
          Ecto.Changeset.t()
  def new_for(user_id, vault_id, kind, target_id, old_path_hmac_b64, old_basename_hmac_b64, opts \\ []) do
    base = %{
      "user_id" => user_id,
      "vault_id" => vault_id,
      "target_kind" => Atom.to_string(kind),
      "target_id" => target_id,
      "old_path_hmac" => old_path_hmac_b64,
      "old_basename_hmac" => old_basename_hmac_b64,
      "cursor" => @start_cursor
    }

    args =
      case Keyword.fetch(opts, :old_path_ciphertext) do
        {:ok, ct_b64} ->
          base
          |> Map.put("old_path_ciphertext", ct_b64)
          |> Map.put("old_path_nonce", Keyword.fetch!(opts, :old_path_nonce))

        :error ->
          base
      end

    new(args)
  end
```

  - In `run/1`, replace the with-clause line `{:ok, old_path} <- tombstone_old_path(user, vault, kind, old_path_hmac)` with `{:ok, old_path} <- recover_old_path(user, vault, kind, old_path_hmac, args)` and add:

```elixir
  # Old-path recovery, two sources in order:
  #   1. The REST-rename tombstone at the old path (Phase 1 — do_rename_note_inner
  #      inserts it; decrypt its path field).
  #   2. Phase 2 (CRDT relocate): genesis_relocate_live/move_note repoints the
  #      row IN PLACE — no tombstone exists — so the enqueue site rides the old
  #      path in args as user-DEK AES-GCM ciphertext, AAD-bound to target_id
  #      (T3.2: plaintext never enters oban_jobs.args; the AAD stops replaying
  #      one job's ciphertext onto another). A DEK rotation between enqueue and
  #      run makes the ciphertext undecryptable — that degrades to the same
  #      {:discard, :old_path_unrecoverable} class (rare; any later rename
  #      enqueues its own fresh job).
  defp recover_old_path(user, vault, kind, old_path_hmac, args) do
    case tombstone_old_path(user, vault, kind, old_path_hmac) do
      {:ok, path} -> {:ok, path}
      {:discard, :old_path_unrecoverable} -> args_old_path(user, args)
    end
  end

  defp args_old_path(user, %{
         "old_path_ciphertext" => ct_b64,
         "old_path_nonce" => nonce_b64,
         "target_id" => target_id
       }) do
    with {:ok, ct} <- decode_b64(ct_b64),
         {:ok, nonce} <- decode_b64(nonce_b64),
         {:ok, dek} <- Crypto.get_dek(user),
         aad = Crypto.aad_for_row("oban_rewrite_note_links", "old_path", target_id),
         {:ok, path} <- Envelope.decrypt(ct, nonce, dek, aad) do
      {:ok, path}
    else
      _ -> {:discard, :old_path_unrecoverable}
    end
  end

  defp args_old_path(_user, _args), do: {:discard, :old_path_unrecoverable}
```

  - Update the moduledoc's "The old plaintext path is recovered at run time by decrypting the rename tombstone" sentence to name both sources (tombstone for REST renames; AAD-bound args ciphertext for CRDT relocates, which tombstone nothing).
- [ ] Run the worker test file — all green, including the four pre-existing tests (`rewrites every source note and chains by cursor`, `survives multiple batches`, `per-source failure is isolated`, `missing tombstone discards without raising` — the last one now proves the arg-less discard leg still works).
- [ ] Run `mix test test/engram/workers/no_plaintext_args_test.exs` — confirm the new arg keys do not trip the lint.
- [ ] `mix format`; commit: `feat: RewriteNoteLinks recovers old_path from AAD-bound args ciphertext`.

---### Task 3 — Thread origin to `genesis_relocate_live` + gated enqueue

`genesis_crdt_note/4` grows an opts arity (`origin:`); `genesis_relocate_live/5` grows an `origin` param and enqueues the rewrite next to its existing `RebindNoteLinks` enqueues when the Task 1 gate passes. The enqueue rides inside the same tenant transaction as the relocate — Oban insert in-txn commits atomically with the rename (strictly stronger than fire-and-forget; `Enqueue.enqueue/2` is still non-raising).

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/lib/engram/notes.ex`
- Test: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/test/engram/links/rewrite_wiring_test.exs` (extend)

**Interfaces**
- Produces: `Notes.genesis_crdt_note/5` — `genesis_crdt_note(user, vault, id, path, opts \\ [])`, `opts[:origin] :: String.t() | nil` (default `nil` = untagged). All existing arity-4 callers (tests, `links_lifecycle_test.exs`) compile unchanged via the default.
- Consumes: Task 1's `crdt_rename_rewrites?/1`, Task 2's `new_for/7`, `Envelope.encrypt/3` (aliased at `notes.ex:11`), the existing private `old_path_hmac_b64!/2` (`notes.ex:4301`).

**Steps**

- [ ] Extend `test/engram/links/rewrite_wiring_test.exs` with a Phase 2 describe (module already has `use Oban.Testing`, the user/vault setup, and the `RewriteNoteLinks` alias):

```elixir
  describe "CRDT-origin gate (Phase 2, #648)" do
    setup %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
      %{note: note}
    end

    test "web-origin relocate enqueues ONE job with encrypted old-path args",
         %{user: user, vault: vault, note: note} do
      {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Fresh.md", origin: "web")

      assert [job] = all_enqueued(worker: RewriteNoteLinks)
      assert job.args["target_kind"] == "note"
      assert job.args["target_id"] == note.id
      assert {:ok, _} = Base.decode64(job.args["old_path_hmac"])
      assert {:ok, _} = Base.decode64(job.args["old_basename_hmac"])
      assert {:ok, _} = Base.decode64(job.args["old_path_ciphertext"])
      assert {:ok, _} = Base.decode64(job.args["old_path_nonce"])
      refute Map.has_key?(job.args, "old_path")
    end

    test "obsidian-origin relocate enqueues NOTHING (one-rewriter invariant)",
         %{user: user, vault: vault, note: note} do
      {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Fresh.md", origin: "obsidian")
      assert all_enqueued(worker: RewriteNoteLinks) == []
    end

    test "untagged relocate enqueues NOTHING while the compromise flag holds",
         %{user: user, vault: vault, note: note} do
      # Pinned to Notes.untagged_crdt_client_type/0 == "obsidian" (see
      # notes_crdt_origin_gate_test.exs). When the flag flips to "web", this
      # test flips to assert [_] = all_enqueued(...) in the same commit.
      {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Fresh.md")
      assert all_enqueued(worker: RewriteNoteLinks) == []
    end

    test "same-path idempotent re-genesis enqueues nothing even for web origin",
         %{user: user, vault: vault, note: note} do
      {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Old.md", origin: "web")
      assert all_enqueued(worker: RewriteNoteLinks) == []
    end
  end
```

- [ ] Run: `mix test test/engram/links/rewrite_wiring_test.exs` — the first test fails (no `old_path_ciphertext` key / no job at all).
- [ ] Implement in `lib/engram/notes.ex`:
  - `genesis_crdt_note/4` → `/5`: change the head to `def genesis_crdt_note(user, vault, id, path, opts \\ [])`, add `origin = Keyword.get(opts, :origin)` in the body, extend the `@spec` (`notes.ex:693`) with the trailing `keyword()`, and update the moduledoc's `@doc` reference from `/4` where it names itself.
  - The `:live`/`{:ok, false}` branch call (`notes.ex:735`) becomes `genesis_relocate_live(live, user, vault, sanitized_path, folder, origin)`.
  - `genesis_relocate_live/5` → `/6` (`notes.ex:877`): add trailing `origin` param. Inside the `{:ok, moved}` success branch, immediately after the second `RebindNoteLinks` enqueue (the `if new_key != old_key do` block) and before `{:ok, moved, {:announce_moved, decrypted.path}}`, add:

```elixir
                  # #648/#1231 Phase 2 — server-side link rewrite for
                  # NON-obsidian CRDT-origin renames (the primary web rename
                  # path). Obsidian-origin relocates never enqueue: the plugin
                  # rewrites its own links (exactly-one-rewriter invariant).
                  # In-txn enqueue: the job commits atomically with the
                  # relocate; Enqueue.enqueue never raises.
                  _ =
                    if crdt_rename_rewrites?(origin) do
                      enqueue_crdt_rename_rewrite(user, vault, moved.id, decrypted.path)
                    end
```

  - Add the private helper next to `genesis_relocate_live`:

```elixir
  # CRDT relocates repoint the row in place (move_note) — no old-path
  # tombstone exists for the worker to decrypt, so the old path rides the
  # job args as user-DEK AES-GCM ciphertext, AAD-bound to the renamed row's
  # id (T3.2: plaintext never enters oban_jobs.args). The {:ok, dek} match
  # follows the RebindNoteLinks-enqueue precedent above: decrypt_or_raise!
  # already proved this user's DEK usable in this very function.
  defp enqueue_crdt_rename_rewrite(user, vault, note_id, old_path) do
    {:ok, dek} = Crypto.get_dek(user)
    aad = Crypto.aad_for_row("oban_rewrite_note_links", "old_path", note_id)
    {ct, nonce} = Envelope.encrypt(old_path, dek, aad)

    Enqueue.enqueue(
      Engram.Workers.RewriteNoteLinks.new_for(
        user.id,
        vault.id,
        :note,
        note_id,
        old_path_hmac_b64!(user, old_path),
        Base.encode64(Links.basename_hmac(user, Links.basename_key(old_path))),
        old_path_ciphertext: Base.encode64(ct),
        old_path_nonce: Base.encode64(nonce)
      ),
      "rewrite_note_links"
    )
  end
```

- [ ] Run the wiring test file — all green (including the six pre-existing Phase 1 tests).
- [ ] Add the end-to-end enqueue→perform round trip to `test/engram/workers/rewrite_note_links_test.exs` (proves the enqueue's ciphertext and the Task 2 decrypt agree on AAD — the seam a unit test of either side alone can miss):

```elixir
  test "web-origin relocate job round-trips: enqueue args alone recover the old path",
       %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Rt-old.md", "content" => "# t"})
    source = seed_source!(user, vault, "RtSource.md", "see [[Rt-old]]")
    {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Rt-new.md", origin: "web")

    assert [job] = all_enqueued(worker: RewriteNoteLinks)
    assert :ok = perform_job(RewriteNoteLinks, job.args)
    assert authoritative!(user, source.id) =~ "[[Rt-new]]"
  end
```

- [ ] Run: `mix test test/engram/workers/rewrite_note_links_test.exs test/engram/links/rewrite_wiring_test.exs test/engram/links_lifecycle_test.exs` (the lifecycle file's CRDT-genesis tests call `genesis_crdt_note/4` — the opts default must keep them green untouched).
- [ ] `mix format`; commit: `feat: gate + enqueue link rewrite on CRDT relocate origin`.

---

### Task 4 — Channel: `client_type` join param → assign → genesis calls

`CrdtChannel.join/3` reads the tag from join params (where `crdt_proto` already lives), normalizes it at the trust boundary, assigns it, and both create paths pass it as `origin:`.

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/lib/engram_web/channels/crdt_channel.ex`
- Test: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/test/engram_web/channels/crdt_channel_origin_test.exs` (new)

**Interfaces**
- Consumes: join `params` (client sends `%{"crdt_proto" => 2, "client_type" => "web" | "obsidian"}`), Task 3's `genesis_crdt_note/5`.
- Produces: `socket.assigns.client_type :: String.t() | nil` (nil = untagged/invalid).

**Steps**

- [ ] Write the failing channel test `test/engram_web/channels/crdt_channel_origin_test.exs` (setup mirrors `crdt_channel_test.exs:20-49`, parameterized on join params):

```elixir
defmodule EngramWeb.CrdtChannelOriginTest do
  # Phase 2 (#648): client_type join tag → origin-gated RewriteNoteLinks
  # enqueue on the crdt_create relocate (rename) path.
  use EngramWeb.ChannelCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Crypto, Notes, Vaults}
  alias Engram.Repo
  alias Engram.Workers.RewriteNoteLinks

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    on_exit(fn -> EngramWeb.RateLimiter.reset_buckets!() end)

    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "CrdtOriginTest"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
    %{user: user, vault: vault, note: note}
  end

  defp join!(user, vault, params) do
    {:ok, _, joined} =
      subscribe_and_join(
        user_socket(user),
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        params
      )

    Sandbox.allow(Repo, self(), joined.channel_pid)
    joined
  end

  defp relocate!(socket, note) do
    ref = push(socket, "crdt_create", %{"doc_id" => note.id, "path" => "Fresh.md"})
    assert_reply ref, :ok, %{doc_id: _}
  end

  test "web-tagged join: relocate enqueues exactly one rewrite job",
       %{user: user, vault: vault, note: note} do
    socket = join!(user, vault, %{"crdt_proto" => 2, "client_type" => "web"})
    relocate!(socket, note)

    assert [job] = all_enqueued(worker: RewriteNoteLinks)
    assert job.args["target_id"] == note.id
    assert {:ok, _} = Base.decode64(job.args["old_path_ciphertext"])
  end

  test "obsidian-tagged join: relocate enqueues nothing",
       %{user: user, vault: vault, note: note} do
    socket = join!(user, vault, %{"crdt_proto" => 2, "client_type" => "obsidian"})
    relocate!(socket, note)
    assert all_enqueued(worker: RewriteNoteLinks) == []
  end

  test "untagged join (a pre-tag plugin): relocate enqueues nothing — compromise default",
       %{user: user, vault: vault, note: note} do
    socket = join!(user, vault, %{"crdt_proto" => 2})
    relocate!(socket, note)
    assert all_enqueued(worker: RewriteNoteLinks) == []
  end

  test "batch-path relocate carries the same origin",
       %{user: user, vault: vault, note: note} do
    socket = join!(user, vault, %{"crdt_proto" => 2, "client_type" => "web"})

    # An empty valid Y-frame is not required for the relocate leg to fire:
    # prepare_create hits genesis BEFORE frame decode? No — decode precedes
    # genesis, so send a real minimal sync_update frame the same way
    # crdt_channel_test.exs builds batch entries (reuse its helper if one is
    # extracted; otherwise build via Yex as that file's batch tests do).
    {:ok, doc} = Engram.Notes.CrdtBridge.doc_from_state(nil)
    frame = Yex.encode_state_as_update!(doc)

    ref =
      push(socket, "crdt_create_batch", %{
        "creates" => [
          %{"doc_id" => note.id, "path" => "Fresh.md", "b64" => Base.encode64(frame)}
        ]
      })

    assert_reply ref, :ok, %{results: [%{status: "ok"}]}
    assert [_job] = all_enqueued(worker: RewriteNoteLinks)
  end
end
```

  (Executor note on the batch test: mirror the exact frame-building the existing `crdt_channel_test.exs` `crdt_create_batch` describe uses at `test/engram_web/channels/crdt_channel_test.exs:418-480` — if its entries build `b64` differently, e.g. via a seeded `Yex.Doc` with text, copy that construction verbatim rather than the sketch above; the assertion under test is only the enqueue. If the batch relocate leg replies with a non-"ok" status for a live-id entry (batch is genesis-with-content), keep the frame construction that yields "ok" in the existing suite's idempotent-re-create test at line 467.)

- [ ] Run: `mix test test/engram_web/channels/crdt_channel_origin_test.exs` — the web-tagged test fails (no job: origin never reaches genesis).
- [ ] Implement in `lib/engram_web/channels/crdt_channel.ex`:
  - `join/3` (`crdt_channel.ex:81`) — assign before delegating:

```elixir
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
```

  - `handle_in("crdt_create", ...)` (`crdt_channel.ex:223`): `Notes.genesis_crdt_note(user, vault, note_id, path)` → `Notes.genesis_crdt_note(user, vault, note_id, path, origin: socket.assigns[:client_type])`.
  - `handle_in("crdt_create_batch", ...)`: read `client_type = socket.assigns[:client_type]` next to the existing `user`/`vault` reads, and change the phase-1 stream call `prepare_create(entry, user, vault)` → `prepare_create(entry, user, vault, client_type)`.
  - `prepare_create/3` → `/4` (both clauses, `crdt_channel.ex:520` and the malformed-entry clause below it): genesis call becomes `Notes.genesis_crdt_note(user, vault, note_id, path, origin: client_type)`; the malformed clause takes `_client_type`.
- [ ] Run the new channel test file, then the full existing channel suite: `mix test test/engram_web/channels/crdt_channel_test.exs test/engram_web/channels/crdt_channel_tracing_test.exs test/engram_web/channels/crdt_channel_origin_test.exs`. The existing files join with `%{"crdt_proto" => 2}` (untagged) — they must pass untouched, which is itself a regression proof of the compromise default.
- [ ] `mix format`; commit: `feat: crdt channel client_type join tag threads origin to genesis`.

---

### Task 5 — Web frontend: tag the join `client_type: "web"`

Frontend ships in this repo and deploys atomically with the backend, so web renames get rewrites from the first deploy — no skew window on this pair.

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/frontend/src/api/channel.ts`

**Interfaces**
- Produces: crdt topic join payload `{ crdt_proto: 2, client_type: "web" }` (consumed by Task 4's `client_type/1`).

**Steps**

- [ ] Edit `frontend/src/api/channel.ts:537`:

```ts
	// Before
	crdtChannel = socket.channel(crdtTopic, { crdt_proto: 2 });
	// After — client_type gates server-side rename link-rewrites (engram#648
	// Phase 2): "web" means the server rewrites [[wikilinks]] on our renames;
	// Obsidian tags "obsidian" and rewrites its own.
	crdtChannel = socket.channel(crdtTopic, { crdt_proto: 2, client_type: "web" });
```

- [ ] `grep -rn "crdt_proto" frontend/src frontend/tests 2>/dev/null` — if any test asserts the exact join payload, extend its expectation to include `client_type: "web"` (as of this plan's research, no frontend test pins the payload).
- [ ] Verify: `cd frontend && bun install && bun run test` (vitest) and `bun run build` (runs `tsc --noEmit`).
- [ ] Commit: `feat: web SPA tags crdt join client_type=web`.

---

### Task 6 — Plugin PR (separate repo: `engram-app/Engram-obsidian`)

A separate PR in `/home/open-claw/documents/code-projects/engram-obsidian-sync` (own branch off its `main`, e.g. `feat/crdt-join-client-type`). **No version bumps — release-please owns the manifest.** Merge order: backend PR first; this PR is safe in either order only because the backend treats untagged as obsidian — do not flip the backend flag until this release has been out one release cycle.

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram-obsidian-sync/src/channel.ts`
- Test: `/home/open-claw/documents/code-projects/engram-obsidian-sync/tests/channel-crdt.test.ts` (extend)

**Interfaces**
- Produces: crdt topic `phx_join` payload `{ crdt_proto: 2, client_type: "obsidian" }`.

**Steps**

- [ ] Write the failing test — extend the existing `describe("NoteChannel CRDT topic join")` block (`tests/channel-crdt.test.ts:67`), copying the frame-location idiom of the `"crdt topic join payload includes crdt_proto: 2"` test at line 85:

```ts
	test("crdt topic join payload tags client_type: obsidian", async () => {
		const channel = new NoteChannel("http://localhost:4000", "key", "u1", "v1");
		await channel.connect();
		simulateOpen(lastWsInstance);

		const crdtJoin = lastWsInstance.sent
			.map((s: string) => JSON.parse(s) as unknown[])
			.find((m: unknown[]) => (m[2] as string).startsWith("crdt:"));

		// The tag tells the backend Obsidian rewrites its own [[wikilinks]] on
		// rename, so the server must NOT enqueue its rewriter (engram#648
		// Phase 2, exactly-one-rewriter invariant). Removing this tag would
		// re-enter the untagged compromise path on old backends and, once the
		// backend default flips, cause DOUBLE rewrites. Do not remove.
		expect((crdtJoin![4] as Record<string, unknown>).client_type).toBe("obsidian");

		channel.disconnect();
	});
```

- [ ] Run: `bun test tests/channel-crdt.test.ts` — confirm the new test fails on `undefined`.
- [ ] Edit `src/channel.ts:887`:

```ts
			// Before
			this.send([this.crdtJoinRef, msgRef, crdtT, "phx_join", { crdt_proto: 2 }]);
			// After — client_type: Obsidian owns link-rewrites for its own renames
			// (engram#648 Phase 2 one-rewriter invariant; backend gates on this tag).
			this.send([
				this.crdtJoinRef,
				msgRef,
				crdtT,
				"phx_join",
				{ crdt_proto: 2, client_type: "obsidian" },
			]);
```

- [ ] Verify: `bun test` (full suite) and `bun run build` (tsc + esbuild). Local lints per repo practice: `./node_modules/.bin/biome ci`, `bun run lint:obsidian`, `bun run lint:css`.
- [ ] Commit in the plugin repo: `feat: tag crdt join with client_type obsidian`; open PR referencing engram#648 and the backend PR ("backend must deploy first; untagged fallback covers skew").

---

## e2e Consideration (no e2e code in this phase)

No e2e addition. Rationale: the e2e suite drives a real Obsidian instance whose plugin (until Task 6's release) joins untagged → compromise default → zero behavioral change, so every existing rename/relocate e2e continues to prove the no-rewrite path; after the plugin release, tagged `"obsidian"` reaches the identical no-enqueue branch. The enqueue side (web) is fully covered by the Task 4 channel integration tests plus the Task 3 round-trip through the real worker — the only thing an e2e would add is a browser driving the same `crdt_create` frame the channel test already pushes. If a web-rename browser e2e is ever wanted, it belongs to the `e2e-browser` suite as a follow-up, not this PR. One watch-item: `e2e/conftest` encodes a plugin-surface contract (settings shape) — this phase changes no plugin settings, so no paired e2e PR is required.

## Final Verification (before PR update)

- [ ] Sequential gauntlet from the worktree root: `mix format` → `mix credo --strict` → `mix dialyzer` → `mix test --warnings-as-errors` (full suite — `genesis_crdt_note` arity change touches lifecycle + channel suites).
- [ ] `cd frontend && bun run test && bun run build`.
- [ ] Confirm no `mix.exs` / manifest version diffs.
- [ ] PR body: state the compromise flag, its flip condition (one release cycle after the tagged plugin ships), and the one-line flip diff.

## Self-Review

- [ ] **Spec coverage**: join-time `client_type` declaration ✓ (Task 4/5/6); threaded to `genesis_relocate_live` ✓ (Task 3 — via `crdt_create`/genesis, the verified real rename path, not `crdt_msg`; documented in Architecture); enqueue only when origin ≠ obsidian ✓; absent ⇒ compromise default with flip flag ✓ (Task 1); unknown-but-present ⇒ enqueue ✓; paired plugin PR separate ✓ (Task 6); backend-first ordering + skew safety ✓; one-rewriter invariant tested from both directions ✓ (Tasks 3 & 4).
- [ ] **Placeholder scan**: grep this plan for `TODO`, `similar to`, `as appropriate`, `...` in code blocks — every code block is complete and anchored to a real file:line; the only executor-latitude note (batch-test frame construction) names the exact existing test to copy from.
- [ ] **Type consistency**: `client_type` is `String.t() | nil` end-to-end (channel normalizer → assign → `opts[:origin]` → `crdt_rename_rewrites?/1` guard-free string/nil handling); worker args stay string-keyed JSON with base64 values; `new_for/7` keeps the arity-6 default so Phase 1 call sites (`notes.ex:1889`, `attachments.ex:572`) compile untouched; `genesis_crdt_note/5` default opts keeps every existing arity-4 caller green.
- [ ] **Invariant tests in place**: tagged obsidian → NO enqueue (unit + channel); tagged web → exactly one enqueue (unit + channel + worker round-trip); untagged → NO enqueue with the flag pinned by a test that reads `Notes.untagged_crdt_client_type/0`.
- [ ] **No suppressions added**; `no_plaintext_args_test.exs` green with the new arg keys.

## Spec requirements I could not ground in real code (gaps + resolutions)

1. **"threads it through update processing"** — the spec's phrasing implies renames flow through CRDT update handling (`crdt_msg`). In the real code, renames arrive as `crdt_create` with a known live id (`crdt_channel.ex:216` / `prepare_create` at `:520`) → `genesis_crdt_note` → `genesis_relocate_live`; `crdt_msg` never relocates. **Resolution:** thread through the actual seam (join assign → genesis opts → relocate param, two hops) — this is the "minimal honest threading" the interpretation asked for, documented in Architecture.
2. **Tombstone question (the big one):** CRDT relocates do NOT create rename tombstones. `genesis_relocate_live` (`notes.ex:877`) → `move_note` (`notes.ex:1255`) is an in-place `Repo.update` (repoint + `deleted_at: nil`) with no tombstone insert; only REST's `do_rename_note_inner` (`notes.ex:~1930`) inserts the old-path tombstone the worker reads. So Phase 1's `tombstone_old_path/4` would `{:discard, :old_path_unrecoverable}` on every CRDT-origin job. **Resolution:** AAD-bound encrypted `old_path` in job args (Task 2/3), tombstone-first fallback order so REST behavior is untouched. Deliberately NOT adding a tombstone to the relocate flow — that would re-enter the #970 delete-wins / #614 seq-feed machinery the relocate path intentionally avoids.
3. **"Absent/unknown tag ⇒ enqueue" vs the compromise "untagged ⇒ plugin-origin"** — the two spec sentences conflict during the window. **Resolution:** absent (nil) takes the flip flag (currently no-enqueue); present-but-unknown enqueues immediately (it cannot be a version-skewed old plugin — those send nothing). The flip is exactly one attribute edit.
4. **`genesis_resurrect`'s rename-restore leg** (`notes.ex:~1013`, `{:announce_moved, old_path}` when a tombstoned id resurrects at a NEW path) is also rename-shaped but is a restore-from-trash edge, not the primary rename path, and sits outside the spec's named seam (`genesis_relocate_live`). **Resolution:** not gated/enqueued in this phase; flagged here so the follow-up that flips the flag can decide whether to cover it (its old path IS recoverable from the tombstone it resurrects, so covering it later needs no new plumbing).
5. **DEK rotation between enqueue and run** invalidates the args ciphertext (rotation re-encrypts rows; args ciphertext keeps the old DEK). **Resolution:** degrades to the existing `{:discard, :old_path_unrecoverable}` class — rare, self-healing on the next rename, documented in the worker comment. `RotationGate.check/1` already snoozes jobs during an in-progress rotation.
6. **Stale tombstones at a relocated-from path**: `recover_old_path` tries tombstones first, and an OLD unrelated tombstone could exist at the relocate's old path (prior delete through the same path). Harmless: `tombstone_old_path` matches by `path_hmac`, so any hit decrypts to the same plaintext path string the job wants. Noted so a reviewer doesn't flag the ordering as a correctness risk.
