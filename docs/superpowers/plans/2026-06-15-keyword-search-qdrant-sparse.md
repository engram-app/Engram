# Hybrid Keyword Search (Qdrant Sparse + HMAC) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a privacy-preserving keyword leg to search — a per-chunk Qdrant sparse vector keyed with `HMAC(user_DEK, token)`, fused server-side with the existing dense vector for real BM25 hybrid retrieval.

**Architecture:** Each chunk Qdrant point gains a named `keyword` sparse vector (`{HMAC_u32(token) → BM25 TF weight}`) alongside its `dense` vector. The collection moves to named vectors with `modifier: "idf"` on the sparse field, so Qdrant supplies IDF at query time while we compute the TF-saturation/length-norm weight at index time (per-user `avgdl`). Hybrid search issues one `/points/query` with two prefetches fused by RRF. No plaintext tokens are stored — the sparse dims are keyed, non-dictionary-reversible fingerprints.

**Tech Stack:** Elixir/Phoenix, Ecto/Postgres, Qdrant (REST via `Req`), `:crypto` HMAC-SHA256, ExUnit + Bypass + Mox.

**Branch note:** This branch is `feat/keyword-search-qdrant` off `main`. It **supersedes PR #606** (the Postgres `tsvector` approach). The #606 modules (`KeywordIndex.Postgres`, `Notes.NoteFts`, `Search.Rrf`, the `notes_fts` migration) do **not** exist on this branch and are **not created** — there are no deletion tasks. PR #606 is closed separately.

---

## Execution watch-items (read first)

These are the two highest-blast-radius areas; review Tasks 6–10 before starting.

1. **Named-vector conversion ripples to existing tests (Tasks 6–9).** Moving the
   collection from one unnamed dense vector to named `{dense, keyword}` changes
   the upsert point shape (`vector: %{"dense" => [...]}`) and the dense search
   body (`using: "dense"`). Any *existing* `qdrant`/`indexing`/`search` test that
   asserts the old bare-list vector shape will need updating to the named-vector
   format. These edits aren't enumerated as their own steps — expect to fix a
   handful when Tasks 7/9 turn the suite red, and keep the assertions (update the
   shape, don't weaken the check). Recreate-the-collection is safe (prod is
   wipeable — "no data is sacred").

2. **One `/points/query` parser must handle two response shapes.** A single-leg
   query (`:vector`/`:keyword`) and a fused query (`:hybrid`) can come back as
   `{"result": [...]}` vs `{"result": {"points": [...]}}` (see the differing
   Bypass mocks in Tasks 7/8/10). The shared `do_search/2` parser that
   `search/3`, `sparse_search/3`, and `hybrid_search/4` all reuse must normalize
   BOTH — unwrap `result.points` when present, else take `result`. Verify against
   the live Qdrant Query API response for your version (≥1.10) and make the
   parser tolerant of both; don't assume one shape.

3. **`dim/2` takes the high 32 bits of the HMAC** (`<<u32::unsigned-32, _::binary>>`),
   not the low 32 — cryptographically equivalent (HMAC output is uniform), just
   noting the spec said "low 32" and the impl says "high 32." No action needed.

Inline "confirm the real signature" notes (EmbedNote arg key, `MCP.Tools` list
accessor, `encrypt_qdrant_payload` arity) are deliberate — match the code you
read, the test will catch a mismatch immediately.

---

## File Structure

