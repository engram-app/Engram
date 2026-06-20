defmodule EngramWeb.ApiSpecCoverageTest do
  @moduledoc """
  Universal documentation-coverage gate over the generated OpenAPI spec.

  Unlike `api_spec_test.exs` (which asserts specific endpoints exist with
  specific params/responses), this walks EVERY operation and enforces
  doc-quality invariants, so a newly-annotated endpoint cannot ship
  under-documented without an explicit, visible exemption.

  Two escape hatches, both deliberate:

    * `"x-internal": true` on the operation — the endpoint is internal and
      intentionally kept out of the public docs (it is also filtered out of
      the published docs site). Permanent.
    * the `@pending_*` allowlists below — known documentation debt awaiting
      backfill. These lists must only SHRINK. Adding a new endpoint does NOT
      entitle you to grow them; document the endpoint instead.
  """
  use ExUnit.Case, async: true

  alias OpenApiSpex.{MediaType, Reference, RequestBody}

  @verbs [:get, :post, :put, :patch, :delete]

  # Operations still missing a prose `description` (backfill: PR #2).
  # MUST ONLY SHRINK — a new endpoint earns its way off this list by being
  # documented, never onto it.
  @pending_description ~w(
    account-me account-storage account-update apikeys-list apikeys-revoke
    attachments-batch-delete attachments-batch-move attachments-changes
    attachments-delete attachments-index attachments-rename attachments-upload
    connections-delete-device connections-delete-oauth connections-delete-pat
    folders-batch-delete folders-batch-move folders-create folders-delete
    folders-explicit folders-index folders-list folders-list-notes folders-rename
    notes-append notes-batch-delete notes-batch-move notes-batch-upsert
    notes-changes notes-delete notes-delete-by-id notes-rename notes-show
    notes-show-by-id notes-upsert search sync-changes tags
    vaults-create vaults-delete vaults-index vaults-restore vaults-show vaults-update
  )

  # Operations whose JSON request body still lacks a top-level `example`
  # (backfill follow-up). MUST ONLY SHRINK.
  @pending_request_example ~w(
    account-delete account-update apikeys-create
    attachments-batch-delete attachments-batch-move attachments-rename
    attachments-upload connections-create-pat
    folders-batch-delete folders-batch-move folders-rename
    notes-batch-delete notes-batch-move notes-batch-upsert notes-rename
    vaults-create vaults-register vaults-update
  )

  setup_all do
    %{spec: EngramWeb.ApiSpec.spec()}
  end

  defp operations(spec) do
    for {path, item} <- spec.paths,
        verb <- @verbs,
        op = Map.get(item, verb),
        not is_nil(op),
        do: {path, verb, op}
  end

  defp internal?(op), do: (op.extensions || %{})["x-internal"] == true

  defp id(op, path, verb), do: op.operationId || "#{verb} #{path}"

  # True when the operation carries a JSON request body.
  defp json_request_body?(%{requestBody: %RequestBody{content: content}})
       when is_map(content),
       do: Map.has_key?(content, "application/json")

  defp json_request_body?(_), do: false

  defp request_example?(%{requestBody: %RequestBody{content: content}}, spec) do
    case content["application/json"] do
      %MediaType{} = media -> media_example?(media, spec)
      _ -> false
    end
  end

  defp request_example?(_, _), do: false

  # A request example can sit on the media object directly, or (the common
  # case here) on the referenced request schema.
  defp media_example?(%MediaType{example: nil, schema: schema}, spec),
    do: schema_example?(schema, spec)

  defp media_example?(%MediaType{example: _present}, _spec), do: true

  defp schema_example?(%Reference{"$ref": ref}, spec) do
    title = ref |> String.split("/") |> List.last()
    schema_example?(spec.components.schemas[title], spec)
  end

  defp schema_example?(%{example: nil}, _spec), do: false
  defp schema_example?(%{example: _present}, _spec), do: true
  defp schema_example?(_, _spec), do: false

  test "every broadcast operation has a prose description", %{spec: spec} do
    missing =
      for {path, verb, op} <- operations(spec),
          not internal?(op),
          id(op, path, verb) not in @pending_description,
          not (is_binary(op.description) and op.description != "") do
        id(op, path, verb)
      end

    assert missing == [],
           "Operations missing a `description` — add one, or (only if truly " <>
             "internal) mark the operation `\"x-internal\": true`:\n" <>
             Enum.map_join(Enum.sort(missing), "\n", &"  - #{&1}")
  end

  test "every broadcast operation with a request body has a top-level example",
       %{spec: spec} do
    missing =
      for {path, verb, op} <- operations(spec),
          not internal?(op),
          json_request_body?(op),
          id(op, path, verb) not in @pending_request_example,
          not request_example?(op, spec) do
        id(op, path, verb)
      end

    assert missing == [],
           "Operations whose request body has no top-level `example` " <>
             "(add `example:` to the request schema):\n" <>
             Enum.map_join(Enum.sort(missing), "\n", &"  - #{&1}")
  end

  test "every schema-level example validates against its own schema", %{spec: spec} do
    invalid =
      for {title, schema} <- spec.components.schemas,
          ex = Map.get(schema, :example),
          not is_nil(ex),
          match?({:error, _}, OpenApiSpex.cast_value(ex, schema)) do
        title
      end

    assert invalid == [],
           "Schema examples that do not validate against their schema " <>
             "(the example rotted — fix it or the schema):\n" <>
             Enum.map_join(Enum.sort(invalid), "\n", &"  - #{&1}")
  end
end
