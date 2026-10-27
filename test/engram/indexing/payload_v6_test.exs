defmodule Engram.Indexing.PayloadV6Test do
  @moduledoc """
  Parity: the payload built from Postgres rows equals the payload built from
  the extracted note body, over a corpus of frontmatter shapes.
  """
  use ExUnit.Case, async: true

  alias Engram.Crypto
  alias Engram.Indexing.PayloadV6
  alias Engram.Notes.{FlatFields, Note}

  @fk :binary.copy(<<7>>, 32)
  @user "11111111-1111-1111-1111-111111111111"
  @vault "22222222-2222-2222-2222-222222222222"
  @folder "33333333-3333-3333-3333-333333333333"

  @corpus %{
    "string" => "---\nstatus: draft\nauthor: Ada\nmood: calm\n---\nBody",
    "number" => "---\npriority: 3\nrating: 4.5\nlevel: 7\n---\nBody",
    "date" => "---\nupdated: 2026-10-01T10:00:00Z\ndue: 2026-11-01\nreleased: 2026-01-05\n---\nB",
    "list" => "---\nsource: [a, b, c]\nlabels: [x, y]\n---\nBody",
    "bool" => "---\nstatus: stable\npublished: true\n---\nBody",
    "nested tags" => "---\ntags: [a/b, a/b/c, plain]\ntype: Playbook\n---\nBody",
    "empty frontmatter" => "---\n---\nBody",
    "no frontmatter" => "# Just a heading\n\nBody",
    "unicode keys" => "---\nstimmung: fröhlich\n日本語: 値\nmood: 😀\n---\nBody",
    "many user keys" => "---\nzeta: 1\nalpha: two\nbeta: 2026-02-03\ngamma: [q, r]\n---\nBody"
  }

  for {name, content} <- @corpus, folder <- [nil, @folder] do
    test "parity: #{name}, folder #{inspect(folder)}" do
      note = note(unquote(folder))
      flat = unquote(content) |> FlatFields.extract(@fk) |> with_key_ids()
      rows = FlatFields.attr_rows(flat, note)

      assert PayloadV6.build_from_rows(note, shuffle(rows), @fk) == PayloadV6.build(note, flat)
    end
  end

  test "f is the folder row id; a root note has no f" do
    flat = FlatFields.empty()
    assert %{"f" => "33333333333333333333333333333333"} = PayloadV6.build(note(@folder), flat)
    refute PayloadV6.build(note(nil), flat) |> Map.has_key?("f")
  end

  test "no rows: the extracting path answers" do
    note = note(@folder)
    flat = "---\nstatus: draft\n---\nB" |> FlatFields.extract(@fk) |> with_key_ids()

    assert PayloadV6.from_rows_or_extract(note, [], @fk, fn -> flat end) ==
             PayloadV6.build(note, flat)
  end

  test "rows present: the extracting path is not called" do
    note = note(nil)
    flat = "---\nauthor: Ada\n---\nB" |> FlatFields.extract(@fk) |> with_key_ids()
    rows = FlatFields.attr_rows(flat, note)

    assert PayloadV6.from_rows_or_extract(note, rows, @fk, fn -> flunk("extracted") end) ==
             PayloadV6.build(note, flat)
  end

  defp note(folder_ref_id) do
    %Note{
      id: "44444444-4444-4444-4444-444444444444",
      user_id: @user,
      vault_id: @vault,
      folder_ref_id: folder_ref_id,
      path_hmac: Crypto.hmac_field(@fk, "p"),
      folder_hmac: Crypto.hmac_field(@fk, "f"),
      type_hmac: Crypto.hmac_field(@fk, "playbook"),
      tags_hmac: for(t <- ~w(a/b a/b/c plain), do: Crypto.hmac_field(@fk, t)),
      mtime: 1_700_000_000.0,
      updated_at: ~U[2026-10-02 00:00:00.000000Z],
      created_at: ~U[2026-10-01 00:00:00.000000Z]
    }
  end

  # The dictionary: a distinct id per user-added key, past the reserved ones.
  defp with_key_ids(flat) do
    ids = flat.names |> Map.keys() |> Enum.sort() |> Enum.with_index(100) |> Map.new()
    FlatFields.put_key_ids(flat, ids)
  end

  defp shuffle(rows), do: Enum.shuffle(rows)
end