**Created:**
- `lib/engram/keyword_index.ex` — behaviour: the swap/TEE seam. Callbacks `encode_document/4`, `encode_query/2`; `module/0` resolver.
- `lib/engram/keyword_index/tokenizer.ex` — `tokens/1`: NFKC + casefold + word split (underscore kept) + CJK bigrams. Pure.
- `lib/engram/keyword_index/bm25.ex` — `tf_weight/4`: BM25 TF saturation + length-norm (IDF is Qdrant's). Pure.
- `lib/engram/keyword_index/qdrant_sparse.ex` — adapter: `dim/2` (HMAC→u32), `encode_document/4`, `encode_query/2`. Builds `%{indices, values}`.
- `lib/engram/keyword_index/stats.ex` — `avgdl/1`: per-vault average chunk token-length from `chunks.token_count`.
- `lib/engram/workers/reindex_keyword.ex` — #605 re-normalize worker stub (recompute weights vs current `avgdl`); auto-trigger deferred.
- Tests mirroring each of the above under `test/engram/...`.

**Modified:**
- `lib/engram/notes/chunk.ex` — add `:token_count` field.
- `priv/repo/migrations/<ts>_add_token_count_to_chunks.exs` — additive (`phase/expand`).
- `lib/engram/vector/qdrant.ex` — named-vector collection (dense + keyword sparse `idf`); `upsert_points` named format; `search` adds `using: "dense"`; new `sparse_search/3` + `hybrid_search/4`.
- `lib/engram/indexing.ex` — `prepare_index` computes `avgdl` + `filter_key`; `build_prepared` tokenizes each chunk, sets `token_count`, attaches the named sparse vector.
- `lib/engram/search.ex` — `mode` dispatch (`:vector` default internal / `:keyword` / `:hybrid`); build sparse query; rerank the fused top-N.
- `lib/engram_web/controllers/search_controller.ex` — web default `mode: :hybrid`.
- `lib/engram/mcp/tools.ex` + `lib/engram/mcp/handlers.ex` — `mode` param (default hybrid).

**Not created (superseding #606):** `KeywordIndex.Postgres`, `Notes.NoteFts`, `Search.Rrf`, `notes_fts` migration.

---

## Conventions (read before starting)

- Tests: `use Engram.DataCase, async: false`. Qdrant is mocked with `Bypass`; the embedder with `Mox` (`Engram.MockEmbedder`, `import Mox`, `setup :verify_on_exit!`). Test collection name is `engram_notes`. User+DEK: `{:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()`; `vault = insert(:vault, user: user)`.
- HMAC helpers (real signatures): `Engram.Crypto.dek_filter_key(user) :: {:ok, <<_::256>>} | {:error, :no_dek}`; `Engram.Crypto.hmac_field(filter_key, value) :: <<_::256>>` (deterministic, 32 bytes).
- Run a single test: `mix test path/to/test.exs:LINE`. Full file: `mix test path/to/test.exs`.
- Every commit message ends with the trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## Task 1: Tokenizer

**Files:**
- Create: `lib/engram/keyword_index/tokenizer.ex`
- Test: `test/engram/keyword_index/tokenizer_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/keyword_index/tokenizer_test.exs
defmodule Engram.KeywordIndex.TokenizerTest do
  use ExUnit.Case, async: true

  alias Engram.KeywordIndex.Tokenizer

  test "lowercases and splits on whitespace/punctuation" do
    assert Tokenizer.tokens("Hello, World!") == ["hello", "world"]
  end

  test "keeps identifiers whole (underscore in-token)" do
    assert Tokenizer.tokens("set PADDLE_API_KEY now") == ["set", "paddle_api_key", "now"]
  end

  test "NFKC-normalizes accented text" do
    # 'é' as e + combining accent normalizes to a single codepoint, then folds case
    assert Tokenizer.tokens("Café") == ["café"]
  end

  test "emits overlapping bigrams for CJK runs" do
    assert Tokenizer.tokens("東京都") == ["東京", "京都"]
  end

  test "single CJK char yields itself" do
    assert Tokenizer.tokens("猫") == ["猫"]
  end

  test "non-binary input yields empty list" do
    assert Tokenizer.tokens(nil) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/keyword_index/tokenizer_test.exs`
Expected: FAIL — `Engram.KeywordIndex.Tokenizer.tokens/1 is undefined (module ... not available)`.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/engram/keyword_index/tokenizer.ex
defmodule Engram.KeywordIndex.Tokenizer do
  @moduledoc """
  Language-neutral exact-token tokenizer for the keyword search leg (#595).

  Pipeline: Unicode NFKC normalize → Unicode case-fold → extract word runs
  (`[\\p{L}\\p{N}_]+`, so identifiers like `paddle_api_key` stay whole) →
  for CJK runs (no word spaces) emit overlapping character bigrams.

  No stemming: exact-token recall is this leg's job; morphology/semantics are
  the vector leg's (Voyage multilingual embeddings). All plaintext-touching
  logic lives here + `KeywordIndex.QdrantSparse` — the future TEE enclave
  boundary.
  """

  @word_re ~r/[\p{L}\p{N}_]+/u

  # Hiragana/Katakana, CJK Ext-A, CJK Unified, Hangul syllables, CJK compat.
  @cjk_re ~r/[\x{3040}-\x{30FF}\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{AC00}-\x{D7AF}\x{F900}-\x{FAFF}]/u

  @spec tokens(String.t() | any()) :: [String.t()]
  def tokens(text) when is_binary(text) do
    text
    |> String.normalize(:nfkc)
    |> String.downcase()
    |> then(&Regex.scan(@word_re, &1))
    |> Enum.map(&hd/1)
    |> Enum.flat_map(&expand/1)
  end

  def tokens(_), do: []

  # Split a word into maximal CJK / non-CJK runs; CJK → bigrams, other → whole.
  defp expand(word) do
    word
    |> String.graphemes()
    |> Enum.chunk_by(&cjk?/1)
    |> Enum.flat_map(fn [g | _] = run ->
      if cjk?(g), do: bigrams(run), else: [Enum.join(run)]
    end)
  end

  defp bigrams([single]), do: [single]

  defp bigrams(chars) do
    chars
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(&Enum.join/1)
  end

  defp cjk?(grapheme), do: Regex.match?(@cjk_re, grapheme)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/keyword_index/tokenizer_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/keyword_index/tokenizer.ex test/engram/keyword_index/tokenizer_test.exs
git commit -m "feat(search): keyword tokenizer (NFKC + casefold + CJK bigrams)

Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: BM25 TF weight

**Files:**
- Create: `lib/engram/keyword_index/bm25.ex`
- Test: `test/engram/keyword_index/bm25_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/keyword_index/bm25_test.exs
defmodule Engram.KeywordIndex.Bm25Test do
  use ExUnit.Case, async: true

  alias Engram.KeywordIndex.Bm25

  test "term frequency saturates (k1) — doubling tf less than doubles weight" do
    w1 = Bm25.tf_weight(1, 100, 100.0)
    w2 = Bm25.tf_weight(2, 100, 100.0)
    assert w2 > w1
    assert w2 < 2 * w1
  end

  test "length normalization (b): a longer doc scores a term lower" do
    short = Bm25.tf_weight(1, 50, 100.0)
    long = Bm25.tf_weight(1, 200, 100.0)
    assert short > long
  end

  test "a doc at avgdl uses the neutral normalization factor" do
    # norm = 1 - b + b*(len/avgdl) = 1 when len == avgdl
    assert_in_delta Bm25.tf_weight(1, 100, 100.0), 1 * 2.2 / (1 + 1.2 * 1.0), 1.0e-9
  end

  test "k1/b are overridable" do
    assert Bm25.tf_weight(3, 100, 100.0, k1: 0.0) == 1.0
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/keyword_index/bm25_test.exs`
Expected: FAIL — `Engram.KeywordIndex.Bm25.tf_weight/3 is undefined`.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/engram/keyword_index/bm25.ex
defmodule Engram.KeywordIndex.Bm25 do
  @moduledoc """
  BM25 term-frequency component (saturation + document-length normalization).

  Qdrant supplies the IDF multiplier at query time (`modifier: "idf"`), so we
  store ONLY this TF term as the sparse vector value. Final relevance is then
  `Σ IDF(t) · tf_weight(t)` = BM25. See #595 design doc.

  Defaults: k1 = 1.2 (saturation), b = 0.75 (length normalization).
  """

  @k1 1.2
  @b 0.75

  @doc """
  BM25 TF weight for a term with frequency `tf` in a document of length
  `doc_len`, given corpus `avgdl` (average document length). `avgdl` must be
  positive.

  Options: `:k1`, `:b`.
  """
  @spec tf_weight(non_neg_integer(), non_neg_integer(), float(), keyword()) :: float()
  def tf_weight(tf, doc_len, avgdl, opts \\ [])
      when is_number(tf) and is_number(doc_len) and is_number(avgdl) and avgdl > 0 do
    k1 = Keyword.get(opts, :k1, @k1)
    b = Keyword.get(opts, :b, @b)
    norm = 1 - b + b * doc_len / avgdl
    tf * (k1 + 1) / (tf + k1 * norm)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/keyword_index/bm25_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/keyword_index/bm25.ex test/engram/keyword_index/bm25_test.exs
git commit -m "feat(search): BM25 TF weight (saturation + length-norm)

Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: KeywordIndex behaviour + QdrantSparse codec (HMAC dim, encode document/query)

**Files:**
- Create: `lib/engram/keyword_index.ex`
- Create: `lib/engram/keyword_index/qdrant_sparse.ex`
- Test: `test/engram/keyword_index/qdrant_sparse_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/keyword_index/qdrant_sparse_test.exs
defmodule Engram.KeywordIndex.QdrantSparseTest do
  use Engram.DataCase, async: true

  alias Engram.Crypto
  alias Engram.KeywordIndex.QdrantSparse

  setup do
    {:ok, user_a} = insert(:user) |> Crypto.ensure_user_dek()
    {:ok, user_b} = insert(:user) |> Crypto.ensure_user_dek()
    {:ok, key_a} = Crypto.dek_filter_key(user_a)
    {:ok, key_b} = Crypto.dek_filter_key(user_b)
    %{key_a: key_a, key_b: key_b}
  end

  test "dim is a deterministic unsigned u32", %{key_a: key} do
    d = QdrantSparse.dim(key, "paddle_api_key")
    assert d == QdrantSparse.dim(key, "paddle_api_key")
    assert is_integer(d) and d >= 0 and d <= 4_294_967_295
  end

  test "same token under two users yields different dims", %{key_a: a, key_b: b} do
    assert QdrantSparse.dim(a, "secret") != QdrantSparse.dim(b, "secret")
  end

  test "encode_document returns aligned indices/values, no plaintext", %{key_a: key} do
    %{indices: indices, values: values} =
      QdrantSparse.encode_document("alpha alpha beta", key, 3, 3.0)

    assert length(indices) == 2
    assert length(values) == 2
    assert Enum.all?(indices, &(is_integer(&1) and &1 >= 0))
    assert Enum.all?(values, &is_float/1)
    # 'alpha' (tf=2) outweighs 'beta' (tf=1)
    by_dim = Enum.zip(indices, values) |> Map.new()
    assert by_dim[QdrantSparse.dim(key, "alpha")] > by_dim[QdrantSparse.dim(key, "beta")]
  end

  test "encode_query gives unit values, deduped dims", %{key_a: key} do
    %{indices: indices, values: values} = QdrantSparse.encode_query("beta beta", key)
    assert indices == [QdrantSparse.dim(key, "beta")]
    assert values == [1.0]
  end

  test "empty text encodes to empty sparse vector", %{key_a: key} do
    assert QdrantSparse.encode_document("", key, 0, 10.0) == %{indices: [], values: []}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/keyword_index/qdrant_sparse_test.exs`
Expected: FAIL — `Engram.KeywordIndex.QdrantSparse.dim/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/engram/keyword_index.ex
defmodule Engram.KeywordIndex do
  @moduledoc """
  Behaviour for the keyword leg of hybrid search (#595): the codec that turns
  plaintext into the sparse vector representation the vector store ranks.

  This is the swap seam. The only impl is `KeywordIndex.QdrantSparse` (HMAC-keyed
  sparse vectors + Qdrant `modifier: "idf"` BM25). A future TEE migration moves
  this module + `KeywordIndex.Tokenizer` inside an enclave; call sites in
  `Engram.Indexing` and `Engram.Search` are unchanged.
  """

  @type sparse :: %{indices: [non_neg_integer()], values: [float()]}

  @doc "Encode a document chunk's plaintext into a BM25-weighted sparse vector."
  @callback encode_document(
              text :: String.t(),
              filter_key :: binary(),
              doc_len :: non_neg_integer(),
              avgdl :: float()
            ) :: sparse()

  @doc "Encode a query string into a sparse query vector (unit values)."
  @callback encode_query(query :: String.t(), filter_key :: binary()) :: sparse()

  @doc "The configured keyword-index adapter."
  @spec module() :: module()
  def module, do: Application.get_env(:engram, :keyword_index, Engram.KeywordIndex.QdrantSparse)
end
```

```elixir
# lib/engram/keyword_index/qdrant_sparse.ex
defmodule Engram.KeywordIndex.QdrantSparse do
  @moduledoc """
  HMAC-keyed sparse-vector codec for the keyword leg (#595).

  A document chunk becomes `%{indices: [u32], values: [bm25_tf_weight]}` where
  each index is `HMAC(user_DEK_filter_key, token)` folded to an unsigned u32.
  No plaintext token is ever stored — the dims are keyed, non-dictionary-
  reversible fingerprints, scoped per user (so Qdrant's IDF is per-user).

  Collisions (two tokens → same u32; ~1 expected at 100k distinct terms) sum
  their values — graceful, ranking-only degradation. We take the high 32 bits
  of the HMAC directly (NO sign-fold / abs — that halves the space; cf.
  FastEmbed issue #369).
  """
  @behaviour Engram.KeywordIndex

  alias Engram.Crypto
  alias Engram.KeywordIndex.Bm25
  alias Engram.KeywordIndex.Tokenizer

  @doc "HMAC(filter_key, token) → unsigned u32 sparse dimension index."
  @spec dim(binary(), String.t()) :: non_neg_integer()
  def dim(filter_key, token) do
    <<u32::unsigned-integer-size(32), _rest::binary>> = Crypto.hmac_field(filter_key, token)
    u32
  end

  @impl Engram.KeywordIndex
  def encode_document(text, filter_key, doc_len, avgdl) do
    text
    |> Tokenizer.tokens()
    |> Enum.frequencies()
    |> Enum.reduce(%{}, fn {token, tf}, acc ->
      d = dim(filter_key, token)
      w = Bm25.tf_weight(tf, doc_len, avgdl)
      # On a u32 collision, sum the colliding terms' weights.
      Map.update(acc, d, w, &(&1 + w))
    end)
    |> to_sparse()
  end

  @impl Engram.KeywordIndex
  def encode_query(query, filter_key) do
    query
    |> Tokenizer.tokens()
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn token, acc -> Map.put(acc, dim(filter_key, token), 1.0) end)
    |> to_sparse()
  end

  defp to_sparse(by_dim) do
    {indices, values} = by_dim |> Map.to_list() |> Enum.unzip()
    %{indices: indices, values: values}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/keyword_index/qdrant_sparse_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/keyword_index.ex lib/engram/keyword_index/qdrant_sparse.ex test/engram/keyword_index/qdrant_sparse_test.exs
git commit -m "feat(search): HMAC-keyed sparse codec (KeywordIndex.QdrantSparse)

Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `chunks.token_count` column + Chunk field

**Files:**
- Create: `priv/repo/migrations/20260615120000_add_token_count_to_chunks.exs`
- Modify: `lib/engram/notes/chunk.ex`
- Test: `test/engram/notes/chunk_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/notes/chunk_test.exs
defmodule Engram.Notes.ChunkTest do
  use Engram.DataCase, async: true

  alias Engram.Notes.Chunk

  test "changeset accepts token_count" do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)

    cs =
      Chunk.changeset(%Chunk{}, %{
        position: 0,
        char_start: 0,
        char_end: 10,
        token_count: 7,
        qdrant_point_id: Ecto.UUID.generate(),
        note_id: note.id,
        user_id: user.id,
        vault_id: vault.id
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :token_count) == 7
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/notes/chunk_test.exs`
Expected: FAIL — `token_count` is not a known field / cast drops it.

- [ ] **Step 3: Write the migration + schema field**

```elixir
# priv/repo/migrations/20260615120000_add_token_count_to_chunks.exs
defmodule Engram.Repo.Migrations.AddTokenCountToChunks do
  use Ecto.Migration

  # phase/expand — additive nullable column; no backfill (pre-launch, wipeable).
  def change do
    alter table(:chunks) do
      add :token_count, :integer
    end
  end
end
```

```elixir
# lib/engram/notes/chunk.ex — add the field and cast it
# In `schema "chunks" do` add after :char_end:
    field :token_count, :integer
# In `cast(attrs, [...])` add :token_count to the list (NOT validate_required —
# legacy rows may be nil until re-indexed).
```

Apply the cast change (full updated `cast`/`schema` snippet):

```elixir
  schema "chunks" do
    field :position, :integer
    field :heading_path, :string
    field :char_start, :integer
    field :char_end, :integer
    field :token_count, :integer
    field :qdrant_point_id, Ecto.UUID

    belongs_to :note, Engram.Notes.Note
    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :position,
      :heading_path,
      :char_start,
      :char_end,
      :token_count,
      :qdrant_point_id,
      :note_id,
      :user_id,
      :vault_id
    ])
    |> validate_required([
      :position,
      :char_start,
      :char_end,
      :qdrant_point_id,
      :note_id,
      :user_id,
      :vault_id
    ])
    |> unique_constraint([:note_id, :position])
  end
