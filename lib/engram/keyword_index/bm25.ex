defmodule Engram.KeywordIndex.Bm25 do
  @moduledoc """
  BM25 term-frequency component (saturation + document-length normalization).

  Qdrant supplies the IDF multiplier at query time (`modifier: "idf"`), so we
  store ONLY this TF term as the sparse vector value. Final relevance is then
  `Σ IDF(t) · tf_weight(t)` = BM25. See #595 design doc.

  Defaults: k1 = 1.2 (saturation), b = 0.75 (length normalization).
  """

  @k1 1.2
  @b 0.75

  @doc """
  BM25 TF weight for a term with frequency `tf` in a document of length
  `doc_len`, given corpus `avgdl` (average document length). `avgdl` must be
  positive.

  Options: `:k1`, `:b`.
  """
  @spec tf_weight(non_neg_integer(), non_neg_integer(), float(), keyword()) :: float()
  def tf_weight(tf, doc_len, avgdl, opts \\ [])
      when is_number(tf) and is_number(doc_len) and is_number(avgdl) and avgdl > 0 do
    k1 = Keyword.get(opts, :k1, @k1)
    b = Keyword.get(opts, :b, @b)
    norm = 1 - b + b * doc_len / avgdl
    tf * (k1 + 1) / (tf + k1 * norm)
  end
end
