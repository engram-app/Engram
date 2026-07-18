# Frontmatter Resilience + Note Diagnostics — Backend Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make note ingestion "degrade, don't detonate" — a note with unparseable frontmatter is stored as-is, its good keys still extracted, the bad key(s) preserved losslessly and reported with a structured reason, and no single note can ever 500 a batch or crash a room.

**Architecture:** Make the `Frontmatter` codec total and per-key lenient (extract good keys, collect bad keys with their raw source for verbatim re-emit). Persist a `parse_status` + `parse_reason` on the note. Wrap the batch loop in per-note rescue so any future parser raise degrades one note instead of the batch. Echo the reason in the batch response and the sync feed.

**Tech Stack:** Elixir 1.17 / Phoenix 1.8, Ecto/Postgres, Yex (Yjs), YamlElixir (parse), Ymlr (emit), Jason.

## Global Constraints

- Branch `feat/frontmatter-resilience`, already created off `origin/main` (d01f8711 = prod 0.5.665). Worktree: `engram/.worktrees/feat-frontmatter-resilience`.
- One `mix.exs` version bump, only when the PR is opened. No per-task version bumps.
- Before any push: `mix format`, `mix credo --strict`, `mix sobelow`, `mix dialyzer`, and the FULL `mix test` must pass (pre-push gates format+credo+sobelow; dialyzer + full test are additionally required).
- Migrations are the **expand** phase (additive columns, defaults). PR needs the `phase/expand` label. Never edit a shipped migration.
- No em dashes in user-facing copy (`message` strings): use periods, commas, colons.
- `Frontmatter` functions must stay **total** (never raise) — every checkpoint/REST/CRDT write projects through them.

---

## Reason contract (produced here, consumed by plugin/web plans)

```elixir
# stored in notes.parse_reason (jsonb), echoed in batch response + sync feed
%{
  "code" => "frontmatter_unparseable_key" | "frontmatter_invalid_yaml" | "note_processing_failed",
  "message" => "Frontmatter key \"date\" is not valid YAML.",   # human, no em dashes
  "detail" => %{"key" => "date", "line" => 2, "snippet" => "date:YYYY-MM-DD"}  # optional fields
}
```
`parse_status` is `"ok"` or `"degraded"`.

---

### Task 1: `encode_values/1` becomes total and per-key lenient

**Files:**
- Modify: `lib/engram/notes/frontmatter.ex` (`encode_values/1`, ~line 78-99)
- Test: `test/engram/notes/frontmatter_test.exs`

**Interfaces:**
- Produces: `Frontmatter.encode_values(map) :: {values :: %{String.t()=>String.t()}, bad_keys :: [String.t()]}` — never raises. `values` holds only JSON-encodable keys; `bad_keys` lists keys whose value (or key type) could not be JSON-encoded.

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/notes/frontmatter_test.exs
describe "encode_values/1 leniency" do
  test "keeps encodable keys and collects the unencodable ones without raising" do
    map = %{"tags" => ["a", "b"], "weird" => {:a, :tuple}}
    assert {values, bad_keys} = Frontmatter.encode_values(map)
    assert values["tags"] == ~s(["a","b"])
    refute Map.has_key?(values, "weird")
    assert bad_keys == ["weird"]
  end

  test "an exotic (charlist/tuple) KEY in a nested map is collected, not raised" do
    # mirrors the yamerl output that 500'd prod (date:YYYY-MM-DD)
    map = %{"date" => %{~c"tag:yaml.org,2002:str" => "x"}}
    assert {values, bad_keys} = Frontmatter.encode_values(map)
    assert bad_keys == ["date"]
    assert values == %{}
  end

  test "all-good map returns empty bad_keys" do
    assert {values, []} = Frontmatter.encode_values(%{"a" => 1, "b" => "s"})
    assert values == %{"a" => "1", "b" => ~s("s")}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/notes/frontmatter_test.exs -o "encode_values/1 leniency"`
Expected: FAIL — current `encode_values` returns `{:ok, map} | :error` and raises on the exotic-key case.

- [ ] **Step 3: Rewrite `encode_values/1`**

```elixir
# Encode each key's value to a JSON string. Total: a value (or exotic key inside
# a nested map) that Jason cannot encode is COLLECTED into bad_keys instead of
# raising or aborting. Returns {values, bad_keys}.
@doc false
def encode_values(map) do
  Enum.reduce(map, {%{}, []}, fn {k, v}, {values, bad} ->
    case safe_encode(deep_sort(v)) do
      {:ok, json_str} -> {Map.put(values, k, json_str), bad}
      :error -> {values, [k | bad]}
    end
  end)
  |> then(fn {values, bad} -> {values, Enum.reverse(bad)} end)
