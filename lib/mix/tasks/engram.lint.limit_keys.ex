defmodule Mix.Tasks.Engram.Lint.LimitKeys do
  @shortdoc "Lints Billing.effective_limit/cap/granted?/check_limit/check_feature key args"

  @moduledoc """
  Lints `Engram.Billing.{effective_limit, cap, granted?, check_limit, check_feature}` call sites:
  the key arg must be an atom literal from `Engram.Billing.LimitKeys.all/0`.

  Fails the build on:
  - unknown atom (typo against catalog)
  - string literal (legacy form)
  - dynamic key (variable or function-call result) — unless preceded by
    `# lint:limit_keys allow_dynamic`

  Any violation can also be suppressed with `# lint:limit_keys ignore` on the
  preceding line — useful for negative-path tests that deliberately pass a bad
  key to assert the catalog guard fires.

  Usage: `mix engram.lint.limit_keys`
  """

  use Mix.Task

  alias Engram.Billing.LimitKeys

  @target_funs ~w(effective_limit cap granted? check_limit check_feature)a

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("compile")

    files = Path.wildcard("lib/**/*.ex") ++ Path.wildcard("test/**/*.exs")

    violations =
      files
      |> Enum.flat_map(fn file -> scan_source!(File.read!(file), file) end)

    if violations == [] do
      Mix.shell().info("limit_keys lint: 0 violations across #{length(files)} files")
    else
      Enum.each(violations, fn v -> Mix.shell().error(format(v)) end)
      Mix.raise("limit_keys lint: #{length(violations)} violation(s)")
    end
  end

  @doc """
  Scans a single source string and returns a list of violation tuples.

  Each tuple: `{file, line, function_atom, kind, value}` where kind is one of
  `:unknown_atom`, `:string_key`, `:dynamic_key`.
  """
  def scan_source!(src, file) do
    tree = Code.string_to_quoted!(src, columns: true, file: file)
    lines = String.split(src, "\n")

    {_, acc} =
      Macro.prewalk(tree, [], fn
        # Engram.Billing.<fun>(_, key, ...)
        {{:., _, [{:__aliases__, _, [:Engram, :Billing]}, fun]}, meta, args} = node, acc
        when fun in @target_funs ->
          {node, check_args(file, meta, fun, args, lines) ++ acc}

        # Billing.<fun>(_, key, ...)
        {{:., _, [{:__aliases__, _, [:Billing]}, fun]}, meta, args} = node, acc
        when fun in @target_funs ->
          {node, check_args(file, meta, fun, args, lines) ++ acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # `Code.string_to_quoted!/2` does not expand `|>`, so the key's position
  # depends on the spelling: `Billing.check_limit(user, :notes_cap, n)` puts it
  # second, `user |> Billing.check_limit(:notes_cap, n)` puts it first. Rather
  # than re-implement pipe expansion, treat a call as clean when EITHER of the
  # first two arguments is a catalog key — no gate takes a catalog key in
  # either position for any other purpose, so this cannot pass a real typo.
  #
  # This used to be a `[_user, key | _rest]` head plus a catch-all commented
  # "arity mismatch — ignore", which silently skipped every piped call site:
  # a typo'd key in that shape was unlinted, the one thing this task exists to
  # catch.
  defp check_args(file, meta, fun, args, lines) when is_list(args) and args != [] do
    line = meta[:line]
    candidates = Enum.take(args, 2)

    cond do
      ignore?(lines, line) ->
        []

      Enum.any?(candidates, &(is_atom(&1) and LimitKeys.defined?(&1))) ->
        []

      true ->
        classify(file, line, fun, key_arg(args), lines)
    end
  end

  defp check_args(_file, _meta, _fun, _args, _lines), do: []

  # No candidate was a valid key, so one of them is the offender. Prefer the
  # unpiped position; a piped 3-arity call with a bad key reports against the
  # wrong argument, but it still FAILS, which is the safe direction.
  defp key_arg([_user, key | _rest]), do: key
  defp key_arg([key]), do: key

  defp classify(file, line, fun, key, lines) do
    cond do
      is_atom(key) -> [{file, line, fun, :unknown_atom, key}]
      is_binary(key) -> [{file, line, fun, :string_key, key}]
      allow_dynamic?(lines, line) -> []
      true -> [{file, line, fun, :dynamic_key, Macro.to_string(key)}]
    end
  end

  defp allow_dynamic?(lines, line),
    do: prev_line_matches?(lines, line, ~r/#\s*lint:limit_keys\s+allow_dynamic/)

  defp ignore?(lines, line), do: prev_line_matches?(lines, line, ~r/#\s*lint:limit_keys\s+ignore/)

  defp prev_line_matches?(lines, line, regex) do
    case Enum.at(lines, line - 2) do
      nil -> false
      prev -> prev =~ regex
    end
  end

  defp format({file, line, fun, kind, value}) do
    "#{file}:#{line}: Billing.#{fun}/_ — #{kind_msg(kind, value)}"
  end

  defp kind_msg(:unknown_atom, key), do: "key #{inspect(key)} not in LimitKeys catalog"
  defp kind_msg(:string_key, key), do: "string key #{inspect(key)} — use atom :#{key}"

  defp kind_msg(:dynamic_key, _),
    do: "dynamic key not allowed (add `# lint:limit_keys allow_dynamic` on preceding line)"
end
