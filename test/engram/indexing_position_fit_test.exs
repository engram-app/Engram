defmodule Engram.IndexingPositionFitTest do
  @moduledoc """
  `Indexing.fit_positions/2`: `chunks.position` is a smallint, so a note of
  more chunks than it holds merges to fit.
  """
  use ExUnit.Case, async: true

  alias Engram.Indexing

  # `chunks.position` is a smallint: a note of more than 32,767 chunks (a
  # 30 MB self-host note of tiny sections, CI huge-notes) crashed the row
  # insert on every attempt. Over that the chunks merge to fit, budget or
  # not. Synthetic chunks: parsing that many needs a ~17 MB note.
  test "more than 32,767 chunks merge to fit the position range" do
    [template] = Engram.Parsers.Markdown.parse("# T\n\nbody", "T.md")

    chunks =
      for i <- 0..32_999 do
        text = "section#{i} body"

        %{
          template
          | position: i,
            text: text,
            context_text: "T\n\n" <> text,
            embed_text: "T\n\n" <> text
        }
      end

    fitted = Indexing.fit_positions(chunks, false)
    assert length(fitted) <= 32_767
    assert fitted |> Enum.map(& &1.position) |> Enum.max() < 32_768
    assert Indexing.fit_positions(Enum.take(chunks, 100), false) === Enum.take(chunks, 100)
  end
end
