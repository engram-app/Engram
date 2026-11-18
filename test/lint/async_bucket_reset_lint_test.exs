defmodule Engram.Lint.AsyncBucketResetLintTest do
  # The rate limiter's buckets are one node-global ETS table. An async test
  # that wipes it (`reset_buckets!/1`, `clear_buckets!/0`) erases the buckets
  # of every test running beside it: McpControllerTest's "suggest_folder
  # spends the same budget as search_notes" lost the token `search_notes`
  # had just spent, ran a second search and hit an unstubbed embedder
  # (CI, #2648 @ e995acd44). Async tests key buckets by their own fresh user;
  # to start a burst at a window edge they call `await_fresh_window!/1`.
  use ExUnit.Case, async: true

  test "no async test wipes the global rate-limit buckets" do
    offenders =
      for path <- Path.wildcard("test/**/*_test.exs"),
          src = File.read!(path),
          src =~ ~r/async:\s*true/,
          src =~ ~r/RateLimiter\.(reset_buckets!|clear_buckets!)/,
          do: path

    assert offenders == [], "async tests wiping rate-limit buckets: #{inspect(offenders)}"
  end
end
