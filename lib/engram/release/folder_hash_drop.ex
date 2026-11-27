defmodule Engram.Release.FolderHashDrop do
  @moduledoc """
  Release K's owner-run boot step (S6 step 3, Engram#2523): drops the
  folder path hash index, then its column, with the statements of migration
  20261126100000 (kept there so the migration-gates reference check sees
  the drop, and `lib/` never names the column; the step parses the file
  for them, it never loads it). `Engram.Release.migrate/0`
  runs it after the migrations, on the same migrator connection and inside
  the same migration lock.

  It never fails or blocks boot (`Engram.Release.BootStep`, the shared shape:
  ledger, kill switch, bounded session). Each statement gets one try per boot
  (the index drop with no `lock_timeout`, CONCURRENTLY blocks no DML; the
  column drop under a 5 s one, so a contended table queues reads behind it
  for at most 5 s). A lock timeout or any error
  is a `folder_path_hash_drop deferred` warning: the ledger row stays open and
  the next boot retries. Both statements are
  IF EXISTS, so a rerun is safe, and a cancelled concurrent index drop
  leaves an INVALID index the rerun drops. Once both are gone the ledger
  (`folder_path_hash_drop` v1) is done and later boots stop at that one read.

  Kill switch: the flag `folder_path_hash_drop`, read from the flags
  source once per boot for every pending step (`BootStep.run_all/3`), because
  the flags reader has not started in the migrate eval. `false` stops the step;
  absent, no source (self-host), unreachable or timed out: run.
  """

  alias Engram.Release.BootStep

  @migration_file "priv/repo/migrations/20261126100000_drop_folder_path_hash_drops.exs"

  @doc "The ledger name."
  def name, do: step().name

  @doc "The step, for `Engram.Release.boot_steps/0`."
  @spec step() :: BootStep.t()
  def step do
    %BootStep{
      name: "folder_path_hash_drop",
      version: 1,
      flag: :folder_path_hash_drop,
      apply: &BootStep.exec(&1, statements())
    }
  end

  @doc """
  Runs the step alone on `repo` (a migrator-credential repo). Returns
  `:skipped` (ledger done), `:disabled` (flag off), `:done` or `:deferred`.
  Never raises. `opts`: `:flags_timeout_ms`.
  """
  @spec run(module(), keyword()) :: BootStep.result()
  def run(repo, opts \\ []) do
    [{_, result}] = BootStep.run_all(repo, [step()], opts)
    result
  end

  # The drops migration's `@statements` literals, read by parsing the file,
  # never by evaluating it: loading a migration runs code (sobelow
  # RCE.Compile) and re-requires its helper `lock_timeout_retry.exs`, which
  # the migrator has already compiled ("redefining module"). The migration
  # stays the one source of the DDL, where the migration-gates check reads it.
  # A fixed path under the app's priv (Ecto.Migrator.migrations_path/1's
  # default, which the repo keeps): a literal suffix, nothing outside the
  # release picks the file. Pinned in .sobelow-skips (Traversal.FileModule).
  defp statements do
    path = Application.app_dir(:engram, @migration_file)

    {_, found} =
      path
      |> File.read!()
      |> Code.string_to_quoted!(file: path)
      |> Macro.prewalk([], fn
        {:@, _, [{:statements, _, [list]}]} = node, acc when is_list(list) -> {node, [list | acc]}
        node, acc -> {node, acc}
      end)

    case found do
      [[_ | _] = sqls] -> if Enum.all?(sqls, &is_binary/1), do: sqls, else: bad(path)
      _ -> bad(path)
    end
  end

  @spec bad(Path.t()) :: no_return()
  defp bad(path), do: raise("#{path}: expected one @statements list of string literals")
end
