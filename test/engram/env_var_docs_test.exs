defmodule Engram.EnvVarDocsTest do
  use ExUnit.Case, async: true

  @runtime_config "config/runtime.exs"
  @context_doc "docs/context/environment-variables.md"

  # The context doc was regenerated from runtime.exs once (2026-06-18) and
  # hand-patched afterwards, so every var added after that date landed in
  # runtime.exs and never reached the table — 12 of them by the time anyone
  # looked. This asserts the gap can't reopen.
  #
  # Deliberately one-directional. The doc legitimately lists vars that
  # runtime.exs never names: DATABASE_SSL (read via RuntimeConfig helpers),
  # AWS_* (Crypto.Config), OLLAMA_URL (the embedder adapter), RELEASE_COOKIE
  # (rel/env.sh.eex), plus removed-var history and ENGRAM_<TIER>_<KEY>, whose
  # real names are interpolated from LimitKeys at boot.
  test "every env var read by runtime.exs has a row in the context doc" do
    # Only the Variable column of a table row counts. A name mentioned in some
    # other row's Purpose cell ("keep > `EMBED_SETTLE_SECONDS`") is a
    # cross-reference, not a definition, and must not satisfy this guard.
    # Scans every backticked name in that one cell, so shared rows like
    # `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` cover both.
    documented =
      @context_doc
      |> File.stream!()
      |> Stream.filter(&String.starts_with?(&1, "|"))
      |> Stream.map(&(&1 |> String.split("|") |> Enum.at(1, "")))
      |> Stream.flat_map(&Regex.scan(~r/`([A-Z][A-Z0-9_]+)`/, &1, capture: :all_but_first))
      |> Stream.concat()
      |> MapSet.new()

    undocumented =
      @runtime_config
      |> File.stream!()
      # Skip comments so a commented-out example can't fail the build.
      |> Stream.reject(&String.starts_with?(String.trim_leading(&1), "#"))
      |> Stream.flat_map(
        &Regex.scan(~r/System\.(?:get_env|fetch_env!?)\("([A-Z][A-Z0-9_]*)"/, &1,
          capture: :all_but_first
        )
      )
      |> Stream.concat()
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(documented, &1))
      |> Enum.sort()

    assert undocumented == [],
           "#{@runtime_config} reads env vars with no row in #{@context_doc}: " <>
             Enum.join(undocumented, ", ") <>
             ".\nAdd a `| VAR | default | purpose |` row to the matching section — " <>
             "the doc is what operators read, so an undocumented knob is an unusable one."
  end
end
