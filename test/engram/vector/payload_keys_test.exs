defmodule Engram.Vector.PayloadKeysTest do
  use ExUnit.Case, async: true

  alias Engram.Vector.PayloadKeys

  test "no two logical names share a short key" do
    shorts = Enum.map(PayloadKeys.logical_names(), &PayloadKeys.short/1)
    assert length(shorts) == length(Enum.uniq(shorts))
  end

  test "every short key is 1 to 2 characters and decodes back" do
    for name <- PayloadKeys.logical_names() do
      short = PayloadKeys.short(name)
      assert String.length(short) in 1..2, "#{name} -> #{short}"
      assert PayloadKeys.long(short) == name
    end
  end

  test "pins the approved short-key map" do
    assert Map.new(PayloadKeys.logical_names(), &{&1, PayloadKeys.short(&1)}) == %{
             user_id: "u",
             vault_id: "v",
             path_id: "p",
             folder_id: "f",
             type_id: "y",
             tags_id: "g",
             status_id: "s",
             author_id: "a",
             rev_by_id: "r",
             src_id: "o",
             proj_id: "j",
             fm_timestamp: "up",
             fm_created: "cr",
             fm_reviewed: "rd",
             fm_expires: "ex",
             fm_due: "du",
             fm_priority: "pr",
             fm_attrs: "fa",
             fm_timestamp_src: "us",
             fm_created_src: "cs",
             note: "n"
           }
  end

  # `n` is the point's note: identity, not metadata. A payload refresh drops
  # the known keys its payload omits (`Qdrant.overwrite_payload/3`), so `n`
  # must never be one of them, or a release that does not write `n` strips
  # it from every point a newer node stamped.
  test "n is never a key a payload refresh deletes" do
    refute "n" in PayloadKeys.note_keys()
  end

  test "an unknown logical name raises instead of writing a long key" do
    assert_raise KeyError, fn -> PayloadKeys.short(:note_id) end
  end

  test "the payload index list uses only short keys" do
    allowed = MapSet.new(PayloadKeys.logical_names(), &PayloadKeys.short/1)

    for {field, _schema} <- PayloadKeys.index_fields() do
      [top | _] = String.split(field, ".")
      assert MapSet.member?(allowed, String.trim_trailing(top, "[]")), field
    end

    refute Enum.any?(PayloadKeys.index_fields(), fn {f, _} -> f =~ "note_id" end)
  end
end
