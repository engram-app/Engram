defmodule Engram.Notes.HelpersTest do
  use ExUnit.Case, async: true

  alias Engram.Notes.Helpers

  describe "scrub_utf8/1" do
    test "leaves valid UTF-8 byte-identical" do
      s = "héllo — world 日本語"
      assert Helpers.scrub_utf8(s) == s
      assert String.valid?(Helpers.scrub_utf8(s))
    end

    test "replaces a dangling multibyte lead byte with the replacement char" do
      # `–` is U+2013 = <<0xE2, 0x80, 0x93>>; keep only the lead byte (the prod bug).
      bad = "PRs #71" <> <<0xE2>> <> "#85"
      out = Helpers.scrub_utf8(bad)

      assert String.valid?(out)
      assert out == "PRs #71�#85"
    end

    test "scrubbed output is always JSON-encodable" do
      bad = <<"## Result 1 (score: 0.577)\n", 0xE2, "tail">>
      assert {:ok, _} = Jason.encode(Helpers.scrub_utf8(bad))
    end

    test "empty string passes through" do
      assert Helpers.scrub_utf8("") == ""
    end
  end

  describe "scrub_broadcast_payload/1" do
    test "scrubs every text field of a note_changed payload to valid UTF-8" do
      bad = "body" <> <<0xE2>> <> "tail"

      payload = %{
        "event_type" => "upsert",
        "path" => "Test/Note.md",
        "content" => bad,
        "title" => "Title" <> <<0xE2>>,
        "folder" => "Folder" <> <<0xE2>>,
        "tags" => ["clean", "dirty" <> <<0xE2>>],
        "version" => 3
      }

      out = Helpers.scrub_broadcast_payload(payload)

      # The whole payload is what crashed Phoenix.PubSub/Jason on #738.
      assert {:ok, _} = Jason.encode(out)
      assert String.valid?(out["content"])
      assert String.valid?(out["title"])
      assert String.valid?(out["folder"])
      assert Enum.all?(out["tags"], &String.valid?/1)
      # Bad bytes are replaced, not dropped — the rest of the text survives.
      assert out["content"] =~ "body"
      assert out["content"] =~ "tail"
      # Non-text fields pass through untouched.
      assert out["version"] == 3
      assert out["event_type"] == "upsert"
    end

    test "leaves an already-valid payload byte-identical" do
      payload = %{"content" => "clean", "title" => "T", "folder" => "F", "tags" => ["a", "b"]}
      assert Helpers.scrub_broadcast_payload(payload) == payload
    end

    test "tolerates a payload missing the optional text fields (delete shape)" do
      payload = %{"event_type" => "delete", "path" => "Test/Gone.md", "vault_id" => "v"}
      assert Helpers.scrub_broadcast_payload(payload) == payload
    end
  end

  describe "scrub_utf8/2 instrumentation" do
    import ExUnit.CaptureLog

    setup do
      handler = "scrub-telemetry-#{inspect(make_ref())}"

      :telemetry.attach(
        handler,
        [:engram, :notes, :utf8_scrub],
        fn _event, measurements, metadata, pid ->
          # Handlers run synchronously in the process that called
          # `:telemetry.execute`, so `self()` here is the emitter. Forward only
          # events emitted by THIS test's own process — otherwise a concurrent
          # async test that scrubs invalid UTF-8 trips this global handler and
          # leaks into our mailbox, flaking `refute_receive` (#754).
          if self() == pid, do: send(pid, {:scrub_telemetry, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "scrubs identically to /1 while accepting a boundary" do
      bad = "PRs #71" <> <<0xE2>> <> "#85"
      assert Helpers.scrub_utf8(bad, :read) == "PRs #71�#85"
    end

    test "emits a counter telemetry event tagged with the boundary on invalid input" do
      assert Helpers.scrub_utf8("ok" <> <<0xE2>>, :read) == "ok�"
      assert_receive {:scrub_telemetry, %{count: 1}, %{boundary: :read}}
    end

    test "does not emit telemetry for valid input (fast path)" do
      assert Helpers.scrub_utf8("clean", :write) == "clean"
      refute_receive {:scrub_telemetry, _, _}
    end

    test "ignores scrub events emitted by other processes (no cross-test leak, #754)" do
      # Reproduces the flake deterministically: a DIFFERENT process scrubs
      # invalid input while our handler is attached. :telemetry handlers run
      # synchronously in the caller of `:telemetry.execute`, so before the fix
      # this test's *global* handler fired in the foreign process and leaked a
      # `{:scrub_telemetry, ...}` into our mailbox — exactly how a concurrent
      # async test tripped the `refute_receive` above under load. The handler
      # must only forward events from its own test's process.
      task = Task.async(fn -> Helpers.scrub_utf8("x" <> <<0xE2>>, :read) end)
      assert Task.await(task) == "x�"

      # The scrub above (in the task process) already ran; if the handler had
      # leaked it, the message would be in our mailbox now.
      refute_received {:scrub_telemetry, _, _}
    end

    test "logs a warning on the write boundary (new corruption is actionable)" do
      log = capture_log(fn -> Helpers.scrub_utf8("x" <> <<0xE2>>, :write) end)
      assert log =~ "invalid UTF-8"
    end

    test "stays silent on read/search boundaries (counter-only, avoids log spam)" do
      assert capture_log(fn -> Helpers.scrub_utf8("x" <> <<0xE2>>, :read) end) == ""
      assert capture_log(fn -> Helpers.scrub_utf8("x" <> <<0xE2>>, :search) end) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # extract_title/2
  # ---------------------------------------------------------------------------

  describe "extract_title/2" do
    test "from frontmatter title field" do
      content = "---\ntitle: My Custom Title\n---\n# Heading\nBody"
      assert Helpers.extract_title(content, "Notes/File.md") == "My Custom Title"
    end

    test "from first h1 heading" do
      content = "# My Heading\nBody text"
      assert Helpers.extract_title(content, "Notes/File.md") == "My Heading"
    end

    test "heading with extra spaces stripped" do
      content = "#   Spaced Heading  \nBody"
      assert Helpers.extract_title(content, "Notes/File.md") == "Spaced Heading"
    end

    test "falls back to filename without extension" do
      content = "Just body text, no heading"
      assert Helpers.extract_title(content, "Notes/My Note.md") == "My Note"
    end

    test "filename without folder" do
      assert Helpers.extract_title("Just body text", "Inbox.md") == "Inbox"
    end

    test "frontmatter title takes priority over heading" do
      content = "---\ntitle: FM Title\n---\n# Heading Title\nBody"
      assert Helpers.extract_title(content, "Notes/File.md") == "FM Title"
    end

    test "empty content uses filename" do
      assert Helpers.extract_title("", "Notes/Empty.md") == "Empty"
    end

    test "frontmatter without title falls back to heading" do
      content = "---\ntags: [a, b]\n---\n# The Heading\nBody text"
      assert Helpers.extract_title(content, "Notes/Tagged.md") == "The Heading"
    end

    test "frontmatter without title and no heading uses filename" do
      content = "---\ntags: [a, b]\n---\nBody text"
      assert Helpers.extract_title(content, "Notes/Tagged.md") == "Tagged"
    end
  end

  # ---------------------------------------------------------------------------
  # extract_tags/1
  # ---------------------------------------------------------------------------

  describe "extract_tags/1" do
    test "list-style tags" do
      content = "---\ntags: [health, fitness]\n---\nBody"
      assert Helpers.extract_tags(content) == ["health", "fitness"]
    end

    test "comma-separated string tags" do
      content = "---\ntags: health, fitness\n---\nBody"
      assert Helpers.extract_tags(content) == ["health", "fitness"]
    end

    test "block-style (multi-line) list tags" do
      content = "---\ntags:\n  - project\n  - work\n---\nBody"
      assert Helpers.extract_tags(content) == ["project", "work"]
    end

    test "block-style list tags with a leading blank line and inline tag" do
      content = "---\ntags:\n  - alpha\n  - beta\n---\nBody with #gamma"
      assert Helpers.extract_tags(content) == ["alpha", "beta", "gamma"]
    end

    test "single-item block list" do
      content = "---\ntags:\n  - solo\n---\nBody"
      assert Helpers.extract_tags(content) == ["solo"]
    end

    test "block list stops at the next frontmatter key" do
      content = "---\ntags:\n  - alpha\n  - beta\nauthor: me\n---\nBody"
      assert Helpers.extract_tags(content) == ["alpha", "beta"]
    end

    test "block list preceded by other frontmatter keys" do
      content = "---\ntitle: T\ntags:\n  - alpha\n  - beta\naliases:\n  - x\n---\nBody"
      assert Helpers.extract_tags(content) == ["alpha", "beta"]
    end

    test "quoted block-list items are unquoted" do
      content = "---\ntags:\n  - \"alpha\"\n  - 'beta'\n---\nBody"
      assert Helpers.extract_tags(content) == ["alpha", "beta"]
    end

    test "quoted inline-list items are unquoted" do
      content = "---\ntags: [\"alpha\", 'beta']\n---\nBody"
      assert Helpers.extract_tags(content) == ["alpha", "beta"]
    end

    test "CRLF frontmatter with a block list" do
      content = "---\r\ntags:\r\n  - alpha\r\n  - beta\r\n---\r\nBody"
      assert Helpers.extract_tags(content) == ["alpha", "beta"]
    end

    test "no frontmatter returns empty list" do
      assert Helpers.extract_tags("# No Tags\nBody") == []
    end

    test "empty tags list" do
      content = "---\ntags: []\n---\nBody"
      assert Helpers.extract_tags(content) == []
    end

    test "empty content returns empty list" do
      assert Helpers.extract_tags("") == []
    end

    test "frontmatter without tags field" do
      content = "---\ntitle: Just a title\n---\nBody"
      assert Helpers.extract_tags(content) == []
    end

    test "extracts an inline #tag from the body" do
      assert Helpers.extract_tags("Some body with a #fitness tag") == ["fitness"]
    end

    test "extracts a nested inline #area/sub tag" do
      assert Helpers.extract_tags("Work note #area/subarea here") == ["area/subarea"]
    end

    test "merges frontmatter tags with inline tags, frontmatter first, deduped" do
      content = "---\ntags: [health]\n---\nBody #fitness and again #health"
      assert Helpers.extract_tags(content) == ["health", "fitness"]
    end

    test "skips #tags inside a fenced code block" do
      content = "Intro #real\n\n```\nnot a #tag here\n```\n\nOutro"
      assert Helpers.extract_tags(content) == ["real"]
    end

    test "skips #tags inside an inline code span" do
      content = "Use `#notatag` in code but #realtag in prose"
      assert Helpers.extract_tags(content) == ["realtag"]
    end

    test "skips the # fragment in a URL" do
      content = "See https://example.com/docs#section for details"
      assert Helpers.extract_tags(content) == []
    end

    test "does not treat a word-attached hash as a tag" do
      assert Helpers.extract_tags("issue C#sharp note") == []
    end

    test "skips heading markers" do
      content = "# Heading One\n## Heading Two\nBody #onlytag"
      assert Helpers.extract_tags(content) == ["onlytag"]
    end

    test "rejects purely-numeric matches like #42" do
      assert Helpers.extract_tags("Closes #42 and tags #bug") == ["bug"]
    end

    test "deduplicates repeated inline tags" do
      assert Helpers.extract_tags("#dup once #dup twice") == ["dup"]
    end

    test "never byte-slices a multibyte char after a #tag (#741 root cause)" do
      # `–` (en-dash U+2013 = <<0xE2,0x80,0x93>>) immediately after `#628`. The
      # byte-mode regex used to capture `628` + the en-dash's lead byte (0xE2),
      # emitting an invalid-UTF-8 tag from VALID content — the exact source of
      # the corrupt tags found at rest in prod.
      content = "note x #628" <> <<0xE2, 0x80, 0x93>> <> " y"
      assert String.valid?(content)

      tags = Helpers.extract_tags(content)
      assert Enum.all?(tags, &String.valid?/1)
      # 628 is purely numeric and the en-dash is not a tag char → no tag at all.
      assert tags == []
    end

    test "keeps a real multibyte inline tag intact" do
      assert Helpers.extract_tags("a #café and #über b") == ["café", "über"]
    end
  end

  # ---------------------------------------------------------------------------
  # extract_folder/1
  # ---------------------------------------------------------------------------

  describe "extract_folder/1" do
    test "single folder level" do
      assert Helpers.extract_folder("Notes/File.md") == "Notes"
    end

    test "nested folder" do
      assert Helpers.extract_folder("Notes/Sub/File.md") == "Notes/Sub"
    end

    test "no folder returns empty string" do
      assert Helpers.extract_folder("File.md") == ""
    end

    test "deep nesting" do
      assert Helpers.extract_folder("A/B/C/D/File.md") == "A/B/C/D"
    end
  end
end
