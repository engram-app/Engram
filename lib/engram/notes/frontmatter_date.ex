defmodule Engram.Notes.FrontmatterDate do
  @moduledoc """
  Date parsing for the v5 flat frontmatter fields (spec 3.3b). Accepts what
  Obsidian writes as well as ISO 8601: `YYYY-MM-DD`, and
  `YYYY-MM-DD[T| ]HH:MM[:SS[.frac]]` with or without `Z` / `+HH:MM`.

  Returns `{unix_seconds, written_date}`. The instant converts an offset to
  UTC and reads a time with no offset as UTC. The date is the day as WRITTEN
  (the local date part, before any conversion), which is what date-only
  fields (`due`, `expires`) mean: `2026-11-01T23:00-08:00` is due Nov 1.

  `:strict` (the nested OKF aliases) needs a time and an offset; `:lenient`
  also takes a bare date (midnight UTC) and a time without an offset.
  """

  @epoch ~D[1970-01-01]

  @spec parse(term(), :strict | :lenient) :: {integer(), Date.t()} | nil
  def parse(<<date::binary-size(10)>>, :lenient) do
    with {:ok, d} <- Date.from_iso8601(date),
         do: {DateTime.to_unix(DateTime.new!(d, ~T[00:00:00], "Etc/UTC")), d},
         else: (_ -> nil)
  end

  def parse(<<date::binary-size(10), sep, rest::binary>>, mode) when sep in [?T, ?\s] do
    {time, offset} = split_offset(rest)

    with {:ok, d} <- Date.from_iso8601(date),
         {:ok, t} <- Time.from_iso8601(seconds(time)),
         {:ok, shift} <- offset_seconds(offset, mode) do
      naive = NaiveDateTime.new!(d, t)
      unix = naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
      {unix - shift, d}
    else
      _ -> nil
    end
  end

  def parse(_value, _mode), do: nil

  @doc "Days since 1970-01-01."
  @spec day(Date.t()) :: integer()
  def day(%Date{} = d), do: Date.diff(d, @epoch)

  # `HH:MM` gains `:00`; anything longer is left to Time.from_iso8601.
  defp seconds(<<_hm::binary-size(5)>> = t), do: t <> ":00"
  defp seconds(t), do: t

  defp split_offset(rest) do
    cond do
      String.ends_with?(rest, "Z") ->
        {String.trim_trailing(rest, "Z"), "Z"}

      match = Regex.run(~r/^(.*)([+-]\d{2}:?\d{2})$/, rest) ->
        {Enum.at(match, 1), Enum.at(match, 2)}

      true ->
        {rest, nil}
    end
  end

  defp offset_seconds(nil, :strict), do: :error
  defp offset_seconds(nil, :lenient), do: {:ok, 0}
  defp offset_seconds("Z", _mode), do: {:ok, 0}

  defp offset_seconds(<<sign, h::binary-size(2), rest::binary>>, _mode) do
    m = String.trim_leading(rest, ":")

    with {hh, ""} <- Integer.parse(h),
         {mm, ""} <- Integer.parse(m),
         true <- hh < 24 and mm < 60 do
      secs = hh * 3600 + mm * 60
      {:ok, if(sign == ?-, do: -secs, else: secs)}
    else
      _ -> :error
    end
  end
end
