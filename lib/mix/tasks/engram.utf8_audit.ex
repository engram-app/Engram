defmodule Mix.Tasks.Engram.Utf8Audit do
  @shortdoc "Count (and with --fix, repair) note rows with invalid UTF-8 at rest (#739)"

  @moduledoc """
  #739 backfill — scan every note for invalid UTF-8 at rest. Note content is
  AES-GCM ciphertext over a `bytea` column, which bypasses Postgres's UTF-8
  validation, so rows written before the #727/#740 write-time scrub can hold
  invalid bytes (a multibyte char truncated to its lead byte). Every egress now
  scrubs, so this is no longer crash-critical — but the bad bytes persist until
  the row is rewritten.

  Default is a READ-ONLY count (safe to run anytime):

      mix engram.utf8_audit

  Pass `--fix` to rewrite each corrupt note through the normal write path
  (scrub + re-encrypt + recompute hash + re-embed), making it valid at rest:

      mix engram.utf8_audit --fix

  In a RELEASE, `Mix` is not loaded — call the function directly via rpc:

      docker exec engram-saas /app/bin/engram rpc \\
        'Engram.Notes.Utf8Backfill.scan(fix: false) |> IO.inspect()'
  """

  use Mix.Task

  alias Engram.Notes.Utf8Backfill

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [fix: :boolean])
    fix? = Keyword.get(opts, :fix, false)

    Mix.Task.run("app.start")

    IO.puts(
      if(fix?,
        do: "Scanning + repairing invalid UTF-8 at rest...",
        else: "Scanning for invalid UTF-8 at rest (read-only)..."
      )
    )

    %{scanned: scanned, corrupt: corrupt, fixed: fixed} = Utf8Backfill.scan(fix: fix?)

    IO.puts("scanned=#{scanned} corrupt=#{corrupt} fixed=#{fixed}")

    cond do
      corrupt == 0 -> IO.puts("clean — no invalid UTF-8 at rest")
      fix? -> IO.puts("repaired #{fixed}/#{corrupt} corrupt rows")
      true -> IO.puts("#{corrupt} corrupt rows — re-run with --fix to repair")
    end
  end
end
