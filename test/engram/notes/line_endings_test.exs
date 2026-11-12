defmodule Engram.Notes.LineEndingsTest do
  use ExUnit.Case, async: true

  alias Engram.Notes.LineEndings

  describe "to_lf/1" do
    test "converts CRLF" do
      assert LineEndings.to_lf("a\r\nb\r\n") == "a\nb\n"
    end

    test "converts a lone CR" do
      assert LineEndings.to_lf("a\rb\r") == "a\nb\n"
    end

    test "converts mixed endings, CRLF as one newline" do
      assert LineEndings.to_lf("a\r\nb\rc\nd\r\r\ne") == "a\nb\nc\nd\n\ne"
    end

    test "leaves LF text and the empty string alone" do
      assert LineEndings.to_lf("a\nb\n") == "a\nb\n"
      assert LineEndings.to_lf("") == ""
    end
  end

  describe "for_path/2" do
    test "converts a markdown note" do
      assert LineEndings.for_path("a\r\nb\r", "N.md") == "a\nb\n"
    end

    test "leaves canvas, base and pathless text byte-exact" do
      text = "{\r\n  \"nodes\": []\r\n}\r"
      assert LineEndings.for_path(text, "Board.canvas") == text
      assert LineEndings.for_path(text, "Table.base") == text
      assert LineEndings.for_path(text, nil) == text
    end
  end
end
