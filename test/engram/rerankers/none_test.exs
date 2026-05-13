defmodule Engram.Rerankers.NoneTest do
  use ExUnit.Case, async: true

  describe "rerank/3" do
    test "returns candidates sorted by score, limited to top_n" do
      candidates = [
        %{score: 0.5, text: "C"},
        %{score: 0.9, text: "A"},
        %{score: 0.7, text: "B"}
      ]

      assert {:ok, results} = None.rerank("query", candidates, 2)
      assert length(results) == 2
      assert hd(results).text == "A"
    end

    test "handles empty candidates" do
      assert {:ok, []} = None.rerank("query", [], 5)
    end
  end
end