```

- [ ] **Step 4: Migrate + run test to verify it passes**

Run: `mix ecto.migrate && mix test test/engram/notes/chunk_test.exs`
Expected: migration applies; test PASSES.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/20260615120000_add_token_count_to_chunks.exs lib/engram/notes/chunk.ex test/engram/notes/chunk_test.exs
git commit -m "feat(search): chunks.token_count for per-vault avgdl

phase/expand additive column. Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Per-vault `avgdl` stat

**Files:**
- Create: `lib/engram/keyword_index/stats.ex`
- Test: `test/engram/keyword_index/stats_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/keyword_index/stats_test.exs
defmodule Engram.KeywordIndex.StatsTest do
  use Engram.DataCase, async: true

  alias Engram.KeywordIndex.Stats
  alias Engram.Notes.Chunk
  alias Engram.Repo

  setup do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)
    %{user: user, vault: vault, note: note}
  end

  test "returns the default when the vault has no indexed chunks", %{vault: vault} do
    assert Stats.avgdl(vault.id) == 256.0
  end

  test "averages token_count across the vault's chunks", %{user: u, vault: v, note: n} do
    for {pos, tc} <- [{0, 10}, {1, 20}, {2, 30}] do
      Repo.insert!(%Chunk{
        position: pos,
        char_start: 0,
        char_end: 1,
        token_count: tc,
        qdrant_point_id: Ecto.UUID.generate(),
        note_id: n.id,
        user_id: u.id,
        vault_id: v.id
      })
    end

    assert Stats.avgdl(v.id) == 20.0
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/keyword_index/stats_test.exs`
Expected: FAIL — `Engram.KeywordIndex.Stats.avgdl/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/engram/keyword_index/stats.ex
defmodule Engram.KeywordIndex.Stats do
  @moduledoc """
  Per-vault `avgdl` (average chunk token length) for BM25 length normalization
  (#595). Computed from `chunks.token_count` — always reflects current vault
  state, no counter bookkeeping. Used at index time; the #605 re-normalize
  worker recomputes weights when a vault's avgdl drifts.

  Falls back to `@default_avgdl` for an empty/new vault (matches the FastEmbed
  BM25 default). BM25 is a soft normalizer, so this bootstrap value barely
  moves rankings on small vaults.
  """

  import Ecto.Query

  alias Engram.Notes.Chunk
  alias Engram.Repo

  @default_avgdl 256.0

  @spec avgdl(Ecto.UUID.t()) :: float()
  def avgdl(vault_id) do
    Chunk
    |> where([c], c.vault_id == ^vault_id and not is_nil(c.token_count))
    |> select([c], avg(c.token_count))
    |> Repo.one(skip_tenant_check: true)
    |> case do
      nil -> @default_avgdl
      %Decimal{} = d -> Decimal.to_float(d)
      n when is_float(n) -> n
      n when is_integer(n) -> n * 1.0
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/keyword_index/stats_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/keyword_index/stats.ex test/engram/keyword_index/stats_test.exs
git commit -m "feat(search): per-vault avgdl stat from chunks.token_count

Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Qdrant — named-vector collection (dense + keyword sparse `idf`)

