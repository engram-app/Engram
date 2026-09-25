defmodule Engram.SkipTenantCheckInventoryTest do
  @moduledoc """
  Ratchet over every `skip_tenant_check: true` in `lib/`: the per-file counts
  must match a reviewed inventory. Adding a site fails this test until someone
  updates the number, which is the entire mechanism — it forces the question
  "did you mean to bypass the tenant guard?" into the diff that introduces it.

  ## Why a count ratchet and not a real "is it scoped?" lint

  Because the honest version is not writable. `skip_tenant_check: true` is
  correct at 197 of the 235 live sites and wrong at ~32, and telling those
  apart needs to know whether a `Repo.with_tenant/2` is in force at runtime —
  which is not a lexical property of the call site. The clearest counter-example
  is `crypto/user_dek_rotation.ex`: 21 of its sites sit in closures that
  `sweep_table_loop/4` executes inside a `with_tenant`, nowhere near them in the
  source. A lexical lint calls all 21 violations and gets turned off inside a
  week.

  So this test judges nothing about correctness. It only refuses to let the
  population grow quietly. The audit is what judged correctness, once, with a
  human reading each site; this keeps that audit from going stale.

  Its predecessor, `tenant_enumeration_lint_test.exs`, tried to judge, and
  bought the narrowness with coverage: it matches only the `from(...)`
  enumerate-by-user_id shape, so it sees none of the 144 direct `Repo.update` /
  `Repo.all` / `Repo.get` sites — including all 40 `Repo.update` calls, which
  are the silent-failure shape (a filtered UPDATE reports 0 rows and no error).
  Both tests stay: it catches a specific bug shape, this catches growth.

  ## What `skip_tenant_check: true` actually does

  It suppresses `Engram.Repo.prepare_query/3`, an application-level tripwire,
  and nothing else. It sets no Postgres session state and is not a tenant
  scope. Where RLS is enforced (the connecting role is not superuser and lacks
  BYPASSRLS), a query carrying it and no enclosing `with_tenant` is filtered by
  the policy: reads return zero rows, `UPDATE`/`DELETE` report zero affected
  with no error, and only `INSERT` raises 42501. Three of the four failure
  modes are silent, which is why the population needs a ratchet rather than
  trust.

  ## Known ceiling

  Counts, not lines. Line pins rot on any edit above them (`.sobelow-skips` and
  `.dialyzer_ignore.exs` have both broken that way in this repo), so this
  deliberately does not pin them. The cost: swapping one site for another in
  the same file passes silently. Worth it — the common case is a site being
  *added*, and that is caught.
  """
  use ExUnit.Case, async: true

  @lib_dir Path.expand("../../lib", __DIR__)

  @option ~r/skip_tenant_check:\s*true/

  # Reviewed count per file, relative to `lib/`. A new entry or a changed
  # number must come with a reason in the PR that changes it.
  #
  # Harvest a fresh map by setting this to `%{}` and reading the failure
  # message, which prints the live counts paste-ready. Do that only alongside
  # an actual audit of what moved — regenerating it to make the test pass is
  # the one use that defeats the point.
  @inventory %{
    "engram/abuse/origin_stats.ex" => 4,
    "engram/accounts.ex" => 35,
    "engram/accounts/export.ex" => 3,
    "engram/accounts/lifecycle.ex" => 4,
    "engram/accounts/password_reset.ex" => 5,
    "engram/auth/clerk/webhook.ex" => 2,
    "engram/auth/device_flow.ex" => 14,
    "engram/billing.ex" => 7,
    "engram/billing/plan_cache.ex" => 1,
    "engram/billing/reconciliation.ex" => 1,
    "engram/billing/workers/override_expiry_sweep.ex" => 1,
    "engram/connections.ex" => 3,
    "engram/crypto.ex" => 1,
    "engram/crypto/aad_rebind.ex" => 3,
    "engram/crypto/master_rotation.ex" => 2,
    "engram/crypto/provider_migration.ex" => 4,
    "engram/crypto/rotation_gate.ex" => 1,
    "engram/crypto/rotation_lock.ex" => 4,
    "engram/crypto/user_dek_rotation.ex" => 23,
    "engram/idempotency.ex" => 1,
    "engram/indexing.ex" => 2,
    "engram/indexing/index_cap.ex" => 2,
    "engram/instance.ex" => 4,
    "engram/legal.ex" => 4,
    "engram/legal/seeder.ex" => 2,
    "engram/links.ex" => 15,
    "engram/logs.ex" => 2,
    "engram/oauth.ex" => 14,
    "engram/oauth/cimd.ex" => 3,
    "engram/onboarding.ex" => 2,
    # TenancyGuard's behavioural probe. The one site in this inventory where
    # the keyword is an accurate DECLARATION rather than a concession: the
    # probe deliberately sets a tenant that owns nothing and asks the SERVER
    # whether the policy filters. The `prepare_query/3` tripwire would refuse
    # the query before Postgres saw it, which would make the guard measure the
    # tripwire instead of the database it is there to interrogate.
    #
    # Generated: one clause per entry in `Repo.tenant_tables/0`, but the
    # keyword appears once in source, which is what this lint counts.
    "engram/repo/tenancy_guard.ex" => 1,
    "engram/usage_meters.ex" => 11,
    "engram/vaults.ex" => 1,
    "engram/workers/account_export.ex" => 6,
    "engram/workers/cimd_refresh.ex" => 1,
    "engram/workers/cleanup_vault.ex" => 1,
    "engram/workers/export_expiry_sweep.ex" => 3,
    "engram/workers/inactivity_cleanup.ex" => 4,
    "engram/workers/vault_deleted_email.ex" => 1,
    "engram_web/controllers/admin/user_controller.ex" => 3
  }

  test "no new skip_tenant_check sites appeared" do
    actual =
      @lib_dir
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.map(&{Path.relative_to(&1, @lib_dir), count_sites(&1)})
      |> Enum.reject(fn {_rel, count} -> count == 0 end)
      |> Map.new()

    assert actual == @inventory, """
    The `skip_tenant_check: true` population changed.

    Added (or newly counted):
    #{diff(actual, @inventory)}
    Removed (or newly uncounted):
    #{diff(@inventory, actual)}
    If you ADDED a site: it bypasses the tenant guard, so confirm the query
    either runs inside `Repo.with_tenant/2` or genuinely spans tenants — and if
    it spans tenants, prefer `Engram.Repo.maintenance()`, which needs no option
    because that pool carries no tripwire to suppress.

    If you REMOVED one: good. Update the number below.

    Live counts, paste-ready:

    @inventory %{
    #{Enum.map_join(Enum.sort(actual), ",\n", fn {f, n} -> ~s(      "#{f}" => #{n}) end)}
    }
    """
  end

  # Comments and heredocs are stripped before counting, because the literal
  # `skip_tenant_check: true` appears in prose all over this codebase — 36
  # occurrences at last count, including in the moduledoc of the maintenance
  # pool that exists to replace it. Counting those would make the ratchet fire
  # on documentation edits, which is the fastest way to get it deleted.
  defp count_sites(path) do
    {kept, inside_heredoc?} =
      path |> File.read!() |> String.split("\n") |> strip_heredocs()

    # Fail LOUD on a desync rather than reporting a plausible smaller number.
    # The stripper toggles on any line containing `\"\"\"`, so a line that both
    # opens and closes one, or a `\"\"\"` inside a regular string or sigil,
    # leaves it inverted — and everything past that point counts as prose and
    # contributes 0. That shows up as a lower count, which the failure message
    # below then invites someone to "fix" by regenerating the map, silently
    # un-guarding the tail of the file. An unbalanced toggle means the number
    # is untrustworthy, not that sites were removed.
    if inside_heredoc? do
      raise """
      unbalanced heredoc in #{path}: the `\"\"\"` toggle ended INSIDE a
      docstring, so every line past the desync was treated as prose and counted
      as zero. Fix the stripper — do NOT regenerate @inventory from this run.
      """
    end

    kept
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    # Occurrences, not lines: two sites on one line must count as two. None
    # exist today, which is exactly why this is cheap to get right now.
    |> Enum.map(&length(Regex.scan(@option, &1)))
    |> Enum.sum()
  end

  # Line-level toggle on `"""`. Crude, and sufficient: it only has to be right
  # about whether a line carrying the option is inside a docstring, and no line
  # in `lib/` both opens a heredoc and calls a Repo function.
  #
  # Returns the trailing toggle state so `count_sites/1` can refuse to report a
  # number it does not trust. The kept lines come back reversed, which is
  # harmless for counting — do not use this to report line numbers.
  defp strip_heredocs(lines) do
    Enum.reduce(lines, {[], false}, fn line, {acc, inside?} ->
      cond do
        String.contains?(line, ~s(""")) -> {acc, not inside?}
        inside? -> {acc, true}
        true -> {[line | acc], false}
      end
    end)
  end

  defp diff(a, b) do
    a
    |> Enum.reject(fn {file, count} -> Map.get(b, file) == count end)
    |> Enum.sort()
    |> case do
      [] -> "  (none)\n"
      entries -> Enum.map_join(entries, "\n", fn {f, n} -> "  #{f} => #{n}" end) <> "\n"
    end
  end
end