end

# Jason.encode/1 returns {:error,_} for some terms but RAISES for others
# (e.g. a charlist/tuple map KEY -> List.to_string/Protocol.UndefinedError).
# Trap both so the codec is total.
defp safe_encode(term) do
  case Jason.encode(term) do
    {:ok, s} -> {:ok, s}
    {:error, _} -> :error
  end
rescue
  _ -> :error
end
```

Note: the `rescue` here converts an unexpected library raise into the graceful `:error` path. It is NOT swallowing a bug — surfacing the unencodable key IS the feature (Task 2 records which key). The underlying "why" is reported to the user, not hidden.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/notes/frontmatter_test.exs -o "encode_values/1 leniency"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes/frontmatter.ex test/engram/notes/frontmatter_test.exs
git commit -m "fix(frontmatter): make encode_values total + per-key lenient"
```

---

### Task 2: `parse/1` returns degraded-key diagnostics; update callers

**Files:**
- Modify: `lib/engram/notes/frontmatter.ex` (`parse/1` ~line 60-76; add a raw-slice helper)
- Modify: `lib/engram/notes/okf_fields.ex` (`extract/1`, the `with` ~line 30)
- Modify: `lib/engram/notes/crdt_bridge.ex` (`ingest_plaintext/2` ~line 243, `normalize_doc/1` ~line 275)
- Test: `test/engram/notes/frontmatter_test.exs`

**Interfaces:**
- Produces: `Frontmatter.parse(block) :: {:ok, order, values, degraded} | :error` where `degraded :: [%{key: String.t(), line: pos_integer() | nil, snippet: String.t()}]`. `:error` is returned ONLY when the block is not YAML-map-shaped at all (whole-block failure). A map that parses but has some unencodable keys returns `{:ok, order_of_good_keys, values, degraded}`.
- Consumes: callers pattern-match the new 4-tuple.

- [ ] **Step 1: Write the failing test**

```elixir
test "parse/1 reports degraded keys with snippet + line, keeps good keys" do
  block = "tags:\n  - a\ndate:YYYY-MM-DD\n"
  assert {:ok, order, values, degraded} = Frontmatter.parse(block)
  assert "tags" in order
  assert values["tags"] == ~s(["a"])
  assert [%{key: "date", snippet: "date:YYYY-MM-DD", line: 3}] = degraded
  refute Map.has_key?(values, "date")
end

test "parse/1 returns :error only for non-map YAML" do
  assert :error = Frontmatter.parse("just a scalar\n")
end

test "parse/1 empty block" do
  assert {:ok, [], %{}, []} = Frontmatter.parse("")
end
```

(Adjust `line: 3` to the emitted 1-based source line of the key within the block; the helper computes it from `String.split(block, "\n")`.)

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/engram/notes/frontmatter_test.exs -o "parse/1"`
Expected: FAIL — `parse/1` currently returns a 3-tuple and `:error` on any bad key.

- [ ] **Step 3: Rewrite `parse/1` + add raw-slice helper**

```elixir
@spec parse(String.t()) ::
        {:ok, [String.t()], %{String.t() => String.t()}, [map()]} | :error
def parse(""), do: {:ok, [], %{}, []}

def parse(block) when is_binary(block) do
  case YamlElixir.read_from_string(block) do
    {:ok, map} when is_map(map) ->
      order = top_level_key_order(block, map)
      {values, bad_keys} = encode_values(map)
      degraded = Enum.map(bad_keys, &degraded_entry(&1, block))
      # Good keys keep source order; bad keys are dropped from `values`/`order`
      # but preserved via `degraded` (raw passthrough happens in emit, Task 3).
      good_order = Enum.filter(order, &Map.has_key?(values, &1))
      {:ok, good_order, values, degraded}

    _ ->
      :error
  end
end

