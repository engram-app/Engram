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

  # .env.example IS the self-host quickstart — `cp .env.example .env && docker
  # compose up -d` is the documented path — so a knob left there after being
  # renamed or removed silently does nothing, and the operator has no way to
  # tell. That file has already shipped wrong content once (it set
  # ENGRAM_DEFAULT_REGISTRATION_MODE=open while its own comment claimed
  # invite_only, producing an open-signup instance).
  #
  # This checks EXISTENCE, not values. A test cannot know the right default for
  # a knob, so the wrong-value class above stays a human review problem; what it
  # can do is prove every name still resolves to something real.
  @build_time_vars ~w(SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_PROJECT)
  test "every var in .env.example is actually read somewhere" do
    read_at_runtime =
      @runtime_config
      |> File.stream!()
      |> Stream.reject(&String.starts_with?(String.trim_leading(&1), "#"))
      |> Stream.flat_map(
        &Regex.scan(~r/System\.(?:get_env|fetch_env!?)\("([A-Z][A-Z0-9_]*)"/, &1,
          capture: :all_but_first
        )
      )
      |> Stream.concat()
      |> MapSet.new()

    orphaned =
      ".env.example"
      |> File.stream!()
      |> Stream.flat_map(&Regex.scan(~r/^#?\s*([A-Z][A-Z0-9_]+)=/, &1, capture: :all_but_first))
      |> Stream.concat()
      |> Enum.uniq()
      # Keep only names nothing accounts for. VITE_* are consumed by the
      # frontend build, not the Elixir runtime, and the three SENTRY_* by the CI
      # source-map upload — a prefix rule rather than a name list, so adding a
      # frontend var needs no edit here.
      |> Enum.reject(
        &(String.starts_with?(&1, "VITE_") or &1 in @build_time_vars or
            MapSet.member?(read_at_runtime, &1))
      )
      |> Enum.sort()

    assert orphaned == [],
           ".env.example offers vars nothing reads: " <>
             Enum.join(orphaned, ", ") <>
             ".\nEither the knob was renamed/removed (drop it from .env.example) or it is " <>
             "consumed outside runtime.exs (add it to @build_time_vars with a reason)."
  end
end
