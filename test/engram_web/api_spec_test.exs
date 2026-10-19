defmodule EngramWeb.ApiSpecTest do
  # async: false — building the full ApiSpec resolves ~100 schema modules via
  # OpenApiSpex.resolve_schema_modules. Running that concurrently with the rest
  # of the suite intermittently races OpenApiSpex's schema resolution (raises in
  # resolve_schema_modules_from_response): green in isolation, flaky only in the
  # full suite. Serializing this module removes the race.
  use ExUnit.Case, async: false

  # Per-endpoint shape (tags, params, response codes) is NOT asserted here: the
  # verify.yml "OpenAPI spec drift gate" regenerates the spec and diffs it
  # against the committed openapi.json, so any annotation change already needs
  # a reviewed regen. This file keeps only spec-wide invariants the diff cannot
  # judge: version decoupling, the auth scheme, and operationId hygiene.

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

  describe "security defaults" do
    test "global security defaults to bearerAuth" do
      spec = EngramWeb.ApiSpec.spec()
      assert spec.security == [%{"bearerAuth" => []}]
    end

    test "health operations opt out of global security (public)" do
      spec = EngramWeb.ApiSpec.spec()
      assert spec.paths["/api/health"].get.security == []
    end
  end

  describe "operationId slugs" do
    setup do: %{spec: EngramWeb.ApiSpec.spec()}

    test "every operation sets an explicit, slug-clean operationId", %{spec: spec} do
      ids =
        for {_path, item} <- spec.paths,
            verb <- [:get, :post, :patch, :put, :delete],
            op = Map.get(item, verb),
            not is_nil(op),
            do: op.operationId

      assert ids != []

      for id <- ids do
        # No default `EngramWeb.SomeController.action` ids leak through — those
        # slugify to unreadable mush (engramweb...controlleraction).
        refute id =~ "Controller", "operationId still defaulted: #{id}"
        refute id =~ ".", "operationId should be hyphenated, not dotted: #{id}"
        assert id =~ ~r/^[a-z0-9-]+$/, "operationId not slug-clean: #{id}"
      end

      # Unique across the whole spec (slugs must not collide).
      assert length(ids) == length(Enum.uniq(ids))
    end

    test "known endpoints carry their expected operationId", %{spec: spec} do
      assert spec.paths["/api/notes"].post.operationId == "notes-upsert"
      assert spec.paths["/api/vaults/{id}/restore"].post.operationId == "vaults-restore"
      assert spec.paths["/api/me"].get.operationId == "account-me"
      assert spec.paths["/api/search"].post.operationId == "search"
    end
  end
end
