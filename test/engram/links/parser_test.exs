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

  test "does not crash on invalid UTF-8 content (#741 regression)" do
    # Produce invalid UTF-8: pad with a lone continuation byte
    content = "pad " <> <<0xFF>> <> " [[Real]]"
    assert [%{target: "Real"}] = Parser.extract(content)
  end

  describe "target offsets" do
    test "offsets span exactly the trimmed target" do
      content = "pre ![[ Folder/Note.md |shown]] post"
      [occ] = Parser.extract(content)
      assert occ.link_type == "embed"
      assert occ.target == "Folder/Note.md"
      assert binary_part(content, occ.target_start, occ.target_len) == "Folder/Note.md"
    end

    test "offsets stop before the anchor and alias" do
      content = "[[Note#Head|shown]]"
      [occ] = Parser.extract(content)
      assert binary_part(content, occ.target_start, occ.target_len) == "Note"
      assert occ.anchor == "Head"
      assert occ.alias == "shown"
    end

    test "offsets are byte offsets, correct after multibyte text" do
      content = "émoji 🎈 [[Café]]"
      [occ] = Parser.extract(content)
      assert binary_part(content, occ.target_start, occ.target_len) == "Café"
    end

    test "every occurrence in a multi-link line carries its own span" do
      content = "[[A]] and ![[B|x]] and [[C#h]]"

      spans =
        content
        |> Parser.extract()
        |> Enum.map(&binary_part(content, &1.target_start, &1.target_len))

      assert spans == ["A", "B", "C"]
    end
  end

  # #1302 — Obsidian writes these instead of wikilinks when
  # "Settings -> Files & Links -> Use [[Wikilinks]]" is OFF. `link_type`
  # stays wikilink/embed (it means "is this an embed", and resolution
  # ignores it); the new `form` field carries the syntax so the rewriter
  # can emit each occurrence back in the shape the author wrote it.
  describe "markdown links (#1302)" do
    test "extracts a plain markdown link" do
      assert [
               %{
                 target: "Foo.md",
                 alias: "Foo",
                 anchor: nil,
                 link_type: "wikilink",
                 form: :markdown,
                 position: 4
               }
             ] = Parser.extract("See [Foo](Foo.md).")
    end

    test "wikilinks report form :wiki" do
      assert [%{form: :wiki}] = Parser.extract("[[Foo]]")
    end

    test "leading ! makes it an embed" do
      assert [%{target: "diagram.png", link_type: "embed", form: :markdown}] =
               Parser.extract("![alt](diagram.png)")
    end

    test "percent-encoded targets decode for resolution but keep the raw span" do
      content = "[My Note](My%20Note.md)"
      [occ] = Parser.extract(content)

      # `target` is what basename_key/resolve_target need...
      assert occ.target == "My Note.md"
      # ...`target_raw` is the literal bytes, so a rewrite splices correctly.
      assert occ.target_raw == "My%20Note.md"
      assert binary_part(content, occ.target_start, occ.target_len) == "My%20Note.md"
    end

    test "wikilink target_raw equals target" do
      [occ] = Parser.extract("[[Folder/Note.md]]")
      assert occ.target_raw == occ.target
    end

    test "angle-bracketed targets unwrap, span covers only the inside" do
      content = "[x](<My Note.md>)"
      [occ] = Parser.extract(content)
      assert occ.target == "My Note.md"
      assert binary_part(content, occ.target_start, occ.target_len) == "My Note.md"
    end

    test "anchors split off the target" do
      content = "[x](Note.md#Some%20Heading)"
      [occ] = Parser.extract(content)
      assert occ.target == "Note.md"
      assert occ.anchor == "Some Heading"
      assert binary_part(content, occ.target_start, occ.target_len) == "Note.md"
    end

    test "a link title after the target is not part of it" do
      content = ~s|[x](Note.md "The Title")|
      [occ] = Parser.extract(content)
      assert occ.target == "Note.md"
      assert binary_part(content, occ.target_start, occ.target_len) == "Note.md"
    end

    test "external and non-vault targets are skipped" do
      content = """
      [a](https://example.com) [b](http://x.test/y) [c](mailto:t@example.com)
      [d](//cdn.example.com/x.png) [e](#just-a-heading) [f]() [g](ftp://h/i)
      """

      assert [] = Parser.extract(content)
    end

    test "obeys the same code-fence, inline-code and frontmatter exclusions" do
      content = """
      ---
      title: has [nope](No.md)
      ---
      `[inline nope](No.md)`

      ```
      [fenced nope](No.md)
      ```

      [Real](Real.md)
      """

      assert [%{target: "Real.md", form: :markdown}] = Parser.extract(content)
    end

    test "mixed wikilink and markdown links both extract, in document order" do
      content = "[[A]] then [B](B.md) then ![[c.png]] then ![d](d.png)"

      assert [
               %{target: "A", form: :wiki, link_type: "wikilink"},
               %{target: "B.md", form: :markdown, link_type: "wikilink"},
               %{target: "c.png", form: :wiki, link_type: "embed"},
               %{target: "d.png", form: :markdown, link_type: "embed"}
             ] = Parser.extract(content)
    end

    test "a wikilink nested in markdown-link label does not double-extract" do
      # Obsidian never writes this, but hand-authored notes can contain it.
      # ONE written link must yield ONE edge. The count assertion is the
      # point of this test: without it, widening the label class to allow
      # `[` produces a second, spurious markdown edge and this test still
      # passes (caught in review of this PR).
      content = "[see [[A]]](B.md)"
      occs = Parser.extract(content)

      assert length(occs) == 1
      assert [%{target: "A", form: :wiki}] = occs

      for occ <- occs do
        assert binary_part(content, occ.target_start, occ.target_len) == occ.target_raw
      end
    end

    test "a path with balanced parens is captured whole, not truncated" do
      # A bare `[^)]*` destination stopped at the first `)`, yielding the
      # target "My(file" — a garbage note_links edge, not a skip.
      content = "[x](My(file).md)"
      [occ] = Parser.extract(content)

      assert occ.target == "My(file).md"
      assert binary_part(content, occ.target_start, occ.target_len) == "My(file).md"
    end

    test "parens survive alongside percent-encoding, which is what Obsidian writes" do
      content = "[x](My%20(file).md)"
      [occ] = Parser.extract(content)

      assert occ.target == "My (file).md"
      assert occ.target_raw == "My%20(file).md"
    end

    test "a LITERAL space before parens follows CommonMark: destination ends there" do
      # `[x](My (file).md)` is not one link to any conforming renderer — an
      # unbracketed destination cannot contain a space, so it is `My` with a
      # malformed title after it. We match that rather than inventing a
      # friendlier reading, and the angle-bracket form is the escape hatch.
      assert [%{target: "My"}] = Parser.extract("[x](My (file).md)")
      assert [%{target: "My (file).md"}] = Parser.extract("[x](<My (file).md>)")
    end

    test "a space ends the destination — no trailing space baked into the target" do
      # CommonMark: an unbracketed destination runs to the first whitespace,
      # and the rest is a (here malformed) title. Trimming only BEFORE the
      # anchor split used to leave `"Note.md "` and silently dangle.
      content = "[x](Note.md #anchor)"
      [occ] = Parser.extract(content)

      assert occ.target == "Note.md"
      assert occ.anchor == nil
    end

    test "an escape decoding to invalid UTF-8 is scrubbed, never stored raw" do
      # `%FF` decodes to a lone 0xFF. Unscrubbed it is encrypted, stored, then
      # decrypted straight into a JSON response — Jason.encode! raises and
      # 500s every read of that note's backlinks, permanently.
      [occ] = Parser.extract("[bad](%FF.md)")

      assert String.valid?(occ.target)
      assert String.valid?(occ.target_raw)
    end

    # Both regexes previously had no early exit on these shapes: 67s on the
    # whitespace run, 14.2s on the bracket run, measured, on the synchronous
    # write path. Generous bounds — this pins the complexity class, not a
    # throughput number, so it will not flake on a loaded CI box.
    @tag timeout: 30_000
    test "pathological input stays linear (ReDoS regression guard)" do
      whitespace = "[x](Note.md" <> String.duplicate(" ", 100_000) <> ")"
      brackets = String.duplicate("[", 100_000)

      for content <- [whitespace, brackets] do
        {micros, _} = :timer.tc(fn -> Parser.extract(content) end)
        assert micros < 2_000_000, "took #{div(micros, 1000)}ms — backtracking regression"
      end
    end

    test "offsets are byte offsets, correct after multibyte text" do
      content = "émoji 🎈 [Café](Caf%C3%A9.md)"
      [occ] = Parser.extract(content)
      assert occ.target == "Café.md"
      assert binary_part(content, occ.target_start, occ.target_len) == "Caf%C3%A9.md"
    end

    test "malformed percent-escapes are left alone rather than crashing" do
      content = "[x](100%25%ZZ.md)"
      [occ] = Parser.extract(content)
      assert binary_part(content, occ.target_start, occ.target_len) == occ.target_raw
    end
  end
end
