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

    test "info.version is the static API contract version, not the app build" do
      spec = EngramWeb.ApiSpec.spec()

      # Decoupled from Application.spec(:engram, :vsn) so release bumps don't
      # churn openapi.json / trip the CI drift gate. See ApiSpec @api_version.
      assert spec.info.version == "1.0.0"
      refute spec.info.version == to_string(Application.spec(:engram, :vsn))
    end

    test "declares a single bearerAuth security scheme covering all credentials" do
      spec = EngramWeb.ApiSpec.spec()
      schemes = spec.components.securitySchemes

      assert %{type: "http", scheme: "bearer"} =
               Map.take(schemes["bearerAuth"], [:type, :scheme])

      # API keys ride the same Authorization: Bearer header, so there is no
      # separate apiKey scheme to duplicate it.
      refute Map.has_key?(schemes, "apiKey")
    end
  end

  describe "annotated paths" do
    test "/api/health is present with a 200 HealthStatus response" do
      spec = EngramWeb.ApiSpec.spec()

      assert %{} = op = spec.paths["/api/health"].get
      assert op.summary
      assert Map.has_key?(op.responses, 200)
    end
  end

  describe "foundation" do
    test "global security defaults to bearerAuth" do
      spec = EngramWeb.ApiSpec.spec()
      assert spec.security == [%{"bearerAuth" => []}]
    end

    test "health operations opt out of global security (public)" do
      spec = EngramWeb.ApiSpec.spec()
      assert spec.paths["/api/health"].get.security == []
    end

    test "declares Notes/Folders/Search/Tags tags" do
      spec = EngramWeb.ApiSpec.spec()
      names = Enum.map(spec.tags, & &1.name)
      assert "Notes" in names and "Folders" in names
      assert "Search" in names and "Tags" in names
    end

    test "shared schemas resolve" do
      assert %OpenApiSpex.Schema{type: :object} = EngramWeb.Schemas.Note.schema()
      assert %OpenApiSpex.Schema{type: :object} = EngramWeb.Schemas.Error.schema()
    end
  end

  describe "Notes paths" do
    setup do: %{spec: EngramWeb.ApiSpec.spec()}

    test "POST /api/notes documents request + 201/409/422/413", %{spec: spec} do
      op = spec.paths["/api/notes"].post
      assert op.tags == ["Notes"]
      assert op.requestBody
      assert Enum.sort(Map.keys(op.responses)) == [201, 409, 413, 422]
    end

    test "GET /api/notes/changes documents since/limit/fields/cursor", %{spec: spec} do
      op = spec.paths["/api/notes/changes"].get
      names = Enum.map(op.parameters, & &1.name)
      assert :since in names and :limit in names and :fields in names and :cursor in names
      assert Map.has_key?(op.responses, 200) and Map.has_key?(op.responses, 400)
    end

    test "by-id show documents id path param + 404", %{spec: spec} do
      op = spec.paths["/api/notes/by-id/{id}"].get
      assert Enum.any?(op.parameters, &(&1.name == :id and &1.in == :path))
      assert Map.has_key?(op.responses, 404)
    end
  end
end
