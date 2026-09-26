defmodule Engram.Logs.TextScrubberTest do
  use ExUnit.Case, async: true

  alias Engram.Logs.TextScrubber

  describe "scrub/1" do
    test "a quoted path is replaced, quotes kept" do
      msg = "ENOENT: no such file or directory, open '/home/alice/Vault/Medical/biopsy.md'"
      out = TextScrubber.scrub(msg)

      assert out =~ "ENOENT: no such file or directory"
      refute out =~ "biopsy"
      refute out =~ "alice"
    end

    test "double-quoted and backtick paths, including an apostrophe in the title" do
      for msg <- [~s(failed on "Medical/Tom's notes.md"), "failed on `Medical/x.md`"] do
        out = TextScrubber.scrub(msg)
        refute out =~ "Medical", "leaked: #{out}"
        assert out =~ "failed on"
      end
    end

    test "an unquoted OS home directory loses its username" do
      for {msg, user} <- [
            {"at /Users/alice/Library/x", "alice"},
            {"at /home/bob/.config/obsidian", "bob"},
            {~S"at C:\Users\carol\AppData\x", "carol"}
          ] do
        refute TextScrubber.scrub(msg) =~ user, "leaked #{user}"
      end
    end

    test "routes, codes, noteRef labels and counts survive" do
      msg = "POST /api/notes returned 500 for n12 (3 of 40) code=EACCES"
      assert TextScrubber.scrub(msg) == msg
    end

    test "nil and non-binary pass through" do
      assert TextScrubber.scrub(nil) == nil
    end

    test "is bounded on a pathological input" do
      big = String.duplicate("'a/", 5_000) <> String.duplicate("x", 50_000)
      {micros, _} = :timer.tc(fn -> TextScrubber.scrub(big) end)
      assert micros < 500_000
    end

    # Shared rule set with the plugin (src/error-util.ts scrubLogText) and the
    # SPA Sentry scrub. Cases mirror tests/remote-log-privacy.test.ts.
    test "a spaced vault-relative title is fully redacted" do
      out = TextScrubber.scrub("push failed for Medical/Divorce settlement draft.md, retrying")
      refute out =~ "Medical"
      refute out =~ "Divorce"
      refute out =~ "settlement"
      assert out =~ "push failed for"
      assert out =~ "retrying"
    end

    test "a spaced Android absolute path is fully redacted" do
      out = TextScrubber.scrub("open /storage/emulated/0/My Vault/Medical/x y.md failed")
      refute out =~ "My"
      refute out =~ "Medical"
      assert out =~ "failed"
    end

    test "apostrophes inside words do not open a quoted path" do
      msg = "can't push n3 | route=/api/notes | reason=won't retry"
      assert TextScrubber.scrub(msg) == msg
    end

    test "a quoted API route is exempt" do
      msg = ~s({"route":"/api/notes"})
      assert TextScrubber.scrub(msg) == msg
    end

    test "a route before the prose survives a spaced path" do
      out = TextScrubber.scrub("POST /api/notes returned 500 for Medical/x y.md")
      assert out == "POST /api/notes returned 500 for <path>"
    end

    test "attachment types are covered" do
      for ext <- ~w(csv docx xlsx pptx json html epub heif rtf odt key pages numbers) do
        refute TextScrubber.scrub("uploading Medical/lab-results.#{ext} now") =~ "lab-results"
      end
    end

    test "an 8+ token gap still redacts the extension token" do
      out = TextScrubber.scrub("Medical/a b c d e f g h i j.md")
      refute out =~ "j.md"
    end

    test "a field token stops the backward walk" do
      out = TextScrubber.scrub("x/y | reason=bad z.md")
      assert out =~ "| reason=bad"
    end

    test "a stack keeps its error name and frames, not its message line" do
      stack =
        "Error: ENOENT open Medical/secret notes.md\n    at push (app.js:1:2)\n    at run (app.js:3:4)"

      out = TextScrubber.scrub_stack(stack)
      refute out =~ "secret"
      assert out =~ "at push (app.js:1:2)"
      assert out =~ ~r/\AError\n/
    end

    # Growth, not wall-clock: CI runners are shared and loaded, so an absolute
    # budget flakes. Quadratic growth from n to 4n is ~16x; linear is ~4x.
    test "is linear on adversarial spaces, slashes and quotes" do
      generators = [
        spaces: &String.duplicate(" ", &1),
        slashes: &(String.duplicate("a/", div(&1, 2)) <> ".md"),
        quotes: &String.duplicate("'", &1),
        spaced_slashes: &(String.duplicate(" x/y", div(&1, 4)) <> " z.md"),
        quoted_slashes: &String.duplicate(~s("a/b ), div(&1, 5))
      ]

      best = fn input ->
        Enum.min(for _ <- 1..3, do: elem(:timer.tc(fn -> TextScrubber.scrub(input) end), 0))
      end

      for {name, gen} <- generators do
        small = best.(gen.(10_000))
        large = best.(gen.(40_000))
        assert large <= 10 * small + 20_000, "#{name}: #{small}us -> #{large}us"
      end
    end

    # Counted in characters like the plugin/SPA (UTF-16 units there), not
    # bytes: a 400-char Cyrillic path is ~800 bytes per side of its slash.
    test "a long non-Latin quoted path is redacted, as in the plugin" do
      left = String.duplicate("д", 400)
      right = String.duplicate("ж", 400)
      out = TextScrubber.scrub("open '#{left}/#{right}' failed")
      refute out =~ "д"
      refute out =~ "ж"
      assert out =~ "open '<path>' failed"
    end

    test "invalid UTF-8 is scrubbed, not raised on" do
      out = TextScrubber.scrub(<<"open '", 0xFF, "Medical/x.md' failed">>)
      refute out =~ "Medical"
      assert out =~ "failed"
    end
  end
end
