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
end
