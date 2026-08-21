defmodule Engram.KeywordIndex.StemCacheTest do
  use ExUnit.Case, async: false

  alias Engram.KeywordIndex.StemCache

  setup do
    StemCache.clear_local()
    :ok
  end

  test "returns the same stem Text.Stemmer would, cold and warm" do
    assert StemCache.stem("running", :en) == Text.Stemmer.stem("running", :en)
    # Second call is served from ETS — must not drift.
    assert StemCache.stem("running", :en) == Text.Stemmer.stem("running", :en)
  end

  test "caches the value, not just the fact of a lookup" do
    _ = StemCache.stem("deploying", :en)
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
    assert [{{:en, "run"}, "run"}] = StemCache.ets_lookup({:en, "run"})
  end

  test "survives an absent table by falling through to the stemmer" do
    # Owner down / table gone must degrade to a correct (if slower) answer
    # rather than crashing an indexing job.
    :ets.delete(:engram_stem_cache)

    assert StemCache.stem("running", :en) == "run"
  after
    # Restart the owner so later tests get their table back.
    Supervisor.terminate_child(Engram.Supervisor, StemCache)
    Supervisor.restart_child(Engram.Supervisor, StemCache)
  end
end
