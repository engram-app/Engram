defmodule Engram.Notes.NoteParseStatusChangesetTest do
  use ExUnit.Case, async: true

  alias Engram.Notes.Note

  test "changeset casts parse_status and parse_reason" do
    cs =
      Note.changeset(%Note{}, %{
        parse_status: "degraded",
        parse_reason: %{"error" => "missing_closing_delimiter"}
      })

    assert Ecto.Changeset.get_change(cs, :parse_status) == "degraded"

    assert Ecto.Changeset.get_change(cs, :parse_reason) == %{
             "error" => "missing_closing_delimiter"
           }
  end

  test "parse_status defaults to ok on a bare struct" do
    assert %Note{}.parse_status == "ok"
  end
end
