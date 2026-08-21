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
  with no path, note id, or user id attached, shared by every user on the node.
  There is no version of this cache that avoids that: the *value* is a stem,
  which is itself a readable word, so hashing the key would hide nothing.

  `:protected` + `:sensitive` accordingly. `:protected` keeps reads direct-ETS
  (the hot path) while closing cache-poisoning — writes go through the owner
  via `handle_cast/2`, which costs nothing measurable because a write only
  happens on a miss, where we are already paying ~83µs for the stem itself.
  `:sensitive` keeps the vocabulary out of `erl_crash.dump`, the one genuinely
  new exposure here (in-memory reads are moot — a resident CRDT room holds an
  entire note body in plaintext in the same VM).

  Nothing is persisted; the table dies with the node.
  """
  use Engram.Cache.NodeLocalEts,
    table: :engram_stem_cache,
    access: :protected,
    sensitive: true

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

  @doc """
  Drops every cached stem. Must go through the owner — the table is
  `:protected`, so the injected `clear_local/0` rescues and silently no-ops
  when called from anywhere else.
  """
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  # Fire-and-forget: the caller already has the stem, so it has nothing to wait
  # for, and a dropped write just costs one future miss. `cast` also keeps the
  # owner off the caller's critical path under concurrent indexing.
  defp put(key, stem), do: GenServer.cast(__MODULE__, {:put, key, stem})

  @doc false
  # Test helper. `process_info(pid, :sensitive)` is not a valid introspection
  # key, so read it the way `Crypto.DekCache` does: `process_flag/2` returns
  # the PREVIOUS value, making a true -> true toggle a non-mutating read.
  @spec sensitive_flag?() :: boolean()
  def sensitive_flag?, do: GenServer.call(__MODULE__, :__sensitive_flag__)

  @impl true
  def handle_call(:clear, _from, state) do
    clear_local()
    {:reply, :ok, state}
  end

  def handle_call(:__sensitive_flag__, _from, state) do
    {:reply, :erlang.process_flag(:sensitive, true), state}
  end

  @impl true
  def handle_cast({:put, key, stem}, state) do
    # ponytail: flush-on-full rather than an LRU. Word frequency is Zipfian, so
    # the hot set refills within a few hundred tokens and per-entry recency
    # bookkeeping would cost more on every hit than the misses it saves. Swap
    # in an LRU only if flushes ever become frequent enough to show as a real
    # miss rate.
    if full?(), do: clear_local()
    ets_insert({key, stem})
    {:noreply, state}
  end

  defp full? do
    case :ets.info(@nle_table, :size) do
      n when is_integer(n) -> n >= @max_entries
      # Table absent (owner down) — `ets_insert/1` is already a guarded no-op.
      _ -> false
    end
  end
end
