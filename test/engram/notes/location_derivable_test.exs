defmodule Engram.Notes.LocationDerivableTest do
  # `Location.derivable?/1` trusts a row's name keys on the same rule as the
  # `notes_set_name_key` trigger: the stamp is anchored on EITHER
  # `path_nonce` (today) or `name_nonce` (release L's second anchor).
  use ExUnit.Case, async: true

  alias Engram.Crypto.NameKeys
  alias Engram.Notes.Location

  defp row(stamp_on) do
    path_nonce = :crypto.strong_rand_bytes(13)
    name_nonce = :crypto.strong_rand_bytes(13)

    stamp =
      case stamp_on do
        :path -> NameKeys.stamp(path_nonce)
        :name -> NameKeys.stamp(name_nonce)
        :neither -> NameKeys.stamp(<<0>>)
        nil -> nil
      end

    %{
      deleted_at: nil,
      folder_ref_id: Ecto.UUID.dump!(Ecto.UUID.generate()),
      name_ciphertext: "ct",
      name_nonce: name_nonce,
      path_nonce: path_nonce,
      name_stamp: stamp
    }
  end

  test "a stamp on either nonce is derivable; on neither, or none, is not" do
    assert Location.derivable?(row(:path))
    assert Location.derivable?(row(:name))
    refute Location.derivable?(row(:neither))
    refute Location.derivable?(row(nil))
  end

  test "a name-anchored stamp needs no path nonce" do
    assert Location.derivable?(%{row(:name) | path_nonce: nil})
    refute Location.derivable?(%{row(:path) | name_nonce: nil, path_nonce: nil})
  end

  test "a tombstone or a row with no folder row or name is not derivable" do
    refute Location.derivable?(%{row(:name) | deleted_at: DateTime.utc_now()})
    refute Location.derivable?(%{row(:name) | folder_ref_id: nil})
    refute Location.derivable?(%{row(:name) | name_ciphertext: nil})
  end
end
