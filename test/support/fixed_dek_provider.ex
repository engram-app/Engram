defmodule Engram.Test.FixedDekProvider do
  @moduledoc """
  `KeyProvider.Local`, except `rotate_dek/2` hands out a DEK the test chose
  (`install!/0`), so a test can pre-seed rows "already rotated" by a crashed
  run under the very key the retry will use.
  """
  alias Engram.Crypto.KeyProvider.Local

  for {name, arity} <- Local.__info__(:functions), name != :rotate_dek do
    args = Macro.generate_arguments(arity, __MODULE__)
    def unquote(name)(unquote_splicing(args)), do: Local.unquote(name)(unquote_splicing(args))
  end

  def rotate_dek(_old_wrapped, ctx) do
    dek = Application.fetch_env!(:engram, :test_fixed_rotation_dek)
    {:ok, wrapped} = Local.wrap_dek(dek, ctx)
    {:ok, wrapped, dek}
  end

  @doc """
  Makes this the key provider for the calling test (restored on exit) and
  returns the DEK the next rotation will hand out. For `async: false` tests:
  the key provider is global.
  """
  def install! do
    dek = :crypto.strong_rand_bytes(32)
    prev = Application.get_env(:engram, :key_provider)
    Application.put_env(:engram, :key_provider, __MODULE__)
    Application.put_env(:engram, :test_fixed_rotation_dek, dek)

    ExUnit.Callbacks.on_exit(fn ->
      if prev,
        do: Application.put_env(:engram, :key_provider, prev),
        else: Application.delete_env(:engram, :key_provider)

      Application.delete_env(:engram, :test_fixed_rotation_dek)
    end)

    dek
  end
end
