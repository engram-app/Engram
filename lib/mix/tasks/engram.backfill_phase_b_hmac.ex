defmodule Mix.Tasks.Engram.BackfillPhaseBHmac do
  @moduledoc """
  Enqueues `Engram.Workers.BackfillPhaseBHmac` jobs for every (user, vault)
  combination that has at least one row with `path_hmac IS NULL` in notes or
  attachments, or `name_hmac IS NULL` in vaults.

  Idempotent — re-runs are safe. The worker itself skips populated rows.

  Usage:

    # Local dev (mix available):
    mix engram.backfill_phase_b_hmac

    # Production (release — Mix not available, use rpc with inline body):
    docker exec engram-saas /app/bin/engram rpc "
    import Ecto.Query
    alias Engram.Notes.Note
    alias Engram.Attachments.Attachment
    alias Engram.Vaults.Vault
    alias Engram.Repo
    alias Engram.Workers.BackfillPhaseBHmac

    note_pairs = Repo.all(from(n in Note, where: is_nil(n.path_hmac), group_by: [n.user_id, n.vault_id], select: {n.user_id, n.vault_id}), skip_tenant_check: true)
    attachment_pairs = Repo.all(from(a in Attachment, where: is_nil(a.path_hmac), group_by: [a.user_id, a.vault_id], select: {a.user_id, a.vault_id}), skip_tenant_check: true)
    vault_pairs = Repo.all(from(v in Vault, where: is_nil(v.name_hmac), select: {v.user_id, v.id}), skip_tenant_check: true)
    pairs = (note_pairs ++ attachment_pairs ++ vault_pairs) |> Enum.uniq()

    for {uid, vid} <- pairs do
      %{\"user_id\" => uid, \"vault_id\" => vid, \"last_id\" => 0} |> BackfillPhaseBHmac.new() |> Oban.insert!()
    end
    IO.puts(\"enqueued \#{length(pairs)}\")
    "
  """

  use Mix.Task

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault
  alias Engram.Workers.BackfillPhaseBHmac

  @shortdoc "Enqueue Phase B HMAC backfill jobs"

  def run(_args) do
    Mix.Task.run("app.start")

    pairs = gather_pairs()

    IO.puts("Enqueueing Phase B backfill for #{length(pairs)} (user, vault) pairs")

    for {user_id, vault_id} <- pairs do
      %{"user_id" => user_id, "vault_id" => vault_id, "last_id" => 0}
      |> BackfillPhaseBHmac.new()
      |> Oban.insert!()
    end

    IO.puts("Done. Watch oban_jobs queue=:crypto_backfill for progress.")
  end

  @doc """
  Returns deduplicated `{user_id, vault_id}` pairs needing Phase B backfill,
  sourced from the union of:
  - notes with `path_hmac IS NULL`
  - attachments with `path_hmac IS NULL`
  - vaults with `name_hmac IS NULL`
  """
  def gather_pairs do
    note_pairs =
      Repo.all(
        from(n in Note,
          where: is_nil(n.path_hmac),
          group_by: [n.user_id, n.vault_id],
          select: {n.user_id, n.vault_id}
        ),
        skip_tenant_check: true
      )

    attachment_pairs =
      Repo.all(
        from(a in Attachment,
          where: is_nil(a.path_hmac),
          group_by: [a.user_id, a.vault_id],
          select: {a.user_id, a.vault_id}
        ),
        skip_tenant_check: true
      )

    vault_pairs =
      Repo.all(
        from(v in Vault,
          where: is_nil(v.name_hmac),
          select: {v.user_id, v.id}
        ),
        skip_tenant_check: true
      )

    (note_pairs ++ attachment_pairs ++ vault_pairs) |> Enum.uniq()
  end
end
