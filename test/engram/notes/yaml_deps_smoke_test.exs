defmodule Engram.Notes.YamlDepsSmokeTest do
  use ExUnit.Case, async: true

  test "yaml_elixir parses and ymlr emits a round-trippable map" do
    {:ok, parsed} = YamlElixir.read_from_string("title: Hello\ntags:\n  - a\n  - b\n")
    assert parsed == %{"title" => "Hello", "tags" => ["a", "b"]}

    emitted = Ymlr.document!(parsed)
    {:ok, reparsed} = YamlElixir.read_from_string(emitted)
    assert reparsed == parsed
  end
end
