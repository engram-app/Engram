defmodule Engram.KeywordIndex.StemCache do
  @moduledoc """
  Node-local memo for Snowball stems.

  `Text.Stemmer` is a pure-Elixir Snowball port, and it is *slow*: a 2026-08-20
  measurement put one `stem/2` call at ~83µs, which made stemming **90% of the
  tokenizer's total cost** (3.3 KB of English prose: 939ms unstemmed vs 9,792ms
  stemmed, 200 iterations). In a 2026-08-20 prod profile of a 1.7k-note bulk
  upload the English stemmer frames were the single largest application bucket.

  It is also the most memoizable function in the codebase. Natural-language
  vocabulary is Zipfian: that same 3.3 KB sample held 450 tokens drawn from
  only **40 distinct words**, and the ratio only improves across a whole vault.

  Keyed `{language, token}`. A stem is a pure function of its inputs, so
  entries never go stale — no TTL, no invalidation, no cross-node sync.

  ## What this table holds

  Plaintext vocabulary — individual lowercased words drawn from user notes,
  with no path, note id, or user id attached, in a `:public` node-local ETS
  table shared by every user on the node. That is a real (if modest) new
  surface: a process with BEAM access could enumerate the words some user on
  this node recently indexed. It is deliberately *less* exposure than what
  already sits in the same VM — a resident CRDT room holds an entire note body
  in plaintext — and unlike `Crypto.DekCache` it holds no secrets, which is why
  it does not pay for that module's `:protected` + owner-serialized writes.
  Nothing here is persisted; the table dies with the node.
  """
  use Engram.Cache.NodeLocalEts, table: :engram_stem_cache

  # ~100k distinct words is far past a natural vocabulary (the OED lists ~170k
  # in current use, and no single node indexes all of English), so reaching the
  # cap means token spam rather than legitimate breadth.
  @max_entries 100_000

  @doc """
  `Text.Stemmer.stem/2`, memoized. Callers must have already checked that
  `language` is a supported Snowball language.
  """
  @spec stem(String.t(), atom()) :: String.t()
  def stem(token, language) do
    key = {language, token}

    case ets_lookup(key) do
      [{^key, stem}] ->
        stem

      _ ->
        stem = Text.Stemmer.stem(token, language)
        put(key, stem)
        stem
    end
  end

  # ponytail: flush-on-full rather than an LRU. Word frequency is Zipfian, so
  # the hot set refills within a few hundred tokens and per-entry recency
  # bookkeeping would cost more on every hit than the misses it saves. Swap in
  # an LRU only if flushes ever become frequent enough to show as a real miss
  # rate.
  defp put(key, stem) do
    if full?(), do: clear_local()
    ets_insert({key, stem})
  end

  defp full? do
    case :ets.info(@nle_table, :size) do
      n when is_integer(n) -> n >= @max_entries
      # Table absent (owner down) — `ets_insert/1` is already a guarded no-op.
      _ -> false
    end
  end
end
