defmodule Engram.Lint.AsyncBucketResetLintTest do
  # The rate limiter's buckets are one node-global ETS table. An async test
  # that wipes it erases the buckets of every test running beside it:
  # McpControllerTest's "suggest_folder spends the same budget as
  # search_notes" lost the token `search_notes` had just spent, ran a second
  # search and hit an unstubbed embedder (CI, #2648 @ e995acd44). Async tests
  # key buckets by their own fresh user; to start a burst at a window edge
  # they call `RateLimiter.await_fresh_window!/1`.
  #
  # Textual, not an AST walk: any call named `reset_buckets!` /
  # `clear_buckets!` whatever its module (an alias, an `import`), any
  # `:ets.delete_all_objects` on a limiter table, and any test/support
  # function that does one of those (a wrapper) called by name.
  use ExUnit.Case, async: true

  @wipe ~r/\b(reset_buckets!|clear_buckets!)\s*\(|:ets\.delete_all_objects\(\s*EngramWeb\.RateLimiter/

  test "no async test wipes the global rate-limit buckets" do
    wrappers = support_wrappers()

    offenders =
      for path <- Path.wildcard("test/**/*_test.exs"),
          path != __ENV__.file |> Path.relative_to_cwd(),
          src = File.read!(path),
          src =~ ~r/async:\s*true/,
          src =~ @wipe or Enum.any?(wrappers, &(src =~ ~r/\b#{Regex.escape(&1)}\s*\(/)),
          do: path

    assert offenders == [], "async tests wiping rate-limit buckets: #{inspect(offenders)}"
  end

  test "the lint sees an aliased call, an import, a raw table wipe and a wrapper" do
    assert "RL.reset_buckets!()" =~ @wipe
    assert "clear_buckets!()" =~ @wipe
    assert ":ets.delete_all_objects(EngramWeb.RateLimiter.ETS)" =~ @wipe
    refute "RateLimiter.await_fresh_window!()" =~ @wipe
    assert "reset_rebuild_gate" in support_wrappers()
  end

  # Names of test/support functions whose body wipes the buckets.
  defp support_wrappers do
    for path <- Path.wildcard("test/support/**/*.ex"),
        chunk <- path |> File.read!() |> String.split(~r/\n\s*defp?\s+/),
        chunk =~ @wipe,
        [_, name] <- [Regex.run(~r/\A([a-z_][a-zA-Z0-9_]*[!?]?)/, chunk)],
        name not in ~w(reset_buckets! clear_buckets!),
        uniq: true,
        do: name
  end
end
