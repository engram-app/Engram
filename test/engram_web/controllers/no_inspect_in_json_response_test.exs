defmodule EngramWeb.NoInspectInJsonResponseTest do
  # T3.0.1 — Static source lint. `inspect(struct)` interpolated into a
  # `json(conn, ...)` body can leak ciphertext, virtual decrypted fields,
  # or struct internals to clients. Forbid the pattern at file scope so
  # any future controller cannot regress.
  use ExUnit.Case, async: true

  @controllers_dir Path.join([File.cwd!(), "lib/engram_web/controllers"])

  test "no controller emits `inspect(...)` inside a `json(` call" do
    offenders =
      @controllers_dir
      |> walk_ex_files()
      |> Enum.flat_map(&scan_file/1)

    assert offenders == [],
           "Found `inspect(...)` inside `json(` calls — leaks struct internals to clients:\n" <>
             Enum.map_join(offenders, "\n", fn {file, line, snippet} ->
               "  #{Path.relative_to_cwd(file)}:#{line}  #{snippet}"
             end)
  end

  defp walk_ex_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      cond do
        File.dir?(path) -> walk_ex_files(path)
        String.ends_with?(entry, ".ex") -> [path]
        true -> []
      end
    end)
  end

  defp scan_file(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _i} ->
      # Anything matching `json(...inspect(...)...)` on the same source line.
      Regex.match?(~r/json\([^)]*inspect\(/, line)
    end)
    |> Enum.map(fn {line, i} -> {path, i, String.trim(line)} end)
  end
end
