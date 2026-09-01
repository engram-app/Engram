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
  # `cap/2` and `granted?/2` are the decoded forms of `effective_limit/2` and
  # `check_feature/2`; a key reached only through them is still gated.
  @gate_funs ~w(effective_limit cap granted? check_limit check_feature limit_enforced?)a

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
  # tells the next reader not to look.
  #
  # The second test below catches ONE direction of that: an entry that is also
  # gated. It cannot catch the other — adding an UNGATED key here to silence a
  # real gap is indistinguishable from a legitimate exemption, which is what
  # this list is for. That is a review question, not a test one. While the map
  # is empty the second test is vacuous by construction; it earns its keep the
  # moment anything is added.
  @unenforced %{}

  # Keys whose enforcement point IS a transport, so a web-layer-only gate is
  # correct rather than a gap. Everything else must be gated under a context or
  # worker, where every transport routes through it.
  #
  # `api_write_enabled` / `api_rps_cap` describe API-KEY traffic specifically:
  # both gates exempt any request without `:current_api_key` by design (pricing
  # decision 2026-08-24), so there is no context-level operation to hang them
  # on. The four connection/device keys gate the single endpoint that mints a
  # connection — OAuth consent and device-flow authorize — which no other
  # transport can reach.
  @transport_scoped ~w(
    api_write_enabled
    api_rps_cap
    concurrent_devices
    device_swap_cooldown_hours
    obsidian_connections_cap
    mcp_connections_cap
  )a

  setup_all do
    # One `Path.wildcard` + `Code.string_to_quoted!` + `Macro.prewalk` over all
    # of `lib/`, shared by every test rather than paid once each.
    sites = gate_sites()
    %{gated: sites |> Map.keys() |> MapSet.new(), sites: sites}
  end

  test "every Free-restrictive limit key has a real Billing gate call in lib/", %{gated: gated} do
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

  test "@unenforced does not list a key that is in fact gated", %{gated: gated} do
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

  test "a cross-transport limit is gated under a context, not only in the web layer", %{
    sites: sites
  } do
    # The recurring bug class in this codebase: the gate lives in the entry
    # point one transport happens to use, so every other transport reaching the
    # SAME operation is ungated. `external_ai_searches_per_day` lived in a plug
    # guarded on `request_path: "/api/search"` and missed all of MCP (#1527).
    # `attachments_enabled` lived in `AttachmentsController.rename/2` while the
    # MCP `move_attachment` tool called the same
    # `Engram.Attachments.move_attachment/4` ungated.
    #
    # `lib/engram_web/` is plugs, controllers and channels — all transport. A
    # key gated ONLY there is gated for whoever knocks on that door and nobody
    # else. See `docs/context/mcp-bypasses-path-shaped-plugs.md`.
    web_only =
      sites
      |> Enum.reject(fn {key, _} -> key in @transport_scoped end)
      |> Enum.filter(fn {_, files} ->
        Enum.all?(files, &String.starts_with?(&1, "lib/engram_web/"))
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    assert web_only == [],
           """
           These limit keys are gated ONLY inside lib/engram_web/:

             #{Enum.map_join(web_only, "\n  ", &":#{&1}")}

           A plug or controller gate covers one transport. MCP calls
           `Engram.*` contexts directly and never re-enters the HTTP stack, so
           the same operation over `POST /api/mcp` is unlimited.

           Move the check into the context function every caller routes
           through, or add the key to @transport_scoped with a reason if the
           endpoint really is the only way to reach the operation.
           """
  end

  # Collects every limit key passed as an atom literal to a Billing gate
  # function anywhere in `lib/`. Excludes the catalog itself, whose moduledoc
  # carries `:notes_cap` in usage examples, and `lib/mix/tasks/`, whose lint
  # tasks quote catalog keys in their docs.
  defp gate_sites do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(fn f ->
      String.contains?(f, "lib/mix/tasks/") or String.contains?(f, "billing/limit_keys.ex")
    end)
    |> Enum.flat_map(fn path -> Enum.map(keys_in_file(path), &{&1, path}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, files} -> {key, Enum.uniq(files)} end)
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
