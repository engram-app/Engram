defmodule Engram.KeywordIndex.LangDetectTest do
  use ExUnit.Case, async: true

  alias Engram.KeywordIndex.LangDetect

  # lingua lazy-loads language models on first call; ensure the app (and NIF) is running.
  setup_all do
    Application.ensure_all_started(:lingua)
    :ok
  end

  test "detects German on a real sentence" do
    assert LangDetect.detect("die Bereitstellung wurde getestet") == :de
  end

  test "detects English on a real sentence" do
    assert LangDetect.detect("the deployment process was tested today") == :en
  end

  test "nonsense Latin text returns nil (confidence below 0.40 floor)" do
    # lingua cannot confidently classify keyboard-mash; top confidence is well below 0.40.
    assert LangDetect.detect("asdfghjkl qwerty zxcvbnm") == nil
  end

  test "pure non-Latin text is not sent to the detector (returns nil)" do
    assert LangDetect.detect("東京都") == nil
  end
end
