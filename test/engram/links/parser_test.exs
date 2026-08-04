defmodule Engram.Links.ParserTest do
  use ExUnit.Case, async: true

  alias Engram.Links.Parser

  test "extracts a plain wikilink with its position" do
    assert [%{target: "Foo", alias: nil, anchor: nil, link_type: "wikilink", position: 4}] =
             Parser.extract("See [[Foo]].")
  end

  test "extracts alias, heading anchor, and block anchor" do
    content = "[[Page|shown]] and [[Page#Heading]] and [[Page#^blockid]]"

    assert [
             %{target: "Page", alias: "shown", anchor: nil},
             %{target: "Page", anchor: "Heading"},
             %{target: "Page", anchor: "^blockid"}
           ] = Parser.extract(content)
  end

  test "embeds get link_type embed" do
    assert [%{target: "image.png", link_type: "embed"}] = Parser.extract("![[image.png]]")
  end

  test "ignores links inside fenced code, inline code, and frontmatter" do
    content = """
    ---
    title: has [[NotALink]]
    ---
    `[[inline nope]]`

    ```
    [[fenced nope]]
    ```

    [[Real]]
    """

    assert [%{target: "Real"}] = Parser.extract(content)
  end

  test "skips empty and same-page-anchor-only targets" do
    assert [] = Parser.extract("[[]] and [[#Just A Heading]]")
  end

  test "multibyte content does not shift positions into invalid offsets" do
    # u-flag regression guard (prod bug #741 class)
    content = "émoji 🎉 then [[Café]]"
    assert [%{target: "Café", position: pos}] = Parser.extract(content)
    assert binary_part(content, pos, 2) == "[["
  end

  test "empty content extracts nothing" do
    assert [] = Parser.extract("")
  end
end
