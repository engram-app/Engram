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

  describe "ApiSpec.spec/0" do
    test "builds a valid OpenAPI 3.0 document" do
      spec = EngramWeb.ApiSpec.spec()

      assert %OpenApiSpex.OpenApi{openapi: "3.0.0"} = spec
      assert spec.info.title == "Engram API"
      assert is_binary(spec.info.version)
    end

    test "declares the bearerAuth + apiKey security schemes" do
      spec = EngramWeb.ApiSpec.spec()
      schemes = spec.components.securitySchemes

      assert %{type: "http", scheme: "bearer"} =
               Map.take(schemes["bearerAuth"], [:type, :scheme])

      assert %{type: "apiKey", in: "header"} =
               Map.take(schemes["apiKey"], [:type, :in])
    end
  end
end
