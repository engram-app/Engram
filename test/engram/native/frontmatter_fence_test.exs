defmodule Engram.Native.FrontmatterFenceTest do
  use ExUnit.Case, async: true

  alias Engram.Links.Parser
  alias Engram.Native
  alias Engram.Notes.Frontmatter

  # The one fence rule (native/engram_core/src/frontmatter.rs), from the
  # table its Rust tests and the web vitest also assert. Every consumer here
  # must agree with it: the split, title/tags and links. The read-only
  # derivations skip a leading BOM first, as the chunker does.
  @cases "native/engram_core/fixtures/frontmatter_fence.json"
         |> File.read!()
         |> Jason.decode!(keys: :atoms)

  @bom "﻿"

  test "Frontmatter.split/1 follows the shared table" do
    for %{name: name, input: input, block: block, body: body} <- @cases do
      assert Frontmatter.split(input) == {block, body}, name
    end
  end

  # Each case that holds `title: T` and `[[In]]` puts them in the block when
  # there is one, so the title is T exactly when a block was found, and the
  # link counts exactly when none was. One test per case, so a red run names
  # every case that differs.
  for %{name: name, input: input} <- @cases, String.contains?(input, "title: T") do
    test "title, tags and links use the same fence: #{name}" do
      input = unquote(input)
      {block, _} = input |> String.trim_leading(@bom) |> Frontmatter.split()
      {title, _tags} = Native.note_meta(input)
      assert title == "T" == (block != nil), "title #{inspect(title)}"

      linked = Enum.any?(Parser.extract(input), &(&1.target == "In"))
      assert linked == (block == nil), "link #{if linked, do: "kept", else: "dropped"}"
    end
  end
end
