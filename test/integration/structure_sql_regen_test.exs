defmodule Engram.StructureSqlRegenTest do
  @moduledoc """
  Guards against `priv/repo/structure.sql` drifting from what PG18 emits for
  the same schema. Loads the on-disk structure dump into a fresh database,
  re-dumps it, and asserts byte-identical (modulo PG18's per-dump
  `\\restrict` / `\\unrestrict` security cookie, which is randomized).

  Without this guard, a hand-edited structure.sql that *happens* to load can
  silently diverge from `pg_dump`'s canonical form — making future baseline
  regens noisy and causing the structure-diff CI gate to flap.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  @structure Path.join([:code.priv_dir(:engram), "repo", "structure.sql"])
  @container "engram-dev-postgres"
  @pg_user "engram"
  @pg_password "engram"
  @test_db "engram_structure_regen_check"

  # `docker exec` inherits the host environment by default. Force a clean
  # subprocess env so credentials in the parent shell never leak into the
  # container's PATH/printenv output. PGPASSWORD is set inline below via
  # `-e PGPASSWORD=...` only on commands that need it.
  @clean_env %{
    "DATABASE_URL" => nil,
    "PGPASSWORD" => nil,
    "PGUSER" => nil,
    "ENCRYPTION_MASTER_KEY" => nil
  }

  test "structure.sql loads and re-dumps byte-identical" do
    on_disk = File.read!(@structure)

    drop_db()
    create_db()

    try do
      load_dump!(on_disk)
      redumped = redump!()

      assert normalize(on_disk) == normalize(redumped),
             diff_message(on_disk, redumped)
    after
      drop_db()
    end
  end

  defp create_db do
    {_out, 0} = docker_exec(["createdb", "-U", @pg_user, @test_db])
  end

  defp drop_db do
    docker_exec(["dropdb", "-U", @pg_user, "--if-exists", @test_db])
  end

  defp load_dump!(sql) do
    tmp = Path.join(System.tmp_dir!(), "structure-regen-#{System.unique_integer([:positive])}.sql")
    File.write!(tmp, sql)

    try do
      {_out, 0} = System.cmd("docker", ["cp", tmp, "#{@container}:/tmp/regen.sql"], env: @clean_env)

      {out, status} =
        docker_exec([
          "psql",
          "-v",
          "ON_ERROR_STOP=1",
          "-U",
          @pg_user,
          "-d",
          @test_db,
          "-f",
          "/tmp/regen.sql"
        ])

      assert status == 0, "psql failed loading dump:\n#{out}"
    after
      File.rm(tmp)
    end
  end

  defp redump! do
    {out, 0} =
      docker_exec([
        "pg_dump",
        "--schema-only",
        "--no-owner",
        "--exclude-table=schema_migrations",
        "-U",
        @pg_user,
        "-d",
        @test_db
      ])

    out
  end

  defp docker_exec(inner_args) do
    args = ["exec", "-e", "PGPASSWORD=#{@pg_password}", @container] ++ inner_args
    System.cmd("docker", args, env: @clean_env)
  end

  # PG18 pg_dump emits `\restrict <random>` / `\unrestrict <random>` lines.
  # The token is regenerated every dump, so it cannot be compared verbatim.
  defp normalize(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(&(String.starts_with?(&1, "\\restrict") or String.starts_with?(&1, "\\unrestrict")))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp diff_message(on_disk, redumped) do
    """
    structure.sql drifted from a fresh pg_dump.

    Re-run the Task C1 regen steps:
      1. Drop+create the dev DB.
      2. mix ecto.migrate --to 20260602000000
      3. pg_dump --schema-only --no-owner --exclude-table=schema_migrations
         > priv/repo/structure.sql
      4. Strip \\restrict / \\unrestrict lines.

    Length on-disk: #{byte_size(on_disk)} bytes
    Length redump:  #{byte_size(redumped)} bytes
    """
  end
end
