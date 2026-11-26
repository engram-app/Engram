defmodule Engram.ReleaseIReconcile do
  @moduledoc """
  Release J's boot migration 20261125100100 (release I's explicit-flag
  reconcile, then the `explicit_seq` stamp). It still runs for an install
  that skips to release K; `run!/0` is that boot run.
  """

  @path "priv/repo/migrations/20261125100100_explicit_folder_reconcile_migrate.exs"

  defp mod do
    m = :"Elixir.Engram.Repo.Migrations.ExplicitFolderReconcileMigrate"
    unless Code.ensure_loaded?(m), do: Code.require_file(@path)
    m
  end

  @doc """
  Puts back the column release K drops, inside the calling test's sandbox
  transaction (rolled back with it), so the reconcile's open-ledger branch
  sees the table a skipping install's boot does: J's migration sorts before
  K's drop. Holds ACCESS EXCLUSIVE on `folders` until the test ends, so
  only `async: false` tests may call it.
  """
  def pre_k_schema!,
    do: Engram.Repo.query!("ALTER TABLE folders ADD COLUMN IF NOT EXISTS full_path_hmac bytea")

  @doc "Runs the boot migration's reconcile."
  def run!, do: :ok = mod().reconcile(Engram.Repo)
end
