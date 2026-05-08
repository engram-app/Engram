defmodule EngramWeb.NoUserStructLeakTest do
  # T3.0.6 — Static source lint. The User schema redacts key fields and
  # the Jason.Encoder is allowlist-only (T3.0.5), but we still ban risky
  # patterns at file scope so a future PR can never accidentally land:
  #
  #   * `json(conn, %{user: user})` — relies on the allowlist holding;
  #     one accidental `@derive {Jason.Encoder, except: [...]}` flip would
  #     leak the wrapped DEK to clients.
  #   * `json(conn, user)`           — same, plus implicit struct serialization.
  #   * `inspect(user)`              — relies on `redact: true` holding.
  #
  # Forcing explicit field projection (`%{id: user.id, email: user.email, ...}`)
  # is one CR comment away from any reviewer. This lint catches it at PR-CI.
  use ExUnit.Case, async: true

  @lib_dir Path.join(File.cwd!(), "lib")

  @forbidden [
    {~r/json\(\s*conn\s*,\s*%\{\s*user:\s*user\b/, "json(conn, %{user: user})"},
    {~r/json\(\s*conn\s*,\s*user\s*\)/, "json(conn, user)"},
    {~r/\binspect\(\s*user\s*\)/, "inspect(user)"}
  ]

  describe "regex sanity (TDD: prove the lint catches what it should)" do
    test "matches `json(conn, %{user: user})`" do
      [{regex, _}] = Enum.filter(@forbidden, fn {_, l} -> l == "json(conn, %{user: user})" end)
      assert Regex.match?(regex, "    json(conn, %{user: user})")
      assert Regex.match?(regex, "json(conn, %{user: user, extra: 1})")
      refute Regex.match?(regex, "json(conn, %{id: user.id, email: user.email})")
    end

    test "matches `json(conn, user)`" do
      [{regex, _}] = Enum.filter(@forbidden, fn {_, l} -> l == "json(conn, user)" end)
      assert Regex.match?(regex, "json(conn, user)")
      refute Regex.match?(regex, "json(conn, user_payload)")
      refute Regex.match?(regex, "json(conn, %{user: user})")
    end

    test "matches `inspect(user)`" do
      [{regex, _}] = Enum.filter(@forbidden, fn {_, l} -> l == "inspect(user)" end)
      assert Regex.match?(regex, ~S|Logger.error("...#{inspect(user)}")|)
      assert Regex.match?(regex, "inspect(user)")
      refute Regex.match?(regex, "inspect(user_id)")
      refute Regex.match?(regex, "inspect(user_payload)")
    end
  end

  test "no lib/ source contains banned user-struct leak patterns" do
    offenders =
      @lib_dir
      |> walk_ex_files()
      |> Enum.flat_map(&scan_file/1)

    assert offenders == [],
           "Found banned user-struct leak patterns in lib/:\n" <>
             Enum.map_join(offenders, "\n", fn {file, line, label, snippet} ->
               "  #{Path.relative_to_cwd(file)}:#{line}  [#{label}]  #{snippet}"
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
    lines = path |> File.read!() |> String.split("\n") |> Enum.with_index(1)

    for {line, i} <- lines,
        not commented?(line),
        {regex, label} <- @forbidden,
        Regex.match?(regex, line) do
      {path, i, label, String.trim(line)}
    end
  end

  # Skip lines that start with `#` so the docstring/comment in the User
  # schema referencing the banned patterns does not self-trip the lint.
  defp commented?(line), do: Regex.match?(~r/^\s*#/, line)
end
