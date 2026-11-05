defmodule Engram.TextTest do
  use ExUnit.Case, async: true

  alias Engram.Text

  test "keeps a string at or under the limit" do
    assert Text.truncate("abc", 3) == "abc"
    assert Text.truncate("", 5) == ""
  end

  test "cuts on codepoints, never splitting a multi-byte character" do
    assert Text.truncate("héllo", 2) == "hé"
    assert Text.truncate("éé", 3) == "ée"
    assert Text.truncate("日本語", 0) == ""
  end

  test "nil passes through" do
    assert Text.truncate(nil, 5) == nil
  end

  test "invalid UTF-8 in the kept prefix is replaced, never kept" do
    out = Text.truncate("ab" <> <<0xFF>> <> "cd", 4)
    assert String.valid?(out)
    assert out == "ab\uFFFDc"
  end

  test "invalid bytes past the cut are not examined or kept" do
    assert Text.truncate("abc" <> <<0xFF>>, 2) == "ab"
  end
end