**Files:**
- Modify: `lib/engram/vector/qdrant.ex` (`ensure_collection/2`)
- Test: `test/engram/vector/qdrant_collection_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/vector/qdrant_collection_test.exs
defmodule Engram.Vector.QdrantCollectionTest do
  use ExUnit.Case, async: false

  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)
    %{bypass: bypass}
  end

  test "creates a collection with named dense + keyword sparse(idf)", %{bypass: bypass} do
    Bypass.expect_once(bypass, "PUT", "/collections/c1", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["vectors"]["dense"]["size"] == 1024
      assert json["vectors"]["dense"]["distance"] == "Cosine"
      assert json["sparse_vectors"]["keyword"]["modifier"] == "idf"
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/vector/qdrant_collection_test.exs`
Expected: FAIL — body has `vectors: %{size: ...}` (unnamed), no `sparse_vectors`.

- [ ] **Step 3: Update `ensure_collection/2`**

```elixir
# lib/engram/vector/qdrant.ex — replace ensure_collection/2 body
  def ensure_collection(col \\ nil, dims) do
    col = col || collection()

    dense = %{size: dims, distance: "Cosine"}

    body =
      %{
        vectors: %{"dense" => dense},
        sparse_vectors: %{"keyword" => %{modifier: "idf"}}
      }
      |> then(fn b ->
        if binary_quantization_enabled?() do
          Map.put(b, :quantization_config, %{binary: %{always_ram: true}})
        else
          b
        end
      end)

    opts = [json: body] ++ req_opts()

    instrument(:ensure_collection, fn ->
      case Req.put("#{base_url()}/collections/#{col}", opts) do
        {:ok, %{status: status}} when status in [200, 201, 409] -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/vector/qdrant_collection_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/vector/qdrant.ex test/engram/vector/qdrant_collection_test.exs
git commit -m "feat(search): named-vector Qdrant collection (dense + keyword sparse idf)

Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Qdrant — named-vector upsert + `using: \"dense\"` search

**Files:**
- Modify: `lib/engram/vector/qdrant.ex` (`upsert_points/2`, `do_search/2` request body)
- Test: `test/engram/vector/qdrant_named_vector_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/vector/qdrant_named_vector_test.exs
defmodule Engram.Vector.QdrantNamedVectorTest do
  use ExUnit.Case, async: false

  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)
    %{bypass: bypass}
  end

  test "upsert sends named dense + keyword vectors verbatim", %{bypass: bypass} do
    Bypass.expect_once(bypass, "PUT", "/collections/c1/points", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [pt] = Jason.decode!(body)["points"]
      assert pt["vector"]["dense"] == [0.1, 0.2]
      assert pt["vector"]["keyword"]["indices"] == [7]
      assert pt["vector"]["keyword"]["values"] == [1.5]
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    point = %{
      id: "p1",
      vector: %{"dense" => [0.1, 0.2], "keyword" => %{indices: [7], values: [1.5]}},
      payload: %{"user_id" => "u1"}
    }

    assert :ok = Qdrant.upsert_points("c1", [point])
  end

  test "search targets the dense named vector", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/collections/c1/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["using"] == "dense"
      Plug.Conn.send_resp(conn, 200, ~s({"result":[]}))
    end)

    assert {:ok, []} = Qdrant.search("c1", [0.1, 0.2], user_id: "u1", limit: 5)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/vector/qdrant_named_vector_test.exs`
Expected: FAIL — `upsert_points` strips the named-vector map shape / `do_search` body has no `using`.

- [ ] **Step 3: Update `upsert_points/2` and the search body**

```elixir
# lib/engram/vector/qdrant.ex — upsert_points/2 already passes p.vector through;
# the serialized map keeps whatever shape the caller provides. Confirm it is:
  def upsert_points(col \\ nil, points) do
    col = col || collection()

    serialized = Enum.map(points, fn p -> %{id: p.id, vector: p.vector, payload: p.payload} end)
    opts = [json: %{points: serialized}] ++ req_opts()

    instrument(:upsert, fn ->
      case Req.put("#{base_url()}/collections/#{col}/points", opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end
```

