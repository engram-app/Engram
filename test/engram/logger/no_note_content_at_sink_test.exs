defmodule Engram.Logger.NoNoteContentAtSinkTest do
  @moduledoc """
  The property, end to end: drive REAL failures and assert nothing note-shaped
  reaches the prod log sink.

  Every other test in this directory pins a MECHANISM — `safe_reason/1` renders
  a label, `RedactFilter` scrubs a key, the source guard flags a call site. Each
  is necessary and none of them tests the thing actually promised, which is:

      "I don't want there to be any way to log or send note content."

  Eight review rounds found leaks one at a time, in modules the mechanism tests
  all passed for: an S3 key inside `reason:` while `storage_key:` beside it was
  redacted; an exception struct flattened into an encodable map carrying the
  body; a vault path rebuilt at read time and handed to S3. A test at the SINK
  catches that whole class at once, because it does not care which mechanism was
  supposed to stop it.

  ## How it works

  Failures are provoked through real functions on real rows, with note content
  and a recognisable path in scope. Everything the code logs is run through the
  REAL `RedactFilter` and the REAL prod formatter — `{LoggerJSON.Formatters.Basic,
  metadata: {:all_except, [:__sentry__]}}` from config/prod.exs — and the
  resulting JSON is searched for the secrets.

  `capture_log` is deliberately not used: it renders the DEV text formatter,
  whose `metadata:` allowlist omits keys that prod emits. A leak in `:error`
  metadata is invisible to it and fully visible in production.

  ## What it cannot do

  It only covers failures it knows how to provoke. A path that never fails in
  the test suite is not asserted here, which is why the mechanism tests and the
  source guard stay. This is the net that catches what they miss, not a
  replacement for them.
  """
  use Engram.DataCase, async: false

  alias Engram.Attachments
  alias Engram.Logger.Metadata

  @secret "Dear diary, the biopsy came back positive"
  @folder "Medical"
  @path "Medical/2026 biopsy results.md"

  # Anything that would identify the note. `@folder` is the one that matters
  # most: a folder name discloses the sensitive fact without the body.
  @markers [@secret, @folder, "biopsy", "2026 biopsy results"]

  setup do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    # `RedactFilter` is NOT applied here. It is installed as a PRIMARY filter at
    # boot (`application.ex:138`), unconditionally, in every env including test
    # — so every event reaching a handler has already been through it. An
    # earlier version of this file called it again, which meant a bug that only
    # showed on the first application was masked, and the test could not say
    # which pass had done the work.
    handler = fn event ->
      {mod, cfg} = LoggerJSON.Formatters.Basic.new(metadata: {:all_except, [:__sentry__]})
      line = mod.format(event, cfg) |> IO.iodata_to_binary()
      Agent.update(agent, &[line | &1])
    end

    :logger.add_handler(:sink_probe, __MODULE__, %{config: %{fun: handler}, level: :debug})
    on_exit(fn -> :logger.remove_handler(:sink_probe) end)

    {:ok, lines: fn -> Agent.get(agent, & &1) end}
  end

  # :logger handler callback.
  def log(event, %{config: %{fun: fun}}), do: fun.(event)

  # `anchor` is not optional decoration. `refute`-only assertions pass just as
  # happily when the filter has blanked EVERY line — which is exactly what the
  # `catch` arm in `RedactFilter` does on a malformed event, and what one real
  # defect in this workstream did for a whole class of input. Every caller
  # names something that must SURVIVE.
  defp assert_clean(lines, anchor, count) do
    emitted = lines.()

    for marker <- @markers, line <- emitted do
      refute line =~ marker,
             """
             A note marker reached the prod log sink.

               marker: #{inspect(marker)}
               line:   #{line}

             Whichever mechanism was meant to stop this did not. Fix it at the
             source — the call site, `safe_reason/1`, or `RedactFilter` — not by
             narrowing this test.
             """
    end

    # Vacuity, both halves. A probe that logged nothing proves nothing, and a
    # probe whose every line is `[REDACTED]` proves only that the filter can
    # destroy output.
    assert emitted != [], "no log lines were captured — the failure did not fire"

    # COUNT, not `any?`. With `any?`, a test emitting three lines was satisfied
    # by one of them surviving — review proved it: blanking exactly one of the
    # three lines in the split-elements test left the suite GREEN. The count is
    # how many log calls the test makes, so losing any one of them is red.
    actual = Enum.count(emitted, &(&1 =~ anchor))

    assert actual == count,
           """
           Expected #{count} line(s) to survive redaction, got #{actual}.

             expected to survive: #{inspect(anchor)}
             lines: #{inspect(emitted)}

           The markers being absent means nothing if the diagnostic is absent
           too — a filter that blanks every line passes every `refute` above.
           """
  end

  describe "attachment failures" do
    test "a missing blob on a live row", %{lines: lines} do
      user = insert(:user) |> Engram.Repo.reload!()
      vault = insert(:vault, user: user)

      {:ok, att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "Medical/biopsy scan.png",
          "content_base64" => Base.encode64(@secret),
          "mtime" => 0.0
        })

      Engram.Storage.InMemory.delete(att.storage_key)

      assert {:error, {:storage, :blob_missing}} =
               Attachments.get_attachment(user, vault, "Medical/biopsy scan.png")

      assert_clean(lines, "blob missing", 1)
    end

    test "a row with no storage_key", %{lines: lines} do
      user = insert(:user) |> Engram.Repo.reload!()
      vault = insert(:vault, user: user)

      {:ok, att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "Medical/biopsy scan.png",
          "content_base64" => Base.encode64(@secret),
          "mtime" => 0.0
        })

      Engram.Repo.with_tenant(user.id, fn ->
        import Ecto.Query

        from(a in Engram.Attachments.Attachment, where: a.id == ^att.id)
        |> Engram.Repo.update_all(set: [storage_key: nil])
      end)

      assert {:error, {:storage, :blob_missing}} =
               Attachments.get_attachment(user, vault, "Medical/biopsy scan.png")

      assert_clean(lines, "no storage_key", 1)
    end
  end

  describe "rendered failure reasons" do
    # The shapes review found leaking, driven through the real sink rather than
    # asserted on `safe_reason/1` in isolation.
    test "an exception carrying the body", %{lines: lines} do
      require Logger

      for e <- [
            %RuntimeError{message: @secret},
            %CaseClauseError{term: {:parsed, @secret}},
            %KeyError{key: :missing, term: %{content: @secret}}
          ] do
        Logger.error(
          "operation failed reason=#{Metadata.safe_reason(e)}",
          Metadata.with_category(:error, :sync, path: @path)
        )
      end

      assert_clean(lines, "operation failed", 3)
    end

    test "an ExAws error whose body echoes the storage key", %{lines: lines} do
      require Logger

      key = "u1/v1/#{@path}"

      {:error, reason} =
        ExAws.Request.client_error(
          %{
            status_code: 403,
            body: "<Error><Code>AccessDenied</Code><Key>#{key}</Key></Error>",
            headers: []
          },
          Jason
        )

      Logger.error(
        "storage failed",
        Metadata.with_category(:error, :sync,
          storage_key: key,
          reason: Metadata.safe_reason(reason)
        )
      )

      assert_clean(lines, "storage failed", 1)
    end

    test "a struct handed over as metadata", %{lines: lines} do
      # Only the raw OTP API can do this — `Logger.error/2`'s macro rejects a
      # struct at the call site.
      :logger.log(:error, "probe", %RuntimeError{message: @secret})
      :logger.log(:error, "probe", %URI{path: "/#{@path}", query: "biopsy prognosis"})

      assert_clean(lines, "probe", 2)
    end
  end

  describe "dependency log lines" do
    test "a Req redirect carrying the object URL", %{lines: lines} do
      :logger.log(
        :warning,
        ["redirecting to ", "https://bucket.s3.example.com/u1/v1/#{@path}"],
        %{mfa: {Req.Steps, :redirect, 1}}
      )

      :logger.log(
        :warning,
        "ExAws: HTTP ERROR: :timeout for URL: \"https://b/u1/v1/#{@path}\" ATTEMPT: 3",
        %{mfa: {ExAws.Request, :request_and_retry, 7}}
      )

      assert_clean(lines, "Req.Steps.redirect", 1)
    end

    # A path SPLIT ACROSS ELEMENTS. Every one of these was proven leaking by
    # review against a redaction rule that worked element-wise: element one held
    # the separator and was redacted, element two held none and passed, and the
    # join glued them into `[REDACTED]biopsy.md`. The no-space case was CLEAN
    # before that rule and regressed under it.
    #
    # Nothing Req ships today splits a path this way, which is exactly why it
    # went unnoticed: the shape is one dependency upgrade away, and this filter
    # exists to be right about lines nobody has read yet.
    test "a path split across iodata elements", %{lines: lines} do
      for parts <- [
            ["redirecting to ", "Medical/", "biopsy.md"],
            ["redirecting to ", "Medical/2026 ", "biopsy results.md"],
            ["redirecting to https://b/u1/v1/Medical/2026 ", "biopsy results.md"],
            # A SPACE in the first folder name. Prefix-truncation kept everything
            # before the first separator-bearing token and shipped `Medical` in
            # clear — the folder name IS the disclosure.
            ["redirecting to ", "Medical Records/2026/biopsy.md"]
          ] do
        :logger.log(:warning, parts, %{mfa: {Req.Steps, :redirect, 1}})
      end

      assert_clean(lines, "Req.Steps.redirect", 4)
    end

    # An IMPROPER list is legal iodata and `IO.chardata_to_string/1` accepts it.
    # `Enum.map_join/2` does not — it raises `FunctionClauseError`, which the
    # `catch` arm in `RedactFilter` converts into a blanked line. The node
    # survives either way; the diagnostic does not, so this asserts the prose
    # survives rather than only that the path is gone.
    test "an improper list is not blanked", %{lines: lines} do
      :logger.log(:warning, ["ExAws: retry for Medical/" | "biopsy.md, backing off"], %{
        mfa: {ExAws.Request, :retry, 1}
      })

      assert_clean(lines, "ExAws.Request.retry", 1)
    end

    # `@separators` lists the percent-encoded forms; a rule that enumerated only
    # `[\/\\]` disagreed with it and let this through. Contrived for a real URL
    # — real encoding turns the spaces into `%20` too — but the two lists
    # disagreeing is the enumerate-the-shapes failure this file keeps losing to.
    test "percent-encoded separators and unquoted paths with spaces", %{lines: lines} do
      for url <- [
            "\"b%2Fu1%2FMedical%2F2026 biopsy results.md\"",
            "https://b/u1/v1/Medical/2026 biopsy results.md"
          ] do
        :logger.log(:warning, "ExAws: HTTP ERROR: :timeout for URL: #{url} ATTEMPT: 3", %{
          mfa: {ExAws.Request, :request_and_retry, 7}
        })
      end

      assert_clean(lines, "ExAws.Request.request_and_retry", 2)
    end
  end
end
