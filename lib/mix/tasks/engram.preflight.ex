defmodule Mix.Tasks.Engram.Preflight do
  @shortdoc "Preview pending migrations before upgrade (self-host)"
  @moduledoc """
  Connects to the configured Ecto repo and prints what
  `Engram.Release.migrate()` is about to do on the next container start.

  ## Usage

      mix engram.preflight

  Output: pending migrations with phase tags, irreversibility flags,
  estimated lock impact, and an optional rollback command (only when all
  pending migrations are reversible).

  Used by self-host operators before `docker compose down && docker compose up`.

  ## Phase tags

  A migration declares its phase via a top-level comment:

      # phase: expand
      # phase: migrate-data
      # phase: contract
      # phase: single-shot

  If no tag is found, phase is reported as `:unknown`.

  ## Lock-risk heuristic limitations

  `detect_lock_risk/1` reads the migration source statically. It does not
  analyze raw `execute("ALTER TABLE ...")` SQL, lower-cased SQL inside
  string literals, or runtime-built migration code. When in doubt, treat
  the lock impact as `:high` and plan downtime accordingly.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    repo = Engram.Repo
    applied = Ecto.Migrator.migrated_versions(repo)
    result = report(repo, applied_versions: applied)
    print(result)
  end

  @doc """
  Build a preflight report. Options:

    * `:migrations_dir` — default `"priv/repo/migrations"`. Override for tests.
    * `:applied_versions` — list of already-applied versions (integers). For tests.
  """
  def report(_repo, opts \\ []) do
    dir = opts[:migrations_dir] || "priv/repo/migrations"
    applied = MapSet.new(opts[:applied_versions] || [])

    pending =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.sort()
      |> Enum.flat_map(fn name ->
        case Regex.run(~r/^(\d{14})_(.+)\.exs$/, name) do
          [_, version_str, slug] ->
            v = String.to_integer(version_str)

            if MapSet.member?(applied, v) do
              []
            else
              [build_entry(dir, name, version_str, slug)]
            end

          _ ->
            []
        end
      end)

    irreversible? = Enum.any?(pending, & &1.irreversible)

    rollback_command =
      cond do
        pending == [] ->
          nil

        irreversible? ->
          nil

        true ->
          prev = applied |> Enum.sort(:desc) |> List.first()

          if prev,
            do: "bin/engram eval 'Engram.Release.rollback(Engram.Repo, #{prev})'",
            else: nil
      end

    %{
      pending: pending,
      already_run: MapSet.size(applied),
      rollback_command: rollback_command,
      warnings: []
    }
  end

  defp build_entry(dir, name, version_str, slug) do
    path = Path.join(dir, name)
    source = File.read!(path)

    %{
      version: version_str,
      name: slug,
      file: path,
      phase: detect_phase(source),
      irreversible: String.contains?(source, "# rollback-irreversible"),
      lock_risk: detect_lock_risk(source)
    }
  end

  defp detect_phase(source) do
    case Regex.run(~r/^\s*#\s*phase:\s*(\w[\w-]*)/m, source) do
      [_, "expand"] -> :expand
      [_, "migrate-data"] -> :migrate_data
      [_, "contract"] -> :contract
      [_, "single-shot"] -> :single_shot
      _ -> :unknown
    end
  end

  defp detect_lock_risk(source) do
    cond do
      # CONCURRENTLY indexes are safe (no table lock, no blocking writes).
      Regex.match?(~r/concurrently:\s*true/, source) ->
        :low

      # Plain CREATE INDEX (no CONCURRENTLY) takes a SHARE lock for the
      # duration — blocks writes on busy tables.
      Regex.match?(~r/\bcreate\s+(unique_)?index\b/, source) ->
        :high

      # DROP TABLE takes ACCESS EXCLUSIVE — blocks all reads + writes.
      Regex.match?(~r/\bdrop\s*\(?\s*table\b/, source) ->
        :high

      # RENAME TABLE / RENAME COLUMN take ACCESS EXCLUSIVE — instant for
      # rename itself, but blocks all activity during the cache flush.
      Regex.match?(~r/\brename\s+table\b/, source) ->
        :high

      # Column type change: ALTER COLUMN ... TYPE forces a table rewrite.
      # Regex matches `modify(:col, :type)` OR `modify(:col, :type, opts)` —
      # the prior version required `)` immediately after the type atom,
      # missing the common `modify(:foo, :string, null: false)` form.
      Regex.match?(~r/\bmodify\s*\(\s*:\w+\s*,\s*:[a-z]+/, source) ->
        :high

      # Generic alter table — adds, removes, defaults. Lock duration is
      # proportional to table size; ranks below explicit high-lock ops.
      Regex.match?(~r/\balter\s+table\b/, source) ->
        :medium

      true ->
        :low
    end
  end

  defp print(%{pending: []} = result) do
    Mix.shell().info("No pending migrations. Database is at the latest version.")
    Mix.shell().info("(Already-run migrations: #{result.already_run})")
  end

  defp print(result) do
    Mix.shell().info("PENDING MIGRATIONS (#{length(result.pending)}):")
    Mix.shell().info("")

    Enum.each(result.pending, fn m ->
      Mix.shell().info("  #{m.version}  #{m.name}")

      Mix.shell().info(
        "    phase: #{m.phase}  irreversible: #{m.irreversible}  lock_risk: #{m.lock_risk}"
      )
    end)

    Mix.shell().info("")
    Mix.shell().info("Already-run: #{result.already_run}")

    if result.rollback_command do
      Mix.shell().info("")
      Mix.shell().info("Rollback command (if needed AFTER upgrade):")
      Mix.shell().info("  #{result.rollback_command}")
    else
      Mix.shell().info("")

      Mix.shell().info(
        "⚠️  Rollback unavailable — at least one pending migration is marked irreversible."
      )

      Mix.shell().info("    Take a database backup before upgrading.")
    end
  end
end
