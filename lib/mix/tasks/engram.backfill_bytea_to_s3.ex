defmodule Mix.Tasks.Engram.BackfillByteaToS3 do
  @shortdoc "Enqueues BackfillByteaToS3 Oban jobs for every (user, vault) with legacy plaintext attachments"

  @moduledoc """
  Scans `attachments` for rows with `encryption_version = 0 AND content IS NOT NULL`
  and enqueues one `Engram.Workers.BackfillByteaToS3` job per distinct (user_id, vault_id)
  pair, with `cursor: 0`. Re-running is safe — `unique` constraints on the worker
  prevent duplicate enqueues.

  Run inside the engram release container:

      docker exec engram-saas /app/bin/engram eval \\
        'Mix.Task.run("engram.backfill_bytea_to_s3")'
  """
  use Mix.Task

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Repo
  alias Engram.Workers.BackfillByteaToS3

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    pairs =
      Repo.all(
        from(a in Attachment,
          where: a.encryption_version == 0 and not is_nil(a.content),
          distinct: true,
          select: {a.user_id, a.vault_id}
        ),
        skip_tenant_check: true
      )

    enqueued =
      Enum.map(pairs, fn {user_id, vault_id} ->
        {:ok, _} =
          BackfillByteaToS3.new(%{user_id: user_id, vault_id: vault_id, cursor: 0})
          |> Oban.insert()
      end)

    IO.puts("Enqueued #{length(enqueued)} jobs across #{length(pairs)} (user, vault) pairs")
  end
end
