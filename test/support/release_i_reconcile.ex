defmodule Engram.ReleaseIReconcile do
  @moduledoc """
  Release I's explicit-flag reconcile rule (`ExplicitFolderReconcile`,
  retired in release J), as boot migration 20261125100100 keeps it. A
  rollback to I runs it daily, so a test of J's writes asks which rows it
  would clear; `run!/0` is the boot run itself.
  """

  @path "priv/repo/migrations/20261125100100_explicit_folder_reconcile_migrate.exs"

  defp mod do
    m = :"Elixir.Engram.Repo.Migrations.ExplicitFolderReconcileMigrate"
    unless Code.ensure_loaded?(m), do: Code.require_file(@path)
    m
  end

  @doc "The ids of `user_id`'s folder rows release I's reconcile would clear."
  def cleared_ids(user_id) do
    Engram.Repo.query!(
      "SELECT f.id FROM folders AS f WHERE f.user_id = $1 AND " <> mod().stale(),
      [
        Ecto.UUID.dump!(user_id)
      ]
    ).rows
  end

  @doc "Runs the boot migration's reconcile."
  def run!, do: :ok = mod().reconcile(Engram.Repo)
end
