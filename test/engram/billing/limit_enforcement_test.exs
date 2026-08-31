defmodule Engram.Billing.LimitEnforcementTest do
  @moduledoc """
  Guards against advertising a limit we only enforce in the client.

  Every `LimitKeys` key whose Free default is restrictive must have a real
  `Engram.Billing` call site in `lib/`. Keys that are deliberately
  display-only go in `@unenforced` with a reason.

  This replaces `mix engram.lint.no_client_only_rate_limits`, whose whole
  coverage check was this same scan — the task's own test reimplemented it
  verbatim, so the task was 180 lines of duplicate plus a CI step. Its other
  half scanned for a `# client-only-rate-limit` comment marker that no source
  file has ever carried.

  ## Why this walks the AST instead of grepping

  The original version asserted `String.contains?(blob, ":\#{key}")` — the key
  merely had to APPEAR anywhere in `lib/`, in any context. That is how the
  MCP search-cap bypass survived: `:external_ai_searches_per_day` appeared in
  `EngramWeb.Plugs.EnforceSearchCap`, which was guarded on
  `request_path: "/api/search"` and therefore never ran for the MCP transport.
  A mention in a moduledoc, a `@unenforced` reason string, or a call site that
  no request can reach all satisfied the old check equally.

  Requiring a real `Billing.{effective_limit, check_limit, check_feature,
  limit_enforced?}` call with the key as an atom literal raises the floor from
  "the string exists" to "a gate exists". It still cannot prove the gate is
  REACHABLE — only a test that drives the actual route or worker does that
  (see `EngramWeb.McpControllerTest`, `Engram.Workers.InactivityCleanupTest`,
  `Engram.Accounts.ExportTest`). Treat this as the cheap backstop, not the
  proof.
  """
  use ExUnit.Case, async: true

  alias Engram.Billing.LimitKeys

  # Functions whose second argument is the limit key. Mirrors
  # `Mix.Tasks.Engram.Lint.LimitKeys`'s target list plus `limit_enforced?/2`,
  # which is a legitimate half of a gate (it reorders the expensive count).
  @gate_funs ~w(effective_limit check_limit check_feature limit_enforced?)a

  # Deliberately not enforced server-side. EMPTY, and worth keeping that way.
  #
  # Both former entries were stale rather than deliberate. `cross_vault_search`
  # sat here as "legacy UX flag; no per-request gate point yet" long after
  # `Engram.Search.cross_vault_allowed/2` started gating it.
  # `vault_scoped_keys` was a dead catalog entry superseded by the
  # `api_key_vaults` table, carrying no gate and no client — deleted outright in
  # the pricing-v2 contract step rather than left exempt.
  #
  # An @unenforced entry that outlives its reason is worse than no entry: it
  # tells the next reader not to look. The second test below now guards that.
  @unenforced %{}

  test "every Free-restrictive limit key has a real Billing gate call in lib/" do
    gated = gated_keys()

    missing =
      Enum.reject(LimitKeys.all(), fn key ->
        LimitKeys.default_for(key, :free) in [nil, true] or
          Map.has_key?(@unenforced, key) or
          MapSet.member?(gated, key)
      end)

    assert missing == [],
           """
           These Free-restrictive limit keys have no Billing gate call in lib/:

             #{Enum.map_join(missing, "\n  ", &":#{&1}")}

           Add a Billing.{check_limit, check_feature, effective_limit,
           limit_enforced?} call site taking the key as an atom literal, or add
           the key to @unenforced with a reason.
           """
  end

  test "@unenforced does not list a key that is in fact gated" do
    gated = gated_keys()

    stale =
      @unenforced
      |> Map.keys()
      |> Enum.filter(&MapSet.member?(gated, &1))

    assert stale == [],
           """
           These keys are listed in @unenforced but DO have a Billing gate call:

             #{Enum.map_join(stale, "\n  ", &":#{&1}")}

           Remove them. A stale exemption hides the very gap this file exists
           to surface, and tells the next reader the key is unenforced when it
           is not.
           """
  end

  # Collects every limit key passed as an atom literal to a Billing gate
  # function anywhere in `lib/`. Excludes the catalog itself, whose moduledoc
  # carries `:notes_cap` in usage examples, and `lib/mix/tasks/`, whose lint
  # tasks quote catalog keys in their docs.
  defp gated_keys do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(fn f ->
      String.contains?(f, "lib/mix/tasks/") or String.contains?(f, "billing/limit_keys.ex")
    end)
    |> Enum.flat_map(&keys_in_file/1)
    |> MapSet.new()
  end

  defp keys_in_file(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(file: path)
    |> Macro.prewalk([], fn node, acc -> {node, collect_key(node) ++ acc} end)
    |> elem(1)
  end

  # `Engram.Billing.fun(_, :key, ...)` and bare `Billing.fun(_, :key, ...)` /
  # `fun(_, :key, ...)` — the codebase aliases `Engram.Billing` at most call
  # sites and calls some gates unqualified from inside `Engram.Billing` itself.
  #
  # Position 1 is checked as well as position 2 because `Code.string_to_quoted!`
  # does not expand `|>`: `user |> Billing.effective_limit(:notes_cap)` parses
  # as a call whose only argument is the key. Matching on "an argument in the
  # first two positions is a known catalog key" covers both spellings without
  # re-implementing pipe expansion, and cannot false-positive — no gate takes a
  # catalog key in either position for any other purpose.
  defp collect_key({{:., _, [_mod, fun]}, _, args}) when fun in @gate_funs,
    do: catalog_keys(args)

  defp collect_key({fun, _, args}) when fun in @gate_funs and is_list(args),
    do: catalog_keys(args)

  defp collect_key(_), do: []

  defp catalog_keys(args) do
    args
    |> Enum.take(2)
    |> Enum.filter(&(is_atom(&1) and LimitKeys.defined?(&1)))
  end
end