```elixir
# lib/engram/vector/qdrant.ex — in search/3, add `using: "dense"` to `base`:
    base = %{
      query: vector,
      using: "dense",
      filter: %{must: must},
      limit: limit,
      with_payload: true
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/engram/vector/qdrant_named_vector_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/vector/qdrant.ex test/engram/vector/qdrant_named_vector_test.exs
git commit -m "feat(search): named-vector upsert + dense-vector search body

Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Qdrant — `sparse_search/3` and `hybrid_search/4`

**Files:**
- Modify: `lib/engram/vector/qdrant.ex` (add two functions; reuse `do_search/2` parser)
- Test: `test/engram/vector/qdrant_hybrid_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/vector/qdrant_hybrid_test.exs
defmodule Engram.Vector.QdrantHybridTest do
  use ExUnit.Case, async: false

  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)
    %{bypass: bypass}
  end

  test "hybrid issues two prefetches with tenant filter + rrf fusion", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/collections/c1/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      [dense_pf, kw_pf] = json["prefetch"]
      assert dense_pf["using"] == "dense"
      assert kw_pf["using"] == "keyword"
      assert kw_pf["query"]["indices"] == [7]
      assert json["query"]["fusion"] == "rrf"
      # tenant filter present on both legs
      assert dense_pf["filter"]["must"] |> Enum.any?(&(&1["key"] == "user_id"))
      assert kw_pf["filter"]["must"] |> Enum.any?(&(&1["key"] == "user_id"))
      Plug.Conn.send_resp(conn, 200, ~s({"result":{"points":[]}}))
    end)

    sparse = %{indices: [7], values: [1.0]}
    assert {:ok, []} = Qdrant.hybrid_search("c1", [0.1], sparse, user_id: "u1", vault_id: "v1", limit: 5)
  end

  test "keyword-only search targets the sparse vector", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/collections/c1/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["using"] == "keyword"
      assert json["query"]["indices"] == [7]
      Plug.Conn.send_resp(conn, 200, ~s({"result":[]}))
    end)

    assert {:ok, []} = Qdrant.sparse_search("c1", %{indices: [7], values: [1.0]}, user_id: "u1", limit: 5)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/vector/qdrant_hybrid_test.exs`
Expected: FAIL — `Qdrant.hybrid_search/4` / `sparse_search/3` undefined.

- [ ] **Step 3: Add the functions**

```elixir
# lib/engram/vector/qdrant.ex — add near search/3. Reuses the private
# `tenant_filter/1` helper (extract from search/3's `must` building) and the
# existing `do_search/2` parser.

  # Extracted from search/3 so all three query shapes share tenant filtering.
  defp tenant_filter(search_opts) do
    user_id = Keyword.fetch!(search_opts, :user_id)
    vault_id = Keyword.get(search_opts, :vault_id)
    tags_hmac = Keyword.get(search_opts, :tags_hmac)
    folder_hmac = Keyword.get(search_opts, :folder_hmac)

    must = [%{key: "user_id", match: %{value: user_id}}]
    must = if vault_id, do: must ++ [%{key: "vault_id", match: %{value: vault_id}}], else: must
    must = if tags_hmac, do: [%{key: "tags_hmac", match: %{any: tags_hmac}} | must], else: must
    must = if folder_hmac, do: [%{key: "folder_hmac", match: %{value: folder_hmac}} | must], else: must
    %{must: must}
  end

  @doc """
  Keyword-only search against the sparse `keyword` vector. `sparse` is
  `%{indices: [u32], values: [float]}`. Same options as `search/3`.
  """
  def sparse_search(col \\ nil, sparse, search_opts) do
    col = col || collection()
    limit = Keyword.get(search_opts, :limit, 5)

    body = %{
      query: %{indices: sparse.indices, values: sparse.values},
      using: "keyword",
      filter: tenant_filter(search_opts),
      limit: limit,
      with_payload: true
    }

    instrument(:sparse_search, fn -> do_search(col, [json: body] ++ req_opts()) end)
  end

  @doc """
  Hybrid search: dense + keyword prefetches fused server-side by RRF in one
  request. `sparse` is `%{indices, values}`. Tenant filter is applied to BOTH
  legs (load-bearing — the sparse inverted index is global).
  """
  def hybrid_search(col \\ nil, dense, sparse, search_opts) do
    col = col || collection()
    limit = Keyword.get(search_opts, :limit, 5)
    filter = tenant_filter(search_opts)

    body = %{
      prefetch: [
        %{query: dense, using: "dense", filter: filter, limit: limit},
        %{
          query: %{indices: sparse.indices, values: sparse.values},
          using: "keyword",
          filter: filter,
          limit: limit
        }
      ],
      query: %{fusion: "rrf"},
      limit: limit,
      with_payload: true
    }

    instrument(:hybrid_search, fn -> do_search(col, [json: body] ++ req_opts()) end)
  end
```

Also refactor `search/3` to use `tenant_filter/1` instead of its inline `must`
(replace the `must = ...` block and `filter: %{must: must}` with `filter:
tenant_filter(search_opts)`), keeping the `params` quantization branch.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/engram/vector/qdrant_hybrid_test.exs test/engram/search_test.exs`
Expected: PASS (the refactor keeps `search/3` behavior; `search_test` still green).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/vector/qdrant.ex test/engram/vector/qdrant_hybrid_test.exs
git commit -m "feat(search): Qdrant sparse_search + hybrid_search (RRF fusion)

Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Indexing — attach the keyword sparse vector per chunk

**Files:**
- Modify: `lib/engram/indexing.ex` (`prepare_index/2`, `build_prepared/4` → `build_prepared/6`)
- Test: `test/engram/indexing_keyword_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/indexing_keyword_test.exs
defmodule Engram.IndexingKeywordTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.KeywordIndex.QdrantSparse

  setup :verify_on_exit!

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  test "each qdrant point carries a named dense + keyword sparse vector", %{user: user, vault: vault} do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn texts, _opts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    note = insert(:note, user: user, vault: vault, content: "alpha beta gamma", path: "n.md")

    {:ok, prepared} = Indexing.prepare_index(note, vault)
    [point | _] = prepared.qdrant_points

    assert %{"dense" => dense, "keyword" => %{indices: indices, values: values}} = point.vector
    assert is_list(dense)
    assert length(indices) == length(values)
    assert length(indices) > 0

    # Dims are the user-keyed HMACs of the tokens, never the plaintext.
    {:ok, key} = Crypto.dek_filter_key(user)
    assert QdrantSparse.dim(key, "alpha") in indices
    refute Enum.any?(indices, &(&1 == "alpha"))

    # The chunk row records its token count.
    assert hd(prepared.chunk_rows).token_count == 3
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/indexing_keyword_test.exs`
Expected: FAIL — `point.vector` is a bare list (no `"dense"`/`"keyword"` keys); `chunk_rows` has no `token_count`.

- [ ] **Step 3: Update `prepare_index/2` and `build_prepared`**

