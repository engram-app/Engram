defmodule Engram.Release.Preflight do
  @moduledoc """
  Previews what `Engram.Release.migrate()` is about to do on the next container
  start: pending migrations with phase tags, irreversibility flags, estimated
  lock impact, and an optional rollback command.

  A plain module rather than a `Mix.Task` — `Mix` is not part of the release
  (see `releases/0` in `mix.exs`), so this is what
  `lib/mix/tasks/engram.preflight.ex` wraps, and what self-host operators call
  directly inside a running container:

      docker compose exec engram bin/engram rpc 'Engram.Release.Preflight.run()'

  Local/dev use: `mix engram.preflight`.

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

  @doc """
  Build the report and print it. The release/rpc entry point.
  """
  @spec run() :: :ok
  def run do
    repo = Engram.Repo

    repo
    |> report(applied_versions: Ecto.Migrator.migrated_versions(repo))
    |> print()
  end

  @doc """
  Build a preflight report. Options:

    * `:migrations_dir` — defaults to the app's own `priv/repo/migrations`.
      Override for tests.
    * `:applied_versions` — list of already-applied versions (integers). For tests.
  """
  def report(_repo, opts \\ []) do
    dir = opts[:migrations_dir] || migrations_dir()
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

  # Resolved through the application, NOT as the relative path
  # "priv/repo/migrations": in a release the CWD is the release root and priv
  # lives under lib/engram-<vsn>/, so the relative form raised File.Error the
  # moment this ran anywhere but a Mix project root. In dev/test app_dir
  # resolves through _build's priv symlink back to the source tree, so both
  # environments read the same 42 files.
  defp migrations_dir, do: Application.app_dir(:engram, "priv/repo/migrations")

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

  @doc """
  Print a report built by `report/2`. Uses `IO.puts` rather than
  `Mix.shell().info` so it works under release rpc.
  """
  @spec print(map()) :: :ok
  def print(%{pending: []} = result) do
    IO.puts("No pending migrations. Database is at the latest version.")
    IO.puts("(Already-run migrations: #{result.already_run})")
  end

  def print(result) do
    IO.puts("PENDING MIGRATIONS (#{length(result.pending)}):")
    IO.puts("")

    Enum.each(result.pending, fn m ->
      IO.puts("  #{m.version}  #{m.name}")
      IO.puts("    phase: #{m.phase}  irreversible: #{m.irreversible}  lock_risk: #{m.lock_risk}")
    end)

    IO.puts("")
    IO.puts("Already-run: #{result.already_run}")

    if result.rollback_command do
      IO.puts("")
      IO.puts("Rollback command (if needed AFTER upgrade):")
      IO.puts("  #{result.rollback_command}")
    else
      IO.puts("")
      IO.puts("⚠️  Rollback unavailable — at least one pending migration is marked irreversible.")
      IO.puts("    Take a database backup before upgrading.")
    end
  end
end