# Best-effort source location + raw slice for a top-level key.
defp degraded_entry(key, block) do
  lines = String.split(block, "\n")
  idx = Enum.find_index(lines, fn l -> Regex.match?(~r/^#{Regex.escape(key)}\s*:/, l) end)
  {line, snippet} =
    case idx do
      nil -> {nil, key}
      i -> {i + 1, Enum.at(lines, i)}
    end
  %{key: key, line: line, snippet: snippet}
end
```

- [ ] **Step 4: Update the two callers to the 4-tuple (behavior preserved)**

`lib/engram/notes/okf_fields.ex` — the `with` clause:
```elixir
with {block, _body} when is_binary(block) <- Frontmatter.split(content),
     {:ok, _order, values, _degraded} <- Frontmatter.parse(block) do
```

`lib/engram/notes/crdt_bridge.ex` `ingest_plaintext/2`:
```elixir
{order, values, body} =
  case fm_block && Frontmatter.parse(fm_block) do
    {:ok, order, values, _degraded} -> {order, values, body}
    _ -> {[], %{}, plaintext}
  end
```

`lib/engram/notes/crdt_bridge.ex` `normalize_doc/1`:
```elixir
case Frontmatter.parse(fm_block) do
  {:ok, order, values, _degraded} ->
    # ...existing body unchanged...
  :error ->
    :ok
end
```

- [ ] **Step 5: Run the frontmatter + bridge + okf tests**

Run: `mix test test/engram/notes/frontmatter_test.exs test/engram/notes/crdt_bridge_test.exs test/engram/notes/okf_fields_test.exs`
Expected: PASS (existing bridge/okf behavior unchanged; new parse tests pass).

- [ ] **Step 6: Commit**

```bash
git add lib/engram/notes/frontmatter.ex lib/engram/notes/okf_fields.ex lib/engram/notes/crdt_bridge.ex test/engram/notes/frontmatter_test.exs
git commit -m "feat(frontmatter): parse/1 reports degraded keys; update callers"
```

---

### Task 3: Lossless raw passthrough for degraded keys (round-trip safety)

**Files:**
- Modify: `lib/engram/notes/frontmatter.ex` (`emit/2` ~line 126, `project/3`), add a raw-passthrough marker
- Modify: `lib/engram/notes/crdt_bridge.ex` (`ingest_plaintext/2` — put degraded raw into the Y.Map + order)
- Test: `test/engram/notes/frontmatter_test.exs`, `test/engram/notes/crdt_bridge_test.exs`

**Interfaces:**
- A degraded key is stored in the Y.Map `values` as a **passthrough marker** JSON string: `~s({"__engram_raw__":"<raw source line(s)>"})`. It appears in `order` at its source position. `emit/2` renders a passthrough marker verbatim (the raw text), never via Ymlr, so the exact bytes round-trip.
- Produces: `Frontmatter.raw_marker(raw) :: String.t()` and `Frontmatter.raw_from_marker(json) :: {:ok, String.t()} | :error`.

- [ ] **Step 1: Write the failing round-trip test**

```elixir
test "a note with a good key + an unencodable key round-trips byte-identical" do
  doc = Yex.Doc.new()
  original = "---\ntags:\n  - a\ndate:YYYY-MM-DD\n---\nbody text\n"
  :ok = Engram.Notes.CrdtBridge.ingest_plaintext(doc, original)
  materialized = Engram.Notes.CrdtBridge.text_of(doc)
  assert materialized == original
end

test "emit renders a raw-passthrough marker verbatim" do
  order = ["tags", "date"]
  values = %{"tags" => ~s(["a"]), "date" => Frontmatter.raw_marker("date:YYYY-MM-DD")}
  assert Frontmatter.emit(order, values) == "tags:\n- a\ndate:YYYY-MM-DD\n"
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/engram/notes/frontmatter_test.exs test/engram/notes/crdt_bridge_test.exs -o passthrough`
Expected: FAIL — no marker support yet; degraded key currently dropped (lossy).

- [ ] **Step 3: Add marker helpers + emit handling in `frontmatter.ex`**

```elixir
@raw_key "__engram_raw__"

@doc "Wrap a degraded key's raw source so emit re-renders it verbatim."
def raw_marker(raw) when is_binary(raw), do: Jason.encode!(%{@raw_key => raw})

def raw_from_marker(json) when is_binary(json) do
  case Jason.decode(json) do
    {:ok, %{@raw_key => raw}} when is_binary(raw) -> {:ok, raw}
    _ -> :error
  end
end

# in emit/2's per-key map_join, before the Ymlr path:
decoded_or_raw =
  case raw_from_marker(values[key]) do
    {:ok, raw} -> {:raw, raw}
    :error -> {:decoded, decode_value(values[key])}
  end

case decoded_or_raw do
  {:raw, raw} -> ensure_trailing_newline(raw)
  {:decoded, decoded} ->
    try do
      Ymlr.document!(%{key => decoded}, sort_maps: false)
      |> String.replace_prefix("---\n", "")
    rescue
      _ -> "#{key}: #{inspect(decoded)}\n"
    end
end
```

(Refactor the existing `map_join` body to the branch above; keep `ensure_trailing_newline`.)

- [ ] **Step 4: Store degraded raw in the Y.Map in `crdt_bridge.ex` `ingest_plaintext/2`**

```elixir
{order, values, body} =
  case fm_block && Frontmatter.parse(fm_block) do
    {:ok, good_order, good_values, degraded} ->
      # Merge degraded keys back as raw passthrough so nothing is lost on emit.
      raw_values =
        Enum.reduce(degraded, good_values, fn %{key: k, snippet: raw}, acc ->
          Map.put(acc, k, Frontmatter.raw_marker(raw))
        end)
      merged_order = merge_order(fm_block, Map.keys(raw_values))
      {merged_order, raw_values, body}

    _ ->
      {[], %{}, plaintext}
  end
```

Add `merge_order/2` (private) that re-derives full source order for all present keys via the same regex `top_level_key_order` uses (or expose `Frontmatter.key_order(block, keys)`). Prefer exposing `Frontmatter.key_order/2` and calling it here to keep ordering logic in one place.

- [ ] **Step 5: Run tests**

Run: `mix test test/engram/notes/frontmatter_test.exs test/engram/notes/crdt_bridge_test.exs`
Expected: PASS (round-trip byte-identical; emit verbatim).

- [ ] **Step 6: Commit**

```bash
git add lib/engram/notes/frontmatter.ex lib/engram/notes/crdt_bridge.ex test/engram/notes/frontmatter_test.exs test/engram/notes/crdt_bridge_test.exs
git commit -m "feat(frontmatter): lossless raw passthrough for degraded keys"
```

---

### Task 4: Persist `parse_status` + `parse_reason` (migration + schema)

**Files:**
- Create: `priv/repo/migrations/<ts>_add_parse_status_to_notes_expand.exs`
- Modify: `lib/engram/notes/note.ex` (add fields to schema + changeset cast)
- Test: `test/engram/notes/note_test.exs` (or the existing schema/changeset test)

**Interfaces:**
- Produces: `notes.parse_status text not null default 'ok'`, `notes.parse_reason jsonb`. `Note` casts `:parse_status`, `:parse_reason`.

- [ ] **Step 1: Write the migration** (expand phase, additive, safe defaults)

```elixir
defmodule Engram.Repo.Migrations.AddParseStatusToNotesExpand do
  use Ecto.Migration

  def change do
    alter table(:notes) do
      add :parse_status, :text, null: false, default: "ok"
      add :parse_reason, :map   # jsonb
    end
  end
end
```

- [ ] **Step 2: Add fields to `Note` schema + changeset**

```elixir
# in schema "notes" do ... (non-virtual, real columns)
field :parse_status, :string, default: "ok"
field :parse_reason, :map

# in the changeset cast list, add :parse_status, :parse_reason
```

- [ ] **Step 3: Run migration + schema test**

Run: `mix ecto.migrate && mix test test/engram/notes/note_test.exs`
Expected: PASS; `\d notes` shows the two columns.

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations lib/engram/notes/note.ex test/engram/notes/note_test.exs
git commit -m "feat(notes): add parse_status + parse_reason columns (expand)"
```

---

### Task 5: Stamp `parse_status`/`parse_reason` at ingest (batch + single)

**Files:**
- Modify: `lib/engram/notes.ex` — batch insert row build (`build_batch_insert_row` ~line 2099, `inject_okf_fields` call) and the single-note upsert path (`upsert_note` ~line 565-576)
- Modify: `lib/engram/notes/okf_fields.ex` — expose whether frontmatter degraded (reuse `Frontmatter.parse` degraded list)
- Test: `test/engram/notes_test.exs`

**Interfaces:**
- Consumes: `Frontmatter.parse/1` degraded list (Task 2).
- Produces: a note ingested with unparseable frontmatter has `parse_status: "degraded"` and `parse_reason` = the reason contract for the first degraded key; a clean note has `parse_status: "ok"`, `parse_reason: nil`.

- [ ] **Step 1: Add a reason builder** in `lib/engram/notes/frontmatter.ex`

```elixir
@doc "Build the stored/echoed reason from a degraded-keys list (nil when empty)."
def reason_for([]), do: nil
def reason_for([%{key: key, line: line, snippet: snippet} | _] = degraded) do
  %{
    "code" => "frontmatter_unparseable_key",
    "message" => "Frontmatter " <> key_phrase(degraded) <> " could not be parsed as YAML.",
    "detail" => %{"key" => key, "line" => line, "snippet" => snippet}
  }
end
defp key_phrase([_]), do: "key needs fixing"   # message stays generic; detail carries specifics
defp key_phrase(list), do: "#{length(list)} keys need fixing"
```

- [ ] **Step 2: Write failing ingest test**

```elixir
test "ingesting a note with unparseable frontmatter stores it degraded with a reason" do
  {:ok, note} = Notes.upsert_note(user, "T.md", %{content: "---\ndate:YYYY-MM-DD\n---\nx\n"})
  assert note.parse_status == "degraded"
  assert note.parse_reason["code"] == "frontmatter_unparseable_key"
  assert note.parse_reason["detail"]["snippet"] == "date:YYYY-MM-DD"
end

test "a clean note is parse_status ok" do
  {:ok, note} = Notes.upsert_note(user, "C.md", %{content: "---\ntags: [a]\n---\nx\n"})
  assert note.parse_status == "ok"
  assert note.parse_reason == nil
end
```

- [ ] **Step 3: Compute + set the reason on both ingest paths**

Derive degraded once from the note's frontmatter block during ingest (split -> parse), build `Frontmatter.reason_for/1`, and merge `%{parse_status: status, parse_reason: reason}` into the attrs passed to `Note.changeset` in both `build_batch_insert_row` and `upsert_note`. Prefer a single private helper `put_parse_status(attrs, content)` in `notes.ex` used by both paths (DRY).

```elixir
defp put_parse_status(attrs, content) do
  degraded =
    case Frontmatter.split(content) do
      {block, _} when is_binary(block) ->
        case Frontmatter.parse(block) do
          {:ok, _o, _v, d} -> d
          _ -> [%{key: "(frontmatter)", line: 1, snippet: String.slice(content, 0, 40)}]
        end
      _ -> []
    end

  case Frontmatter.reason_for(degraded) do
    nil -> Map.merge(attrs, %{parse_status: "ok", parse_reason: nil})
    reason -> Map.merge(attrs, %{parse_status: "degraded", parse_reason: reason})
  end
end
```

Note the whole-block `:error` case maps to `frontmatter_invalid_yaml` — extend `reason_for` to accept that sentinel, or synthesize the reason here with `code: "frontmatter_invalid_yaml"`.

- [ ] **Step 4: Run tests**

Run: `mix test test/engram/notes_test.exs -o "parse_status"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes.ex lib/engram/notes/frontmatter.ex test/engram/notes_test.exs
git commit -m "feat(notes): stamp parse_status + reason on ingest (batch + single)"
```

---

### Task 6: Raise-proof the batch loop (defense in depth)

**Files:**
- Modify: `lib/engram/notes.ex` — `process_batch_entry` (the per-entry map_reduce inside `run_batch_upsert`)
- Test: `test/engram/notes_test.exs`

**Interfaces:**
- Produces: a batch entry whose processing RAISES yields a per-note error result `{:error, note_ref, %{code: "note_processing_failed", message: ...}}` and is excluded from the transaction's committed rows; sibling entries still commit. The endpoint returns 200 with a per-note result list, never 500 on a single-note raise.

- [ ] **Step 1: Write failing test** (inject a raise via a poison note that historically 500'd)

```elixir
test "one poison note degrades itself, batch still commits the rest" do
  entries = [
    %{path: "good.md", content: "---\ntags: [a]\n---\nok\n"},
    %{path: "poison.md", content: "---\ndate:YYYY-MM-DD\n---\nx\n"}
  ]
  assert {:ok, results} = Notes.batch_upsert_notes(user, entries)
  assert Enum.any?(results, &match?({:ok, _, _}, &1))          # good.md committed
  # poison.md is committed-but-degraded (Task 5), NOT an error, since parse is now total:
  poison = Enum.find(results, fn r -> elem(r, 0) == :ok and note_path(r) == "poison.md" end)
  assert poison
end

test "a synthetic raise in one entry degrades only that entry" do
  # Use a test hook / a content value that forces a raise in processing to prove
  # the rescue isolates it. Assert the batch returns 200-shaped results and the
  # sibling commits.
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/engram/notes_test.exs -o "batch"`
Expected: FAIL on the synthetic-raise isolation test (current: raise aborts the whole transaction).

- [ ] **Step 3: Wrap per-entry processing in rescue**

In `process_batch_entry` (the fn passed to `Enum.map_reduce` inside `Repo.with_tenant`), wrap the body:

```elixir
try do
  # ...existing per-entry processing...
rescue
  e ->
    Logger.error("batch entry raised, degrading note",
      category: :sync, error: Exception.message(e), path: entry.path)
    {:error, entry.path,
     %{"code" => "note_processing_failed",
       "message" => "This note could not be processed and was skipped.",
       "detail" => %{}}}
end
```

Ensure the surrounding `map_reduce`/transaction treats an `{:error, ...}` entry as a per-note failure (collected into results), NOT a transaction rollback. If the current code uses `Repo.rollback` on `{:error, changeset}`, keep validation errors per-note (they already are) and make sure a rescued raise routes to the same per-note error accumulator, not a rollback. Verify with the sibling-commit test.

- [ ] **Step 4: Run tests**

Run: `mix test test/engram/notes_test.exs -o "batch"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes.ex test/engram/notes_test.exs
git commit -m "fix(notes): per-entry rescue so one raise can't fail a batch"
```

---

### Task 7: Echo reason in batch response + expose on note read + sync feed

**Files:**
- Modify: the batch controller/serializer for `POST /api/notes/batch` (find via `grep -rn "do_batch_upsert\|batch" lib/engram_web/controllers/`)
- Modify: the note JSON view/serializer (single note read) and the `/sync/changes` feed serializer (find via `grep -rn "note_changed\|changes\|render.*note" lib/engram_web/`)
- Test: controller tests under `test/engram_web/controllers/`

**Interfaces:**
- Produces: batch response per-note objects include `"parse_status"` and `"parse_reason"`; single note read includes them; each `/sync/changes` entry includes them. (Web + plugin plans consume these.)

- [ ] **Step 1: Write failing controller test**

```elixir
test "POST /api/notes/batch echoes parse_status + reason per note", %{conn: conn} do
  body = %{notes: [%{path: "d.md", content: "---\ndate:YYYY-MM-DD\n---\nx\n"}]}
  conn = post(conn, ~p"/api/notes/batch", body)
  [note] = json_response(conn, 200)["results"]  # adjust to real response shape
  assert note["parse_status"] == "degraded"
  assert note["parse_reason"]["detail"]["snippet"] == "date:YYYY-MM-DD"
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/engram_web/controllers/note_controller_test.exs -o "parse_status"`
Expected: FAIL — fields not serialized.

- [ ] **Step 3: Add the fields to each serializer**

Add `parse_status` + `parse_reason` to: the batch per-note result map, the single-note view map, and the `/sync/changes` entry map. Match the existing key casing/style in each serializer (read the neighboring fields first).

- [ ] **Step 4: Run controller + sync tests**

Run: `mix test test/engram_web/`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web test/engram_web
git commit -m "feat(api): expose parse_status + reason on batch, note read, sync feed"
```

---

### Task 8: Full gate + open PR

- [ ] **Step 1: Bump version once** in `mix.exs` (patch bump).
- [ ] **Step 2: Run the full gate**

```bash
mix format --check-formatted && mix credo --strict && mix sobelow --exit && mix dialyzer && mix test
```
Expected: all green.

- [ ] **Step 3: Commit + push + open PR** (labels: `phase/expand`; body references the incident + spec).

```bash
git add mix.exs && git commit -m "chore: bump version for frontmatter-resilience"
git push -u origin feat/frontmatter-resilience
gh pr create --label phase/expand --title "feat: frontmatter resilience + note parse diagnostics" --body "..."
```

---

## Self-review notes

- Spec coverage: degrade-don't-detonate (T1,T3,T5,T6), reason contract (T2,T5,T7), persistence-decision-A (T4,T5,T7), Approach-B leniency + passthrough (T1-T3), batch raise-proofing (T6), API/feed exposure (T7). Plugin + web surfaces are separate plans (consume T7's contract).
- The single-note `POST/PUT /api/notes` + MCP `write_note` 500s (audit #2) are closed by T1 (total parse) + T5 (stamps them degraded); no separate task needed.
- The CRDT room-crash on the legacy deliver path (audit #3) is closed by T1 (parse no longer raises inside `ingest_plaintext`).
- Exact response/serializer shapes in T7 must be read from the codebase at execution time (grep hints given); do not assume key casing.
