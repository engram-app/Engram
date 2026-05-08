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
  # Variants matter: real call sites bind users as `current_user`,
  # `target_user`, etc. The regex set covers all common bindings.
  use ExUnit.Case, async: true

  alias Engram.Test.SourceLint

  @lib_dir Path.join(File.cwd!(), "lib")

  # Match any binding that ends in `user` (user, current_user, target_user,
  # other_user, etc.) but not unrelated bindings like `user_id` or
  # `user_payload`. The trailing word boundary + `\b` after the suffix
  # prevents false positives.
  @user_binding ~S"(?:[a-z_]+_)?user"

  @forbidden [
    {~r/json\(\s*conn\s*,\s*%\{\s*user:\s*#{@user_binding}\b/,
     "json(conn, %{user: <user-binding>})"},
    {~r/json\(\s*conn\s*,\s*#{@user_binding}\s*\)/, "json(conn, <user-binding>)"},
    {~r/\binspect\(\s*#{@user_binding}\s*\)/, "inspect(<user-binding>)"}
  ]

  describe "regex sanity (TDD: prove the lint catches what it should)" do
    test "matches `json(conn, %{user: ...})` with various bindings" do
      [{regex, _}] = pick("json(conn, %{user: <user-binding>})")
      assert Regex.match?(regex, "    json(conn, %{user: user})")
      assert Regex.match?(regex, "json(conn, %{user: current_user, extra: 1})")
      assert Regex.match?(regex, "json(conn, %{user: target_user})")
      refute Regex.match?(regex, "json(conn, %{id: user.id, email: user.email})")
    end

    test "matches bare `json(conn, <user-binding>)`" do
      [{regex, _}] = pick("json(conn, <user-binding>)")
      assert Regex.match?(regex, "json(conn, user)")
      assert Regex.match?(regex, "json(conn, current_user)")
      assert Regex.match?(regex, "json(conn, target_user)")
      refute Regex.match?(regex, "json(conn, user_payload)")
      refute Regex.match?(regex, "json(conn, user_id)")
      refute Regex.match?(regex, "json(conn, %{user: user})")
    end

    test "matches `inspect(<user-binding>)`" do
      [{regex, _}] = pick("inspect(<user-binding>)")
      assert Regex.match?(regex, ~S|Logger.error("...#{inspect(user)}")|)
      assert Regex.match?(regex, "inspect(user)")
      assert Regex.match?(regex, "inspect(current_user)")
      refute Regex.match?(regex, "inspect(user_id)")
      refute Regex.match?(regex, "inspect(user_payload)")
    end

    defp pick(label), do: Enum.filter(@forbidden, fn {_, l} -> l == label end)
  end

  test "no lib/ source contains banned user-struct leak patterns" do
    offenders =
      @lib_dir
      |> SourceLint.walk_ex_files()
      |> Enum.flat_map(&scan_file/1)

    assert offenders == [],
           "Found banned user-struct leak patterns in lib/:\n" <>
             Enum.map_join(offenders, "\n", fn {file, line, label, snippet} ->
               "  #{Path.relative_to_cwd(file)}:#{line}  [#{label}]  #{snippet}"
             end)
  end

  defp scan_file(path) do
    lines = path |> File.read!() |> String.split("\n") |> Enum.with_index(1)

    for {line, i} <- lines,
        not SourceLint.commented?(line),
        {regex, label} <- @forbidden,
        Regex.match?(regex, line) do
      {path, i, label, String.trim(line)}
    end
  end
end
