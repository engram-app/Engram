defmodule Engram.FileTimeFixtures do
  @moduledoc """
  Real prod `notes.mtime` values (2026-11) with the microsecond
  `Engram.FileTime.to_at/1` must store for each. Desktop Obsidian's
  `stat.mtimeMs` carries sub-millisecond digits, which the plugin divides
  by 1000. Five of them floored 1 us low on 0.74 and 0.75.
  """

  @doc "`[{double, microsecond}]`."
  def prod_desktop_times do
    [
      {1_792_507_938.5950112, 595_011},
      {1_792_374_456.8065336, 806_534},
      {1_792_355_282.670638, 670_638},
      {1_793_463_598.414629, 414_629},
      {1_792_348_622.2113965, 211_397},
      {1_793_434_092.091588, 91_588},
      {1_792_744_305.7469757, 746_976},
      {1_793_152_317.489393, 489_393},
      {1_793_392_404.6805549, 680_555},
      {1_792_152_782.1053593, 105_359},
      {1_793_152_881.2996936, 299_694},
      {1_793_504_975.8445764, 844_576}
    ]
  end

  @doc "The twin `t` must have: its second, at microsecond `us`."
  def rounded_twin({t, us}),
    do: DateTime.from_unix!(trunc(t) * 1_000_000 + us, :microsecond)
end