```elixir
# lib/engram/indexing.ex
# (a) add aliases at top:
  alias Engram.KeywordIndex
  alias Engram.KeywordIndex.Stats

# (b) prepare_index/2 — compute filter_key + avgdl, thread them through:
  def prepare_index(note, %Engram.Vaults.Vault{} = vault) do
    chunks = Markdown.parse(note.content || "", note.path)

    if chunks == [] do
      {:ok, :no_chunks}
    else
      context_texts = Enum.map(chunks, & &1.context_text)
      dims = Application.get_env(:engram, :embed_dims, @default_dims)
      user = Engram.Accounts.get_user!(note.user_id)

      with :ok <- Qdrant.ensure_collection(collection(), dims),
           {:ok, filter_key} <- Engram.Crypto.dek_filter_key(user),
           {:ok, vectors} <- embed_for_indexing(context_texts) do
        avgdl = Stats.avgdl(note.vault_id)
        build_prepared(note, user, chunks, vectors, filter_key, avgdl)
      end
    end
  end

# (c) build_prepared/6 — tokenize each chunk, set token_count, attach sparse.
#     (Replaces the old build_prepared/4. It already fetched the user; now the
#     user + filter_key + avgdl are passed in.)
  defp build_prepared(note, user, chunks, vectors, filter_key, avgdl) do
    now = DateTime.utc_now(:second)

    prepared =
      Enum.zip(chunks, vectors)
      |> Enum.reduce_while({:ok, []}, fn {chunk, vector}, {:ok, acc} ->
        point_id = Ecto.UUID.generate()
        doc_len = chunk.text |> Engram.KeywordIndex.Tokenizer.tokens() |> length()
        sparse = KeywordIndex.module().encode_document(chunk.text, filter_key, doc_len, avgdl)

        base_payload = %{
          user_id: to_string(note.user_id),
          vault_id: to_string(note.vault_id),
          title: note.title,
          heading_path: chunk.heading_path,
          text: chunk.text,
          chunk_index: chunk.position,
          path_hmac: encode_hmac(note.path_hmac),
          folder_hmac: encode_hmac(note.folder_hmac),
          tags_hmac: Enum.map(note.tags_hmac || [], &Base.encode64/1)
        }

        case Engram.Crypto.encrypt_qdrant_payload(base_payload, user, collection(), point_id) do
          {:ok, payload} ->
            row = %{
              note_id: note.id,
              user_id: note.user_id,
              vault_id: note.vault_id,
              position: chunk.position,
              heading_path: chunk.heading_path,
              char_start: chunk.char_start,
              char_end: chunk.char_end,
              token_count: doc_len,
              qdrant_point_id: point_id,
              created_at: now
            }

            point = %{
              id: point_id,
              vector: %{"dense" => vector, "keyword" => sparse},
              payload: payload
            }

            {:cont, {:ok, [{row, point} | acc]}}

          {:error, reason} = err ->
            :telemetry.execute(
              [:engram, :indexing, :encrypt_failed],
              %{count: 1},
              %{user_id: note.user_id, vault_id: note.vault_id, note_id: note.id, reason: inspect(reason)}
            )

            {:halt, err}
        end
      end)

    with {:ok, prepared_pairs} <- prepared do
      {chunk_rows, qdrant_points} = prepared_pairs |> Enum.reverse() |> Enum.unzip()
      {:ok, %{note: note, chunk_rows: chunk_rows, qdrant_points: qdrant_points}}
    end
  end
```

Note: the old `build_prepared/4` took `_vault` and looked up the user internally;
the new `/6` receives `user` from `prepare_index/2`. Remove the now-unused old
clause. The DEK is mandatory for indexing (every payload is already encrypted),
so `dek_filter_key/1` returning `{:error, :no_dek}` short-circuits prepare_index
exactly like an encryption failure would — no behavior regression.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/engram/indexing_keyword_test.exs test/engram/indexing_test.exs`
Expected: PASS (new test + existing indexing tests green with the named-vector point shape).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/indexing.ex test/engram/indexing_keyword_test.exs
git commit -m "feat(search): build+attach keyword sparse vector per chunk

Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Search read path — mode dispatch + hybrid + rerank-on-fused

**Files:**
- Modify: `lib/engram/search.ex`
- Test: `test/engram/search_hybrid_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/search_hybrid_test.exs
defmodule Engram.SearchHybridTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Search

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)
    {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)
    %{bypass: bypass, user: user, vault: vault}
  end

  test "mode: :hybrid sends a fused dense+keyword query and returns results",
       %{bypass: bypass, user: user, vault: vault} do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn ["paddle_api_key"], _opts -> {:ok, [[0.1, 0.2, 0.3]]} end)

    {:ok, enc} =
      Engram.Crypto.encrypt_qdrant_payload(
        %{text: "PADDLE_API_KEY rotation", title: "Ops", heading_path: "Ops"},
        user,
        "engram_notes",
        "uuid-1"
      )

    fused = %{
      "result" => %{
        "points" => [
          %{
            "id" => "uuid-1",
            "score" => 0.0163,
            "payload" =>
              Map.merge(
                %{
                  "text" => enc.text,
                  "title" => enc.title,
                  "heading_path" => enc.heading_path,
                  "text_nonce" => enc.text_nonce,
                  "title_nonce" => enc.title_nonce,
                  "heading_path_nonce" => enc.heading_path_nonce,
                  "aad_version" => enc.aad_version
                },
                %{"user_id" => to_string(user.id), "vault_id" => to_string(vault.id)}
              )
          }
        ]
      }
    }

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["query"]["fusion"] == "rrf"
      assert length(json["prefetch"]) == 2

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(fused))
    end)

    assert {:ok, [hit]} = Search.search(user, vault, "paddle_api_key", mode: :hybrid)
    assert hit.text == "PADDLE_API_KEY rotation"
    assert_in_delta hit.score, 0.0163, 1.0e-6
  end

  test "internal default mode stays :vector (single-leg query)",
       %{bypass: bypass, user: user, vault: vault} do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn ["x"], _opts -> {:ok, [[0.1, 0.2, 0.3]]} end)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["using"] == "dense"
      refute Map.has_key?(json, "prefetch")
      Plug.Conn.send_resp(conn, 200, ~s({"result":[]}))
    end)

    assert {:ok, []} = Search.search(user, vault, "x")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/search_hybrid_test.exs`
Expected: FAIL — `Search.search/4` ignores `:mode`; never issues a `prefetch`/`fusion` body.

- [ ] **Step 3: Update `Engram.Search`**

```elixir
# lib/engram/search.ex
# (a) add aliases:
  alias Engram.KeywordIndex
  alias Engram.KeywordIndex.QdrantSparse

# (b) replace do_search/4 with a mode-dispatching version. The vector leg keeps
#     the existing fetch/decrypt/rerank/rehydrate flow; hybrid + keyword build
#     the sparse query and run the corresponding Qdrant call, then share the
#     SAME decrypt → rerank(fused top-N) → rehydrate tail.

  defp do_search(user, vault, query, opts) do
    mode = Keyword.get(opts, :mode, :vector)
    limit = Keyword.get(opts, :limit, 5)
    tags = Keyword.get(opts, :tags)
    folder = Keyword.get(opts, :folder)

    rerank_for_user? = reranker_active_for?(user)
    fetch_limit = if rerank_for_user?, do: max(limit * 4, @min_candidates), else: limit

    case translate_phase_b_filters(user, folder, tags) do
      {:ok, phase_b_kw} ->
        search_opts =
          [user_id: to_string(user.id), limit: fetch_limit]
          |> then(&if(vault, do: Keyword.put(&1, :vault_id, to_string(vault.id)), else: &1))
          |> Keyword.merge(phase_b_kw)

        with {:ok, candidates} <- run_legs(mode, user, query, search_opts),
             vaults_by_id = load_candidate_vaults(user, vault, candidates),
             {:ok, decrypted} <-
               Engram.Crypto.decrypt_qdrant_candidates(candidates, user, vaults_by_id, collection()) do
          rerank_module = if rerank_for_user?, do: reranker(), else: Engram.Rerankers.None

          with {:ok, ranked} <- rerank_module.rerank(query, decrypted, limit) do
            {:ok, rehydrate_display_fields(ranked, user)}
          end
        end

      :no_dek_with_filter ->
        {:ok, []}
    end
  end

  # Vector leg: embed query → dense Qdrant search (existing behavior).
  defp run_legs(:vector, _user, query, search_opts) do
    with {:ok, [vector]} <- embed_for_search(query) do
      Qdrant.search(collection(), vector, search_opts)
    end
  end

  # Keyword leg: HMAC the query tokens → sparse Qdrant search. Cross-vault
  # keyword is deferred (single-vault for v1) — without a vault the keyword
  # leg returns empty and hybrid degrades to vector-only.
  defp run_legs(:keyword, user, query, search_opts) do
    case sparse_query(user, query) do
      {:ok, sparse} -> Qdrant.sparse_search(collection(), sparse, search_opts)
      :no_vault -> {:ok, []}
    end
  end

  # Hybrid: dense + sparse fused server-side. A no-DEK / cross-vault keyword
  # falls back to the vector leg rather than failing.
  defp run_legs(:hybrid, user, query, search_opts) do
    with {:ok, [vector]} <- embed_for_search(query) do
      case sparse_query(user, query) do
        {:ok, sparse} -> Qdrant.hybrid_search(collection(), vector, sparse, search_opts)
        :no_vault -> Qdrant.search(collection(), vector, search_opts)
      end
    end
  end

  # Build the sparse query vector. Requires a single-vault scope (Phase-B
  # filters already guaranteed a DEK upstream when set; here we derive it).
  defp sparse_query(user, query) do
    case Engram.Crypto.dek_filter_key(user) do
      {:ok, filter_key} -> {:ok, KeywordIndex.module().encode_query(query, filter_key)}
      {:error, :no_dek} -> :no_vault
    end
  end
