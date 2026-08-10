defmodule Mix.Tasks.Engram.BackfillOnboardingActions do
  @shortdoc "Backfill onboarding_actions for legacy users with vaults"

  @moduledoc """
  One-shot: insert `first_vault_created` for every user with at least one
  vault, via `Engram.Onboarding.Backfill.first_vault_created/0`.

  Thin wrapper only — `Mix.Task` is unavailable in a release, so the actual
  backfill lives in `Engram.Onboarding.Backfill`, which release rpc calls directly
  instead of going through this task:

      docker exec engram-saas /app/bin/engram rpc 'Engram.Onboarding.Backfill.first_vault_created()'

  Local/dev use:

      mix engram.backfill_onboarding_actions

  Idempotent via the unique index on (user_id, action).
  """

  use Mix.Task

  alias Engram.Onboarding.Backfill

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    count = Backfill.first_vault_created()
    Mix.shell().info("Backfilled #{count} onboarding_actions rows")
    :ok
  end
end
