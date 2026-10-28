defmodule Engram.WindowedReadsTest do
  # The #2276 oracle must flag "rare predicate + keyset + LIMIT" on its own,
  # not because the old queries happened to carry an EXISTS.
  use ExUnit.Case, async: true

  alias Engram.WindowedReads

  @ids [Ecto.UUID.generate(), Ecto.UUID.generate()]

  defp windowed?(sql, params), do: WindowedReads.windowed?(sql, params, "notes", 1_000)

  describe "flags the bug shape" do
    test "the old NoteIndexState fill, EXISTS stripped" do
      refute windowed?(
               """
               SELECT n.id::text, note_index_state_sync(n, false) FROM notes n
               WHERE n.kind = 'note'
                 AND ($1::uuid IS NULL OR n.user_id = $1::uuid)
                 AND ($2::uuid IS NULL OR n.id > $2::uuid)
               ORDER BY n.id LIMIT $3
               """,
               [nil, nil, 1_000]
             )
    end

    test "the old NoteIndexState recount, EXISTS stripped" do
      refute windowed?(
               """
               SELECT n.id::text FROM notes n JOIN note_index_state s ON s.note_id = n.id
               WHERE n.kind = 'note'
                 AND ($1::uuid IS NULL OR n.user_id = $1::uuid)
                 AND s.points <> 0
                 AND ($2::uuid IS NULL OR n.id > $2::uuid)
               ORDER BY n.id LIMIT $3
               """,
               [nil, nil, 1_000]
             )
    end

    test "the old NoteSplit needing, EXISTS stripped" do
      refute windowed?(
               ~s|SELECT n0."id" FROM "notes" AS n0 WHERE (n0."is_folder" IS NULL) | <>
                 ~s|AND (n0."user_id" = $1::uuid) AND (n0."id" > $2::uuid) | <>
                 ~s|ORDER BY n0."id" LIMIT $3 FOR UPDATE SKIP LOCKED|,
               [Ecto.UUID.generate(), Ecto.UUID.generate(), 1_000]
             )
    end

    test "a plain column predicate with a keyset LIMIT" do
      refute windowed?(
               ~s|SELECT n0."id" FROM "notes" AS n0 WHERE (n0."keyword_version" <> $1) | <>
                 ~s|AND (n0."id" > $2) ORDER BY n0."id" LIMIT $3|,
               [3, Ecto.UUID.generate(), 1_000]
             )
    end

    test "a window term ORed with an unbounded branch" do
      refute windowed?(
               ~s|SELECT n0."id" FROM "notes" AS n0 WHERE (n0."id" = ANY($1)) OR (n0."kind" = 'x')|,
               [@ids]
             )
    end

    test "a second, unbounded notes source joined in" do
      refute windowed?(
               "SELECT 1 FROM notes n JOIN notes m ON m.vault_id = n.vault_id " <>
                 "WHERE n.id = ANY($1::uuid[])",
               [@ids]
             )
    end

    test "a window larger than allowed" do
      refute windowed?(
               ~s|SELECT n0."id" FROM "notes" AS n0 WHERE (n0."id" > $1) ORDER BY n0."id" LIMIT $2|,
               [Ecto.UUID.generate(), 5_000]
             )
    end

    test "a single EXISTS over the table" do
      refute windowed?(~s|SELECT TRUE FROM "notes" AS n0 WHERE (n0."id" = $1) LIMIT 1|, [
               Ecto.UUID.generate()
             ])
    end
  end

  describe "passes a window" do
    test "the IdWindows read, fleet and per user" do
      assert windowed?(
               ~s|SELECT n0."id" FROM "notes" AS n0 WHERE (n0."id" > $1) ORDER BY n0."id" LIMIT $2|,
               [Ecto.UUID.generate(), 1_000]
             )

      assert windowed?(
               ~s|SELECT n0."id" FROM "notes" AS n0 WHERE (n0."id" > $1) | <>
                 ~s|AND (n0."user_id" = $2) ORDER BY n0."id" LIMIT $3|,
               [Ecto.UUID.generate(), Ecto.UUID.generate(), 200]
             )
    end

    test "a predicate confined to the window's ids" do
      assert windowed?(
               "SELECT n.id::text FROM notes n LEFT JOIN note_index_state s ON s.note_id = n.id " <>
                 "WHERE n.id = ANY($1::uuid[]) AND n.kind = 'note'",
               [@ids]
             )

      assert windowed?("SELECT id::text FROM notes WHERE id = ANY($1::uuid[]) FOR UPDATE", [@ids])
    end

    test "a statement that reads no notes" do
      assert windowed?("SELECT 1 FROM users", [])
    end
  end
end
