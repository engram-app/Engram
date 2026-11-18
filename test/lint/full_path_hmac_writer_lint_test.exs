defmodule Engram.FullPathHmacWriterLintTest do
  @moduledoc """
  Grep-style lint: `folders.full_path_hmac` is written in ONE place,
  `Engram.Folders.PathHmacs`. Its writer first takes the hash from any other
  live row holding it, so no two live rows share one (0.89.0 nodes key a map
  by it in a mixed window, S6 step 3). A writer anywhere else would skip that
  release, so any write form outside that module fails here: an Ecto
  `full_path_hmac:` keyword (set, insert row, map), raw SQL that assigns it,
  or an `INSERT INTO folders` that lists it.
  """
  use ExUnit.Case, async: true

  alias Engram.Test.SourceLint

  @lib_dir Path.expand("../../lib", __DIR__)
  @owner "engram/folders/path_hmacs.ex"

  # An assignment `full_path_hmac = <value>`: after SET, after a comma, or
  # opening a line of a multi-line SET. A comparison is `==` in Ecto, and in
  # raw SQL follows `AND`/`WHERE`/a table alias (`f.full_path_hmac =`).
  @line_writes [
    ~r/\bfull_path_hmac:\s/,
    ~r/\bSET\b[^;]*\bfull_path_hmac\s*=(?!=)/i,
    ~r/,\s*full_path_hmac\s*=(?!=)/i,
    ~r/^\s*"?\s*full_path_hmac\s*=(?!=)/i,
    # A changeset or map write by atom (`put_change/3`, `Map.put/3`, `cast/3`).
    ~r/\b(put_change|change|cast|Map\.put|Map\.merge)\b.*:full_path_hmac\b/
  ]
  @insert ~r/INSERT\s+INTO\s+folders\s*\([^)]*\bfull_path_hmac\b/is

  test "only Engram.Folders.PathHmacs writes full_path_hmac" do
    files =
      for path <- SourceLint.walk_ex_files(@lib_dir),
          rel = Path.relative_to(path, @lib_dir),
          rel != @owner,
          do: {rel, File.read!(path)}

    lines =
      for {rel, src} <- files,
          {line, n} <- src |> String.split("\n") |> Enum.with_index(1),
          not SourceLint.commented?(line),
          Enum.any?(@line_writes, &Regex.match?(&1, line)),
          do: "#{rel}:#{n}: #{String.trim(line)}"

    inserts =
      for {rel, src} <- files,
          Regex.match?(@insert, src),
          do: "#{rel}: an INSERT INTO folders lists full_path_hmac"

    assert lines ++ inserts == [], Enum.join(lines ++ inserts, "\n")
  end
end
