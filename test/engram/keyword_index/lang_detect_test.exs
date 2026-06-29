defmodule Engram.KeywordIndex.LangDetectTest do
  use ExUnit.Case, async: true

  alias Engram.KeywordIndex.LangDetect

  test "detects German on a real sentence" do
    assert LangDetect.detect("die Bereitstellung wurde getestet") == :de
  end

  test "detects English on a real sentence" do
    assert LangDetect.detect("the deployment process was tested today") == :en
  end

  test "undetermined / too-short text returns nil (raw-only fallback)" do
    # paasaa returns "und" for text too short to classify; "und" is unmapped -> nil
    assert LangDetect.detect("x") == nil
  end

  test "pure non-Latin text is not sent to the detector (returns nil)" do
    assert LangDetect.detect("東京都") == nil
  end
end
