defmodule Engram.KeywordIndex.StemCacheTest do
  use ExUnit.Case, async: false

  alias Engram.KeywordIndex.StemCache

  setup do
    :ok = StemCache.clear()
    :ok
  end

  # Writes are a cast; a call afterwards guarantees the owner drained it.
  defp sync, do: :sys.get_state(StemCache)

  test "returns the same stem Text.Stemmer would, cold and warm" do
    assert StemCache.stem("running", :en) == Text.Stemmer.stem("running", :en)
    sync()
    # Second call is served from ETS — must not drift.
    assert StemCache.stem("running", :en) == Text.Stemmer.stem("running", :en)
  end

  test "caches the value, not just the fact of a lookup" do
    _ = StemCache.stem("deploying", :en)
    sync()
    assert [{{:en, "deploying"}, "deploy"}] = StemCache.ets_lookup({:en, "deploying"})
  end

  test "keys by language — same token stems differently per language" do
    en = StemCache.stem("courir", :en)
    fr = StemCache.stem("courir", :fr)

    assert en == Text.Stemmer.stem("courir", :en)
    assert fr == Text.Stemmer.stem("courir", :fr)
    refute en == fr
  end

  test "a token whose stem equals itself is still cached (no repeated work)" do
    assert StemCache.stem("run", :en) == "run"
    sync()
    assert [{{:en, "run"}, "run"}] = StemCache.ets_lookup({:en, "run"})
  end

  test "the table is :protected — a foreign process cannot poison an entry" do
    _ = StemCache.stem("running", :en)
    sync()

    assert_raise ArgumentError, fn ->
      :ets.insert(:engram_stem_cache, {{:en, "running"}, "POISONED"})
    end

    assert StemCache.stem("running", :en) == "run"
  end

  test "owner is :sensitive — the table stays out of crash dumps" do
    assert StemCache.sensitive_flag?()
  end

  test "survives an absent table by falling through to the stemmer" do
    # Owner down / table gone must degrade to a correct (if slower) answer
    # rather than crashing an indexing job.
    Supervisor.terminate_child(Engram.Supervisor, StemCache)

    assert StemCache.stem("running", :en) == "run"
  after
    Supervisor.restart_child(Engram.Supervisor, StemCache)
  end
end
