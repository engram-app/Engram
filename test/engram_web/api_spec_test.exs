defmodule EngramWeb.ApiSpecTest do
  use ExUnit.Case, async: true

  describe "HealthStatus schema" do
    test "is a valid OpenApiSpex schema struct with the expected fields" do
      schema = EngramWeb.Schemas.HealthStatus.schema()

      assert %OpenApiSpex.Schema{type: :object} = schema
      assert Map.has_key?(schema.properties, :status)
      assert Map.has_key?(schema.properties, :version)
    end
  end
end
