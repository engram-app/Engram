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

  # R3b: a collection indexes the identity keys only; the note belts match
  # by `n` alone.
  test "the v5 index list is u, v and n" do
    assert Enum.map(PayloadKeys.index_fields(), &elem(&1, 0)) |> Enum.sort() == ~w(n u v)
  end

  # R3b: every field an earlier release indexed and no reader filters on.
  test "retired_index_fields names every pre-R3b index but the tenant and n" do
    retired = PayloadKeys.retired_index_fields()

    assert Enum.sort(retired) ==
             Enum.sort(
               ~w(p f y g s a r o j up cr rd ex du pr fa[].k fa[].h fa[].n fa[].d) ++
                 ~w(path_hmac type_hmac folder_hmac tags_hmac note_id fm_timestamp fm_created)
             )

    for {field, _} <- PayloadKeys.index_fields(), do: refute(field in retired)
    for field <- ~w(user_id vault_id), do: refute(field in retired)
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
