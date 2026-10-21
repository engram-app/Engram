defmodule Engram.Notes.NoteKeysTest do
  # Wave 3 readers: once the NoteSplit ledger is done, lookups filter on the
  # 16-byte ids and use the (vault_id, ...) partial indexes. Same answers as
  # the HMAC form (the full suites pass in both modes); this pins the plans.
  #
  # Not async: the mode is a node-wide cache entry, and an async neighbour
  # matching an HMAC statement must not see it flip.
  use Engram.DataCase, async: false

  alias Engram.DataMigrations
  alias Engram.Links
  alias Engram.Notes
  alias Engram.Notes.Keys
  alias Engram.QueryPlan
  alias Engram.QueryRecorder

  setup do
    on_exit(fn ->
      Engram.Cache.clear_local(:note_split)
      DataMigrations.reset_cache()
    end)

    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Keys", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp ids_on! do
    :ok = DataMigrations.mark_done("note_split", 1)
    Engram.Cache.clear_local(:note_split)
    assert Keys.ids?()
  end

  defp write!(user, vault, path, content \\ "x") do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    note
  end

  defp mine(queries), do: Enum.filter(queries, &(&1.pid == self()))

  defp plan_of(queries, pattern) do
    [sql | _] = for %{sql: sql} <- mine(queries), sql =~ pattern, do: sql
    QueryPlan.generic_plan(sql)
  end

  test "the mode follows the ledger", %{user: u, vault: v} do
    refute Keys.ids?()
    note = write!(u, v, "a.md")
    ids_on!()
    assert {:ok, %{id: id}} = Notes.get_note(u, v, "a.md")
    assert id == note.id
  end

  test "the ids go off when another node reopens the ledger" do
    :ok = DataMigrations.mark_done("note_split", 1)
    # This node has seen it done: `done?/2` keeps that for the node's lifetime.
    assert DataMigrations.done?("note_split", 1)
    Engram.Cache.clear_local(:note_split)
    assert Keys.ids?()

    # Another node's re-verify reopens it: the row changes, this node's
    # cached `done?/2` term does not. The ids must still go off here.
    Engram.Repo.query!("UPDATE data_migrations SET completed_at = NULL WHERE name = 'note_split'")
    assert DataMigrations.done?("note_split", 1)
    Engram.Cache.clear_local(:note_split)
    refute Keys.ids?()
  end

  test "a passed mode picks the column, not the cache" do
    hmac = :crypto.strong_rand_bytes(32)
    refute Keys.ids?()

    assert inspect(Keys.eq(:path, hmac, true)) =~ "path_id"
    assert inspect(Keys.in_any(:folder, [hmac], true)) =~ "folder_id"
    assert inspect(Keys.eq(:path, hmac, false)) =~ "path_hmac"
    assert inspect(Keys.kind_match(:note, true)) =~ "is_folder"
    assert inspect(Keys.kind_match(:note, false)) == inspect(dynamic(true))
  end

  # One test, seeded once: the plans only mean something on a vault big
  # enough that selectivity, not a tiny table's cost ties, picks the index
  # (as NotesPathIndexPlanTest). The decoys' ciphertext is not real; only the
  # planner reads them.
  test "each id lookup reads its (vault_id, ...) partial index", %{user: u, vault: v} do
    target = write!(u, v, "deep/Target.md")
    write!(u, v, "F/one.md")
    write!(u, v, "t.md", "---\ntype: idea\n---\nx")
    write!(u, v, "gone.md", "body")
    :ok = Notes.delete_note(u, v, "gone.md")
    {:ok, _} = Notes.create_folder_marker(u, v, "Marked")

    for _ <- 1..1000 do
      insert(:note,
        user: u,
        vault: v,
        path_hmac: :crypto.strong_rand_bytes(32),
        folder_hmac: :crypto.strong_rand_bytes(32),
        basename_hmac: :crypto.strong_rand_bytes(32)
      )
    end

    Engram.Repo.query!("ANALYZE notes")
    ids_on!()

    plan = fn fun, pattern ->
      {result, qs} = QueryRecorder.record(fun)
      {result, plan_of(qs, pattern)}
    end

    {{:ok, %{id: id}}, p} =
      plan.(fn -> Notes.get_note(u, v, "deep/Target.md") end, ~r/"path_id" = \$/)

    assert id == target.id
    assert p =~ "notes_path_live", p

    {ids, p} =
      plan.(fn -> Notes.note_ids_for_paths(u, nil, ["F/one.md"]) end, ~r/"path_id" = ANY/)

    assert Map.keys(ids) == ["F/one.md"]
    assert p =~ "notes_path_live", p

    {{:ok, [one]}, p} =
      plan.(fn -> Notes.list_notes_in_folder(u, v, "F") end, ~r/"folder_id" = \$/)

    assert one.path == "F/one.md"
    assert p =~ "notes_folder", p

    {_, p} =
      plan.(fn -> Notes.create_folder_marker(u, v, "Marked") end, ~r/"folder_id" (= ANY|=)/)

    # Tombstoned markers too (an undelete), so the non-partial folder index.
    assert p =~ "notes_folder", p

    {_, p} =
      plan.(
        fn ->
          Notes.upsert_note(u, v, %{"path" => "gone.md", "content" => "body"}, actor: "api")
        end,
        ~r/"path_id" = \$\d+.*NOT \(\w+\."deleted_at" IS NULL\)/s
      )

    assert p =~ "notes_path_tomb", p

    {resolved, p} =
      plan.(fn -> Links.resolve_target(u, v, "Target", "wikilink") end, ~r/"basename_id" = ANY/)

    assert resolved == {:note, target.id}
    assert p =~ "notes_basename", p

    {{:ok, types}, p} = plan.(fn -> Notes.list_types(u, v) end, ~r/"type_id" IS NULL/)
    assert types == ["idea"]
    assert p =~ "notes_type", p
  end

  test "the index literal is this runtime's Unicode code" do
    # notes_link_keys_stale inlines 1501; a Unicode upgrade must rebuild it.
    assert Links.link_keys_code() == 1501
  end
end
