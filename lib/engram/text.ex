defmodule Engram.Text do
  @moduledoc """
  String helpers shared by code that writes free text into bounded columns.
  """

  @doc """
  Cuts `value` to at most `max` codepoints. `nil` passes through.

  Codepoints, not graphemes and not bytes: Postgres `varchar(n)` counts
  codepoints, so a grapheme cut can still overflow the column (an "e" plus a
  combining accent is one grapheme, two codepoints), and a byte cut can split a
  multi-byte character into invalid UTF-8. Invalid bytes in the kept prefix are
  replaced with U+FFFD, which Postgres would otherwise reject. Walks only the
  kept prefix, so a multi-megabyte valid input costs `max` steps.
  """
  @spec truncate(String.t() | nil, non_neg_integer()) :: String.t() | nil
  def truncate(nil, _max), do: nil

  def truncate(value, max) when is_binary(value) and is_integer(max) and max >= 0 do
    case cut(value, max, value) do
      :invalid -> truncate(String.replace_invalid(value), max)
      kept -> kept
    end
  end

  defp cut(rest, 0, whole), do: binary_part(whole, 0, byte_size(whole) - byte_size(rest))
  defp cut(<<_::utf8, rest::binary>>, n, whole), do: cut(rest, n - 1, whole)
  defp cut(<<>>, _n, whole), do: whole
  defp cut(_invalid, _n, _whole), do: :invalid
end
