defmodule Engram.Text do
  @moduledoc """
  String helpers shared by code that writes free text into bounded columns.
  """

  @doc """
  Cuts `value` to at most `max` codepoints.

  Codepoints, not graphemes and not bytes: Postgres `varchar(n)` counts
  codepoints, so a grapheme cut can still overflow the column (an "e" plus a
  combining accent is one grapheme, two codepoints), and a byte cut can split a
  multi-byte character into invalid UTF-8. Walks only the kept prefix, so a
  multi-megabyte input costs `max` steps.
  """
  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  def truncate(value, max) when is_binary(value) and is_integer(max) and max >= 0,
    do: cut(value, max, value)

  defp cut(rest, 0, whole), do: binary_part(whole, 0, byte_size(whole) - byte_size(rest))
  defp cut(<<_::utf8, rest::binary>>, n, whole), do: cut(rest, n - 1, whole)
  # A byte that is not valid UTF-8 counts as one; the input was already invalid.
  defp cut(<<_, rest::binary>>, n, whole), do: cut(rest, n - 1, whole)
  defp cut(<<>>, _n, whole), do: whole
end
