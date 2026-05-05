defmodule Engram.Crypto.ProviderConformanceTest do
  @moduledoc """
  Shared conformance exercised against every KeyProvider. Any new provider
  must pass these assertions without modification.
  """
  use ExUnit.Case, async: false

  @providers [Engram.Crypto.KeyProvider.Local]

  setup do
    Application.put_env(
      :engram,
      :encryption_master_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    :ok
  end

  for provider <- @providers do
    @tag provider: provider
    test "#{inspect(provider)}: name is an atom", %{} do
      assert is_atom(unquote(provider).name())
    end

    test "#{inspect(provider)}: generate_dek is 32 bytes" do
      assert byte_size(unquote(provider).generate_dek()) == 32
    end

    test "#{inspect(provider)}: wrap/unwrap round-trips" do
      dek = unquote(provider).generate_dek()
      ctx = %{user_id: 1}
      {:ok, wrapped} = unquote(provider).wrap_dek(dek, ctx)
      assert {:ok, ^dek} = unquote(provider).unwrap_dek(wrapped, ctx)
    end

    test "#{inspect(provider)}: rotate_wrapping preserves DEK" do
      dek = unquote(provider).generate_dek()
      ctx = %{user_id: 1}
      {:ok, wrapped} = unquote(provider).wrap_dek(dek, ctx)
      {:ok, rotated} = unquote(provider).rotate_wrapping(wrapped, ctx)
      assert {:ok, ^dek} = unquote(provider).unwrap_dek(rotated, ctx)
    end

    test "#{inspect(provider)}: supports_async_workers? is boolean" do
      assert is_boolean(unquote(provider).supports_async_workers?())
    end
  end
end
