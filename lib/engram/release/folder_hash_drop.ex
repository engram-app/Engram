defmodule Engram.Release.FolderHashDrop do
  @moduledoc """
  Release K's owner-run boot step (S6 step 3, Engram#2523): drops the
  folder path hash index, then its column, with the statements of migration
  20261126100000 (kept there so the migration-gates reference check sees
  the drop, and `lib/` never names the column; the step parses the file
  for them, it never loads it). `Engram.Release.migrate/0`
  runs it after the migrations, on the same migrator connection and inside
  the same migration lock.

  It never fails or blocks boot. Each statement gets one try per boot under
  a 5 s `lock_timeout` (LockTimeoutRetry's value; no in-boot retries, so a
  contended table queues reads behind it for at most 5 s per statement). A
  lock timeout or any error is a `folder_path_hash_drop deferred` warning:
  the ledger row stays open and the next boot retries. Both statements are
  IF EXISTS, so a rerun is safe, and a cancelled concurrent index drop
  leaves an INVALID index the rerun drops. Once both are gone the ledger
  (`folder_path_hash_drop` v1) is done and later boots stop at that one read.

  Kill switch: the flag `folder_path_hash_drop`, read once from the flags
  source (`Engram.ServiceConfig.Flags.read_once/2`, 3 s budget) because the
  flags reader has not started in the migrate eval. `false` stops the step;
  absent, no source (self-host), unreachable or timed out: run.
  """

  alias Engram.DataMigrations
  alias Engram.Logger.Metadata
  alias Engram.ServiceConfig.Flags

  require Logger

  @name "folder_path_hash_drop"
  @version 1
  @flag :folder_path_hash_drop
  @migration_file "priv/repo/migrations/20261126100000_drop_folder_path_hash_drops.exs"
  @flags_timeout_ms 3_000
  @lock_timeout "5s"
  @statement_timeout_ms 30_000

  @doc "The ledger name."
  def name, do: @name

  @doc """
  Runs the step on `repo` (a migrator-credential repo). Returns `:skipped`
  (ledger done), `:disabled` (flag off), `:done` or `:deferred`. Never raises.
  `opts`: `:flags_timeout_ms`.
  """
  @spec run(module(), keyword()) :: :skipped | :disabled | :done | :deferred
  def run(repo, opts \\ []) do
    cond do
      DataMigrations.done?(@name, @version) -> :skipped
      not enabled?(Keyword.get(opts, :flags_timeout_ms, @flags_timeout_ms)) -> :disabled
      true -> drop(repo)
    end
  rescue
    e -> deferred(e)
  catch
    kind, reason -> deferred({kind, reason})
  end

  defp enabled?(timeout_ms) do
    case Application.get_env(:engram, :service_flags) do
      nil ->
        true

      source ->
        # The migrate eval starts no app. The fetch needs Req (and its Finch
        # pool, which ex_aws's Req client shares) and ex_aws, whose AuthCache
        # holds the task-role credentials that sign the AppConfig call.
        _ = Application.ensure_all_started([:req, :ex_aws])

        case Flags.read_once(source, timeout_ms) do
          {:ok, flags} ->
            Map.get(flags, @flag, true)

          {:error, reason} ->
            Logger.warning(
              "#{@name} flags unreadable; running with the default (on)",
              Metadata.with_category(:warning, :boot, reason: safe(reason))
            )

            true
        end
    end
  end

  defp drop(repo) do
    result =
      repo.checkout(
        fn ->
          repo.query!("SET lock_timeout = '#{@lock_timeout}'")
          repo.query!("SET statement_timeout = #{@statement_timeout_ms}")

          try do
            Enum.reduce_while(statements(), :ok, fn sql, :ok ->
              case repo.query(sql, [], timeout: @statement_timeout_ms + 5_000) do
                {:ok, _} -> {:cont, :ok}
                {:error, e} -> {:halt, {:error, e}}
              end
            end)
          after
            repo.query!("RESET lock_timeout")
            repo.query!("RESET statement_timeout")
          end
        end,
        timeout: 3 * @statement_timeout_ms
      )

    case result do
      :ok ->
        :ok = DataMigrations.mark_done(@name, @version)

        Logger.info(
          "#{@name} done",
          Metadata.with_category(:info, :boot, migration: @name, version: @version)
        )

        :done

      {:error, e} ->
        deferred(e)
    end
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

  defp bad(path), do: raise("#{path}: expected one @statements list of string literals")

  defp deferred(reason) do
    Logger.warning(
      "#{@name} deferred; the next boot retries",
      Metadata.with_category(:warning, :boot, migration: @name, reason: safe(reason))
    )

    _ = open_ledger()
    :deferred
  end

  # Best effort: a ledger write failing too must not fail boot.
  defp open_ledger do
    DataMigrations.note_open(@name, @version)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp safe(%{__exception__: true} = e), do: Metadata.safe_reason(e)
  defp safe(reason) when is_atom(reason) or is_binary(reason), do: to_string(reason)
  defp safe(reason), do: Metadata.safe_exit_reason(reason)
end
