defmodule Engram.Vector.QdrantMissingPointIdsTest do
  @moduledoc """
  Point ids taken from `chunks` rows can name a point Qdrant no longer holds
  (an orphaned row). A payload write over such a list must still land on the
  points that exist and return `:ok`, or the reused-point payload refresh
  fails for any user with one orphan. Bypass answers 200 to
  anything, so only a real Qdrant shows what a missing id does.
  """
  use ExUnit.Case, async: false

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  @moduletag :qdrant_integration

  @dims 8

  setup do
    ServiceConfig.put_override(:qdrant_url, qdrant_url())

    col =
      "engram_missing_ids_#{System.get_env("MIX_TEST_PARTITION")}_#{System.unique_integer([:positive])}"

    :ok = Qdrant.ensure_collection(col, @dims)
    Engram.QdrantIntegration.drop_on_exit(col)

    live = Ecto.UUID.generate()

    :ok =
      Qdrant.upsert_points(col, [
        %{id: live, vector: %{"dense" => List.duplicate(0.1, @dims)}, payload: %{"a" => 1}}
      ])

    %{col: col, live: live, missing: Ecto.UUID.generate()}
  end

  test "set_payload merges onto the live point and skips a missing id", ctx do
    assert :ok = Qdrant.set_payload(ctx.col, [ctx.missing, ctx.live], %{"b" => 2})
    assert payload(ctx.col, ctx.live) == %{"a" => 1, "b" => 2}
  end

  test "a list of only missing ids is a no-op", ctx do
    assert :ok = Qdrant.set_payload(ctx.col, [ctx.missing], %{"b" => 2})
    assert payload(ctx.col, ctx.live) == %{"a" => 1}
  end

  defp payload(col, id) do
    {:ok, %{status: 200, body: %{"result" => [point]}}} =
      Req.post("#{qdrant_url()}/collections/#{col}/points",
        json: %{ids: [id], with_payload: true, with_vector: false}
      )

    point["payload"]
  end

  defp qdrant_url do
    System.get_env("QDRANT_URL") ||
      Application.get_env(:engram, :qdrant_url, "http://localhost:6333")
  end
end
