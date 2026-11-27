defmodule Engram.ServiceConfig.FlagKeysTest do
  @moduledoc """
  A flags-only key missing from `flag_keys/0` is dropped by the flags parser
  as unknown, so a `false` in the reviewed file is silently ignored and the
  step it guards still runs (engram-infra PR 1972 review). Every flags-only
  key must be a flag key, and every flag key a typed key.
  """
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig.Overrides

  test "every flags-only key is a flag key, and every flag key is typed" do
    assert Overrides.flags_only() -- Overrides.flag_keys() == []
    assert Overrides.flag_keys() -- Overrides.keys() == []
  end

  test "release L's boot-step kill switches are flags-only flag keys" do
    for key <- ~w(notes_shape_relax notes_name_unique_build notes_manifest_name_build)a do
      assert key in Overrides.flags_only(), "#{key} not flags-only"
      assert {:ok, ^key} = Overrides.flag_key(Atom.to_string(key))
      assert :ok = Overrides.validate(key, false)
    end
  end
end
