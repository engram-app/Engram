defmodule Engram.Crypto.ProviderConformanceTest do
  @moduledoc """
  Shared conformance exercised against every KeyProvider. Any new provider
  must pass these assertions without modification.

  AwsKms's KMS calls are stubbed via Mox so this suite stays hermetic.
  """
  use ExUnit.Case, async: false

  import Mox

  setup :verify_on_exit!

  @providers [
    Engram.Crypto.KeyProvider.Local,
    Engram.Crypto.KeyProvider.AwsKms
  ]

  setup do
    Application.put_env(
      :engram,
      :encryption_master_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    prev_client = Application.get_env(:engram, :aws_kms_client)
    Application.put_env(:engram, :aws_kms_client, Engram.AwsKmsMock)

    on_exit(fn -> Application.put_env(:engram, :aws_kms_client, prev_client) end)

    :ok
  end

  # AwsKms needs Mox stubs that simulate a real KMS round-trip. We keep an
  # in-process map of ciphertext → plaintext so wrap/unwrap pairs round-trip.
  defp stub_aws_kms_roundtrip do
    table = :ets.new(:aws_kms_stub_table, [:set, :public])

    stub(Engram.AwsKmsMock, :encrypt, fn pt, _ctx ->
      ct = :crypto.strong_rand_bytes(48)
      :ets.insert(table, {ct, pt})
      {:ok, ct}
    end)

    stub(Engram.AwsKmsMock, :decrypt, fn ct, _ctx ->
      case :ets.lookup(table, ct) do
        [{^ct, pt}] -> {:ok, pt}
        [] -> {:error, :context_mismatch}
      end
    end)

    stub(Engram.AwsKmsMock, :re_encrypt, fn ct, _src, _dst ->
      case :ets.lookup(table, ct) do
        [{^ct, pt}] ->
          new_ct = :crypto.strong_rand_bytes(48)
          :ets.insert(table, {new_ct, pt})
          {:ok, new_ct}

        [] ->
          {:error, :context_mismatch}
      end
    end)

    :ok
  end

  for provider <- @providers do
    @tag provider: provider
    test "#{inspect(provider)}: name is an atom" do
      if unquote(provider) == Engram.Crypto.KeyProvider.AwsKms, do: stub_aws_kms_roundtrip()
      assert is_atom(unquote(provider).name())
    end

    test "#{inspect(provider)}: generate_dek is 32 bytes" do
      if unquote(provider) == Engram.Crypto.KeyProvider.AwsKms, do: stub_aws_kms_roundtrip()
      assert byte_size(unquote(provider).generate_dek()) == 32
    end

    test "#{inspect(provider)}: wrap/unwrap round-trips" do
      if unquote(provider) == Engram.Crypto.KeyProvider.AwsKms, do: stub_aws_kms_roundtrip()

      dek = unquote(provider).generate_dek()
      ctx = %{user_id: 1}
      {:ok, wrapped} = unquote(provider).wrap_dek(dek, ctx)
      assert {:ok, ^dek} = unquote(provider).unwrap_dek(wrapped, ctx)
    end

    test "#{inspect(provider)}: rotate_wrapping preserves DEK" do
      if unquote(provider) == Engram.Crypto.KeyProvider.AwsKms, do: stub_aws_kms_roundtrip()

      dek = unquote(provider).generate_dek()
      ctx = %{user_id: 1}
      {:ok, wrapped} = unquote(provider).wrap_dek(dek, ctx)
      {:ok, rotated} = unquote(provider).rotate_wrapping(wrapped, ctx)
      assert {:ok, ^dek} = unquote(provider).unwrap_dek(rotated, ctx)
    end

    test "#{inspect(provider)}: supports_async_workers? is boolean" do
      if unquote(provider) == Engram.Crypto.KeyProvider.AwsKms, do: stub_aws_kms_roundtrip()
      assert is_boolean(unquote(provider).supports_async_workers?())
    end

    test "#{inspect(provider)}: rotate_dek returns fresh DEK + new wrapped blob" do
      if unquote(provider) == Engram.Crypto.KeyProvider.AwsKms, do: stub_aws_kms_roundtrip()

      dek = unquote(provider).generate_dek()
      ctx = %{user_id: 1}
      {:ok, old_wrapped} = unquote(provider).wrap_dek(dek, ctx)
      {:ok, new_wrapped, new_dek} = unquote(provider).rotate_dek(old_wrapped, ctx)

      assert byte_size(new_dek) == 32
      assert new_dek != dek
      assert new_wrapped != old_wrapped
      assert {:ok, ^new_dek} = unquote(provider).unwrap_dek(new_wrapped, ctx)
    end

    test "#{inspect(provider)}: boot_check returns :ok in happy path" do
      if unquote(provider) == Engram.Crypto.KeyProvider.AwsKms do
        stub_aws_kms_roundtrip()
        stub(Engram.AwsKmsMock, :describe_key, fn -> :ok end)
      end

      assert :ok = unquote(provider).boot_check()
    end

    test "#{inspect(provider)}: unwrap_dek_no_fallback round-trips wrapped DEK" do
      if unquote(provider) == Engram.Crypto.KeyProvider.AwsKms, do: stub_aws_kms_roundtrip()

      dek = unquote(provider).generate_dek()
      ctx = %{user_id: 1}
      {:ok, wrapped} = unquote(provider).wrap_dek(dek, ctx)
      assert {:ok, ^dek} = unquote(provider).unwrap_dek_no_fallback(wrapped, ctx)
    end
  end

  describe "cross-provider identify_from_blob/1 round-trip" do
    test "every provider produces a blob that identify_from_blob maps back to itself" do
      stub_aws_kms_roundtrip()

      for provider <- @providers do
        dek = provider.generate_dek()
        {:ok, blob} = provider.wrap_dek(dek, %{user_id: 1})
        assert {:ok, ^provider} = Engram.Crypto.KeyProvider.identify_from_blob(blob)
      end
    end
  end
end