```

Keep `QdrantSparse` alias even if only referenced via `KeywordIndex.module/0`
(the default resolves to it) — or drop the unused alias to satisfy Credo; the
module call is `KeywordIndex.module().encode_query/2`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/engram/search_hybrid_test.exs test/engram/search_test.exs`
Expected: PASS — new hybrid + default-vector tests green; existing `search_test` (default `:vector`) unchanged.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/search.ex test/engram/search_hybrid_test.exs
git commit -m "feat(search): hybrid/keyword/vector mode dispatch + rerank fused top-N

Internal default stays :vector (MCP + existing callers unchanged).
Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Web controller defaults to hybrid

**Files:**
- Modify: `lib/engram_web/controllers/search_controller.ex`
- Test: `test/engram_web/controllers/search_controller_test.exs` (add a case)

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram_web/controllers/search_controller_test.exs — add inside the
# existing describe block (assumes the file's existing auth/setup helpers).
  test "web search requests hybrid mode", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
      {:ok, body, c} = Plug.Conn.read_body(c)
      assert Jason.decode!(body)["query"]["fusion"] == "rrf"
      Plug.Conn.send_resp(c, 200, ~s({"result":{"points":[]}}))
    end)

    Engram.MockEmbedder
    |> Mox.expect(:embed_texts, fn ["hi"], _ -> {:ok, [[0.1, 0.2, 0.3]]} end)

    conn = get(conn, ~p"/api/search", %{"query" => "hi"})
    assert json_response(conn, 200)["results"] == []
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram_web/controllers/search_controller_test.exs`
Expected: FAIL — controller sends no `mode`, so `Search` defaults to `:vector` (single-leg body, no `fusion`).

- [ ] **Step 3: Add `mode: :hybrid` in the controller**

```elixir
# lib/engram_web/controllers/search_controller.ex — in search/2, add :hybrid to opts:
    opts =
      [limit: chunk_limit, cross_vault: cross_vault, mode: :hybrid]
      |> then(&if(tags, do: Keyword.put(&1, :tags, tags), else: &1))
      |> then(&if(folder, do: Keyword.put(&1, :folder, folder), else: &1))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram_web/controllers/search_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/controllers/search_controller.ex test/engram_web/controllers/search_controller_test.exs
git commit -m "feat(search): web search defaults to hybrid mode

Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: MCP `mode` param

**Files:**
- Modify: `lib/engram/mcp/tools.ex` (`search_notes` inputSchema)
- Modify: `lib/engram/mcp/handlers.ex` (map `args["mode"]` → opts)
- Test: `test/engram/mcp/handlers_search_mode_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/mcp/handlers_search_mode_test.exs
defmodule Engram.MCP.HandlersSearchModeTest do
  use ExUnit.Case, async: true

  test "search_notes tool advertises the mode enum" do
    tool = Enum.find(Engram.MCP.Tools.list(), &(&1.name == "search_notes"))
    assert tool.inputSchema["properties"]["mode"]["enum"] == ["hybrid", "keyword", "vector"]
    assert tool.inputSchema["properties"]["mode"]["default"] == "hybrid"
  end

  test "mode arg maps to the Search opt (unknown falls back to hybrid)" do
    assert Engram.MCP.Handlers.search_mode(%{"mode" => "keyword"}) == :keyword
    assert Engram.MCP.Handlers.search_mode(%{"mode" => "vector"}) == :vector
    assert Engram.MCP.Handlers.search_mode(%{"mode" => "nonsense"}) == :hybrid
    assert Engram.MCP.Handlers.search_mode(%{}) == :hybrid
  end
end
```

