defmodule Engram.Crypto.KeyProviderIdentifyTest do
  use ExUnit.Case, async: true

  alias Engram.Crypto.KeyProvider

  test "0xAA-prefixed blob → AwsKms" do
    assert {:ok, Engram.Crypto.KeyProvider.AwsKms} =
             KeyProvider.identify_from_blob(<<0xAA, 0x01, 0x00, 0x00>>)
  end

  test "0x02-prefixed 62-byte blob → Local (v2)" do
    blob = <<0x02, 0x01>> <> :binary.copy(<<0>>, 60)
    assert {:ok, Engram.Crypto.KeyProvider.Local} = KeyProvider.identify_from_blob(blob)
  end

  test "0x01-prefixed 62-byte blob → Local (v1)" do
    blob = <<0x01, 0x01>> <> :binary.copy(<<0>>, 60)
    assert {:ok, Engram.Crypto.KeyProvider.Local} = KeyProvider.identify_from_blob(blob)
  end

  test "60-byte raw blob → Local (legacy)" do
    blob = :binary.copy(<<0>>, 60)
    assert {:ok, Engram.Crypto.KeyProvider.Local} = KeyProvider.identify_from_blob(blob)
  end

  test "unknown blob shape → {:error, :unrecognised_blob}" do
    assert {:error, :unrecognised_blob} =
             KeyProvider.identify_from_blob(<<0x77, 0x99, 0xAB>>)
  end

  test "non-binary input → {:error, :unrecognised_blob}" do
    assert {:error, :unrecognised_blob} = KeyProvider.identify_from_blob(nil)
  end
end
