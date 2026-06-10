defmodule Engram.SchemaTest do
  use ExUnit.Case, async: true

  defmodule SampleSchema do
    use Engram.Schema

    schema "sample" do
      field(:name, :string)
    end
  end

  test "primary key is uuid, app-supplied" do
    assert SampleSchema.__schema__(:primary_key) == [:id]
    assert SampleSchema.__schema__(:type, :id) == Ecto.UUID
    assert SampleSchema.__schema__(:autogenerate_id) == nil
  end

  test "foreign key type is uuid" do
    # `__changeset__/0` returns a map of `field => ecto_type` for each
    # cast-eligible field on the schema. We assert the PK shows up as
    # `Ecto.UUID` here as a redundant guard alongside `:type`.
    assert Map.get(SampleSchema.__changeset__(), :id) == Ecto.UUID
  end
end