(If `Engram.MCP.Tools.list/0` has a different name, use the real list accessor
found in `tools.ex`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/mcp/handlers_search_mode_test.exs`
Expected: FAIL — no `mode` in schema; `Handlers.search_mode/1` undefined.

- [ ] **Step 3: Add the schema + handler mapping**

```elixir
# lib/engram/mcp/tools.ex — in the search_notes inputSchema "properties" map,
# add the "mode" property and update the description:
          "mode" => %{
            "type" => "string",
            "enum" => ["hybrid", "keyword", "vector"],
            "description" =>
              "Retrieval mode (default hybrid). Use 'keyword' for exact terms, " <>
                "identifiers, code, or error strings; 'vector' for purely " <>
                "conceptual/semantic queries; 'hybrid' (default) blends both.",
            "default" => "hybrid"
          },
```

```elixir
# lib/engram/mcp/handlers.ex — add a public helper + thread it into opts:
  @doc "Map the MCP `mode` arg to a Search mode (unknown → :hybrid)."
  def search_mode(args) do
    case args["mode"] do
      "keyword" -> :keyword
      "vector" -> :vector
      _ -> :hybrid
    end
  end

# and where search opts are built (the existing `opts = [limit: limit]` line):
    opts = [limit: limit, mode: search_mode(args)]
    opts = if tags, do: Keyword.put(opts, :tags, tags), else: opts
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/mcp/handlers_search_mode_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/mcp/tools.ex lib/engram/mcp/handlers.ex test/engram/mcp/handlers_search_mode_test.exs
git commit -m "feat(search): MCP search_notes mode param (hybrid|keyword|vector)

Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: Encryption assertion — only `{u32: float}` reaches Qdrant

**Files:**
- Test: `test/engram/keyword_index/no_plaintext_test.exs`

- [ ] **Step 1: Write the test (this task is the proof, not a feature)**

```elixir
# test/engram/keyword_index/no_plaintext_test.exs
defmodule Engram.KeywordIndex.NoPlaintextTest do
  use Engram.DataCase, async: true

  alias Engram.Crypto
  alias Engram.KeywordIndex.QdrantSparse

  test "the stored sparse vector contains no plaintext tokens and is unkeyed-irreversible" do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    {:ok, key} = Crypto.dek_filter_key(user)

    text = "PADDLE_API_KEY secret rotation paddle"
    %{indices: indices, values: values} = QdrantSparse.encode_document(text, key, 4, 4.0)

    # Only integers and floats are emitted — no token strings.
    assert Enum.all?(indices, &is_integer/1)
    assert Enum.all?(values, &is_float/1)

    # None of the source tokens appear verbatim as a dimension.
    for token <- ["paddle_api_key", "secret", "rotation", "paddle"] do
      refute token in Enum.map(indices, &to_string/1)
    end

    # Non-reversibility: a different key produces different dims for the same
    # token — so the dims are not a public hash of the plaintext.
    {:ok, other_user} = Crypto.ensure_user_dek(insert(:user))
    {:ok, other_key} = Crypto.dek_filter_key(other_user)
    refute QdrantSparse.dim(key, "secret") == QdrantSparse.dim(other_key, "secret")
  end
end
```

- [ ] **Step 2: Run test to verify it passes (the codec already guarantees this)**

Run: `mix test test/engram/keyword_index/no_plaintext_test.exs`
Expected: PASS. (If it fails, the codec leaked plaintext — fix `QdrantSparse`, do not weaken the test.)

- [ ] **Step 3: Commit**

```bash
git add test/engram/keyword_index/no_plaintext_test.exs
git commit -m "test(search): assert keyword index stores no plaintext tokens

Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: #605 re-normalize worker stub

**Files:**
- Create: `lib/engram/workers/reindex_keyword.ex`
- Test: `test/engram/workers/reindex_keyword_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/workers/reindex_keyword_test.exs
defmodule Engram.Workers.ReindexKeywordTest do
  use Engram.DataCase, async: false

  alias Engram.Workers.ReindexKeyword

  test "enqueues a per-vault re-normalize job" do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    assert {:ok, job} = ReindexKeyword.enqueue(vault.id)
    assert job.args["vault_id"] == to_string(vault.id)
    assert job.worker == "Engram.Workers.ReindexKeyword"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/workers/reindex_keyword_test.exs`
Expected: FAIL — `Engram.Workers.ReindexKeyword.enqueue/1` undefined.

- [ ] **Step 3: Write the worker stub**

```elixir
# lib/engram/workers/reindex_keyword.ex
defmodule Engram.Workers.ReindexKeyword do
  @moduledoc """
  #605 — re-normalize a vault's keyword sparse vectors against its current
  `avgdl`, and backfill notes indexed before the keyword leg existed.

  Recomputes the BM25 TF weight for every chunk (re-decrypt + re-tokenize via
  the normal index path) so length-normalization stays correct as the vault's
  avgdl drifts. Pre-launch this is the manual re-normalizer and the backfill
  tool; AUTOMATIC drift-triggering is deferred (uncalibratable with zero users).

  Scaffold: re-enqueues each of the vault's notes through `EmbedNote`, which
  rebuilds the named dense + keyword vectors in one decrypted pass.
  """
  use Oban.Worker, queue: :indexing, max_attempts: 3

  import Ecto.Query

  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.EmbedNote

  @spec enqueue(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(vault_id) do
    %{vault_id: to_string(vault_id)} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"vault_id" => vault_id}}) do
    note_ids =
      from(n in Note, where: n.vault_id == ^vault_id, select: n.id)
      |> Repo.all(skip_tenant_check: true)

    jobs = Enum.map(note_ids, fn id -> EmbedNote.new(%{note_id: to_string(id)}) end)
    _ = Oban.insert_all(jobs)
    :ok
  end
end
```

(Confirm `EmbedNote.new/1`'s arg key matches its `perform/1` — use the real key
found in `embed_note.ex` `perform/1` pattern, e.g. `%{"note_id" => ...}`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/workers/reindex_keyword_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/workers/reindex_keyword.ex test/engram/workers/reindex_keyword_test.exs
git commit -m "feat(search): #605 keyword re-normalize/backfill worker stub

Auto-trigger deferred (uncalibratable pre-launch). Refs #595, #605

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: Full suite + format/credo green

**Files:** none (verification)

- [ ] **Step 1: Format + Credo**

Run: `mix format && mix credo --strict`
Expected: no formatting diff; Credo passes (the four CI-fatal checks clean).

- [ ] **Step 2: Full test suite**

Run: `mix test`
Expected: PASS, 0 failures (new keyword tests + all existing green). If a
`:qdrant_integration`-tagged test needs a live Qdrant, run the default
(excluded) suite as CI does; note any integration test that needs a real
named-vector collection.

- [ ] **Step 3: Commit any format fixes**

```bash
git add -A
git commit -m "style: mix format keyword-search files

Refs #595

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" || echo "nothing to format"
```

---

## Self-Review

**Spec coverage:**
- Named-vector chunk collection (dense + keyword sparse `idf`) → Tasks 6, 7.
- HMAC(user_DEK, token) → u32, no sign-fold → Task 3.
- BM25 (Qdrant IDF + client TF/length-norm) → Tasks 2 (weight), 6 (`idf`), 9 (apply), 10 (query).
- Tokenizer: NFKC + casefold + UAX#29-ish + CJK bigrams, no stemming → Task 1.
- Per-user avgdl, re-normalizable; no auto-trigger → Tasks 4, 5, 14.
- Hybrid server-side RRF, delete app-side fusion → Tasks 8, 10 (no `Search.Rrf` exists to delete on this branch).
- Rerank on fused top-N, Pro-gated (§G preserved) → Task 10 (shared decrypt→rerank tail; `reranker_active_for?` unchanged).
- Mode dispatch, internal default `:vector`, web `:hybrid`, MCP `mode` → Tasks 10, 11, 12.
- Security: no plaintext at rest → Task 13.
- Rollout: recreate collection (named vectors) → Task 6 (`ensure_collection` runs on first index; prod wiped per "no data is sacred"). Version floor ≥1.10 is an ops checklist item, not code.

**Placeholder scan:** none — every code step has full Elixir.

**Type/name consistency:** `KeywordIndex.module()` resolves to `QdrantSparse`; `encode_document/4` + `encode_query/2` used identically in Tasks 3/9/10; `dim/2` consistent; `tf_weight/4` consistent; `avgdl/1` consistent; sparse shape `%{indices, values}` consistent across Tasks 3/7/8/9/10; Qdrant fns `search/3`, `sparse_search/3`, `hybrid_search/4` consistent.

**Decisions made (flag for the user):**
1. **avgdl storage:** added `chunks.token_count` + an `AVG()` query (`Stats.avgdl/1`) rather than a counter table. Self-correcting, no delta bookkeeping, supports #605 re-normalize cheaply.
2. **No separate keyword write hook in EmbedNote:** the sparse vector is built inline in `Indexing.build_prepared` where chunk plaintext + dense vector already colocate. `EmbedNote` is unchanged — smaller surface than #606's `index_keywords/1`.
3. **No `delete` callback:** deleting a chunk point (existing `Qdrant.delete_by_note`) removes its sparse vector too.
4. **HMAC key reuse:** the keyword dim uses the existing `dek_filter_key`/`hmac_field` fingerprint pattern (same class as folder/tag/path HMACs), not a new derived key.
5. **`KeywordIndex` behaviour reshaped** from #606's `upsert/delete/search` (note-level, store-owned) to `encode_document/encode_query` (codec) — fits the chunk-colocated, Qdrant-fuses-server-side reality.
