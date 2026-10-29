defmodule Engram.DevRuntimeDefaultsTest do
  # A fresh clone must boot `mix phx.server` with no env file: MIX_ENV=dev
  # defaults to docker-compose.dev.yml's stores and a public dev-only master
  # key. Prod must refuse that key.
  use ExUnit.Case, async: false

  alias Engram.RuntimeConfig

  @vars ~w(DATABASE_URL QDRANT_URL STORAGE_BACKEND ENCRYPTION_MASTER_KEY)

  setup do
    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      for {var, value} <- previous,
          do: if(value, do: System.put_env(var, value), else: System.delete_env(var))
    end)
  end

  defp read_runtime(env), do: Config.Reader.read!("config/runtime.exs", env: env, target: :host)

  test "dev with no env resolves the docker-compose.dev.yml stores and the dev key" do
    engram = read_runtime(:dev)[:engram]
    repo = engram[Engram.Repo]

    assert repo[:hostname] == "localhost"
    assert repo[:port] == 5433
    assert repo[:database] == "engram_dev"
    assert engram[:qdrant_url] == "http://localhost:6334"
    assert engram[:storage] == Engram.Storage.Database
    assert engram[:encryption_master_key] == RuntimeConfig.dev_encryption_master_key()
    assert {:ok, <<_::256>>} = Base.decode64(engram[:encryption_master_key])
  end

  test "dev env vars still override the defaults" do
    System.put_env("DATABASE_URL", "postgresql://u:p@db.example:5432/other")
    System.put_env("QDRANT_URL", "http://qdrant.example:6333")
    System.put_env("STORAGE_BACKEND", "s3")
    key = Base.encode64(:crypto.strong_rand_bytes(32))
    System.put_env("ENCRYPTION_MASTER_KEY", key)

    engram = read_runtime(:dev)[:engram]

    assert engram[Engram.Repo][:url] == "postgresql://u:p@db.example:5432/other"
    assert engram[:qdrant_url] == "http://qdrant.example:6333"
    assert engram[:storage] == Engram.Storage.S3
    assert engram[:encryption_master_key] == key
  end

  test "prod refuses to boot with the dev-only key" do
    System.put_env("ENCRYPTION_MASTER_KEY", RuntimeConfig.dev_encryption_master_key())
    assert_raise RuntimeError, ~r/public dev-only key/, fn -> read_runtime(:prod) end
  end

  test "prod and test never fall back to the dev key" do
    getenv = fn _ -> nil end
    assert RuntimeConfig.encryption_master_key(getenv, :prod) == nil
    assert RuntimeConfig.encryption_master_key(getenv, :test) == nil
  end
end
