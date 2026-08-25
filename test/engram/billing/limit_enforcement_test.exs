defmodule Engram.Billing.LimitEnforcementTest do
  @moduledoc """
  Guards against advertising a limit we only enforce in the client.

  Every `LimitKeys` key whose Free default is restrictive must be referenced
  somewhere in `lib/`. Keys that are deliberately display-only go in
  `@unenforced` with a reason.

  This replaces `mix engram.lint.no_client_only_rate_limits`, whose whole
  coverage check was this same scan — the task's own test reimplemented it
  verbatim, so the task was 180 lines of duplicate plus a CI step. Its other
  half scanned for a `# client-only-rate-limit` comment marker that no source
  file has ever carried.
  """
  use ExUnit.Case, async: true

  alias Engram.Billing.LimitKeys

  # Deliberately not enforced server-side.
  @unenforced %{
    cross_vault_search: "legacy UX flag; no per-request gate point yet",
    vault_scoped_keys: "legacy; superseded by the api_key_vaults table"
  }

  test "every Free-restrictive limit key is referenced in lib/" do
    # `lib/mix/tasks/` is excluded so a key named only inside a lint task's
    # own docs can't count as an enforcement site.
    blob =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "lib/mix/tasks/"))
      |> Enum.map_join("\n", &File.read!/1)

    missing =
      Enum.reject(LimitKeys.all(), fn key ->
        LimitKeys.default_for(key, :free) in [nil, true] or
          Map.has_key?(@unenforced, key) or
          String.contains?(blob, ":#{key}")
      end)

    assert missing == [],
           """
           These Free-restrictive limit keys have no reference in lib/:

             #{Enum.map_join(missing, "\n  ", &":#{&1}")}

           Add a Billing.{check_limit, check_feature, effective_limit} call
           site, or add the key to @unenforced with a reason.
           """
  end
end
