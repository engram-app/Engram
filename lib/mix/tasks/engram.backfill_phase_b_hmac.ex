defmodule Mix.Tasks.Engram.BackfillPhaseBHmac do
  @moduledoc """
  Enqueues `Engram.Workers.BackfillPhaseBHmac` jobs for every (user, vault)
  combination that has at least one row with `path_hmac IS NULL` in notes,
  attachments, or `name_hmac IS NULL` in vaults.

  Idempotent — re-runs are safe. The worker itself skips populated rows.

  Usage from a release shell on FastRaid:
      docker exec engram-saas /app/bin/engram eval 'Mix.Task.run("engram.backfill_phase_b_hmac")'
  """

  use Mix.Task

  import Ecto.Query

  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.BackfillPhaseBHmac

  @shortdoc "Enqueue Phase B HMAC backfill jobs"

  def run(_args) do
    Mix.Task.run("app.start")

    pairs =
      Repo.all(
        from(n in Note,
          where: is_nil(n.path_hmac),
          group_by: [n.user_id, n.vault_id],
          select: {n.user_id, n.vault_id}
        ),
        skip_tenant_check: true
      )
      |> Enum.uniq()

    IO.puts("Enqueueing Phase B backfill for #{length(pairs)} (user, vault) pairs")

    for {user_id, vault_id} <- pairs do
      %{"user_id" => user_id, "vault_id" => vault_id, "last_id" => 0}
      |> BackfillPhaseBHmac.new()
      |> Oban.insert!()
    end

    IO.puts("Done. Watch oban_jobs queue=:backfill for progress.")
  end
end
