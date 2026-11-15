defmodule Engram.Links.QualifiedLinksPlanTest do
  # S5 gate arm 1 (`Links.qualified_links_query/4`, Engram#2523) planned as
  # prod runs it: as `engram_app` with the tenant set (FORCE RLS applies), in
  # a custom AND a forced generic plan (`QueryPlan.rls_plans/3`,
  # docs/context/rls-leakproof-index-quals.md).
  #
  # It must descend `note_links_basename_idx` on (user_id, vault_id,
  # target_basename_hmac), plain column quals RLS cannot bar, and read only
  # the moved basename's links, never the vault's. The bare-key test and the
  # stale arm are row filters on that basename's rows. `n_distinct = 40` on
  # the tenant columns costs a generic `vault_id = $n` as prod's hundreds of
  # tenants (notes-generic-plan-mis-pick.md). Not async: ALTER TABLE and the
  # role drop.
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.Links
  alias Engram.QueryPlan

  @basename :crypto.strong_rand_bytes(32)
  @bare for _ <- 1..3, do: :crypto.strong_rand_bytes(32)

  # 3,000 links on other basenames, plus 40 to `@basename`: 30 bare with
  # current keys, 4 qualified, 3 with a NULL key and 3 with a stale stamp.
  defp seed_links!(user, vault) do
    notes =
      Engram.Fixtures.insert_notes!(
        user,
        vault,
        for(_ <- 1..30, do: build(:note, path_hmac: :crypto.strong_rand_bytes(32)))
      )

    [u, v] = [Ecto.UUID.dump!(user.id), Ecto.UUID.dump!(vault.id)]
    ids = Enum.map(notes, &Ecto.UUID.dump!/1)
    stamp = "'\\x00'::bytea || '\\x" <> Base.encode16(Links.link_keys_version()) <> "'::bytea"

    Repo.query!(
      """
      INSERT INTO note_links (user_id, vault_id, source_note_id, target_text_ciphertext,
        target_text_nonce, target_basename_hmac, target_key_hmac, link_keys_stamp,
        link_type, position)
      SELECT $1, $2, s.id, '\\x00'::bytea, '\\x00'::bytea, decode(md5(s.id::text || p), 'hex'),
        decode(md5(s.id::text || p), 'hex'), #{stamp}, 'wikilink', p
      FROM unnest($3::uuid[]) AS s(id), generate_series(0, 99) AS p
      """,
      [u, v, ids]
    )

    # {key, stamp} per row to `@basename`, positions 100+ on the first note.
    insert_basename_rows!(u, v, hd(ids), basename_rows(30))
    hd(notes)
  end

  # One statement for any number of rows to `@basename`: `{key, state}` each,
  # positions from `from` on `source_id` (a dumped uuid).
  defp insert_basename_rows!(u, v, source_id, rows, from \\ 100) do
    version = Links.link_keys_version()
    {keys, states} = Enum.unzip(rows)
    stamps = Enum.map(states, &if(&1 == :stale, do: <<1>>, else: <<0>> <> version))

    Repo.query!(
      """
      INSERT INTO note_links (user_id, vault_id, source_note_id, target_text_ciphertext,
        target_text_nonce, target_basename_hmac, target_key_hmac, link_keys_stamp,
        link_type, position)
      SELECT $1, $2, $3, '\\x00'::bytea, '\\x00'::bytea, $4, r.key, r.stamp, 'wikilink', $7 + r.pos
      FROM unnest($5::bytea[], $6::bytea[]) WITH ORDINALITY AS r(key, stamp, pos)
      """,
      [u, v, source_id, @basename, keys, stamps, from]
    )
  end

  # `bare` rows with a current bare key, then 4 qualified, 3 with a NULL key
  # and 3 with a stale stamp.
  defp basename_rows(bare) do
    for(i <- 0..(bare - 1), do: {Enum.at(@bare, rem(i, 3)), :current}) ++
      for(_ <- 1..4, do: {:crypto.strong_rand_bytes(32), :current}) ++
      for(_ <- 1..3, do: {nil, :current}) ++
      for(_ <- 1..3, do: {Enum.at(@bare, 0), :stale})
  end

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    source = seed_links!(user, vault)

    Repo.query!("ALTER TABLE note_links ALTER COLUMN user_id SET (n_distinct = 40)")
    Repo.query!("ALTER TABLE note_links ALTER COLUMN vault_id SET (n_distinct = 40)")
    QueryPlan.fresh!("note_links")
    %{user: user, vault: vault, source: source}
  end

  test "reads note_links_basename_idx, the basename's rows only, in both plan modes", %{
    user: user,
    vault: vault
  } do
    query =
      user.id
      |> Links.qualified_links_query(vault.id, @basename, @bare)
      |> select([l], l.id)

    # 4 qualified + 3 NULL key + 3 stale; the 30 bare rows are filtered out.
    assert Repo.with_tenant!(user.id, fn -> Repo.all(query, skip_tenant_check: true) end)
           |> length() == 10

    {sql, params} = Repo.to_sql(:all, query)
    %{custom: custom, generic: generic} = QueryPlan.rls_plans(user.id, sql, params)

    for {mode, plan} <- [custom: custom, generic: generic] do
      assert plan =~ "note_links_basename_idx", "#{mode} plan:\n#{plan}"
      refute plan =~ "Seq Scan", "#{mode} plan:\n#{plan}"
      refute plan =~ "note_links_vault_id_index", "#{mode} plan:\n#{plan}"
      refute plan =~ "note_links_user_id_vault_id_source_note_id_index", "#{mode} plan:\n#{plan}"
      IO.puts("plan-proof qualified_links #{mode} buffers=#{QueryPlan.buffers(plan)}")
      # A few index pages plus the 40 rows' heap pages (one source note, so
      # one or two), never the vault's 3,040 links.
      assert QueryPlan.buffers(plan) <= 12, "#{mode}:\n#{plan}"
    end
  end

  # Staging 0.85.0 (hot basename, 628 links to one name): 368 buffers. The
  # same query at that scale as prod runs it: `engram_app`, tenant set,
  # custom and generic plans. A qual RLS cannot see through (non-leakproof
  # function on a column) would turn the descent into a vault scan, as the
  # notes by-path lookup did on 0.84.0 (`notes-generic-plan-mis-pick.md`).
  test "a hot basename (628 links) still descends note_links_basename_idx under RLS", %{
    user: user,
    vault: vault,
    source: source
  } do
    [u, v] = [Ecto.UUID.dump!(user.id), Ecto.UUID.dump!(vault.id)]
    # Setup left 40 rows to the basename (positions 100-139): 588 more.
    insert_basename_rows!(u, v, Ecto.UUID.dump!(source), basename_rows(578), 200)
    QueryPlan.fresh!("note_links")

    query =
      user.id
      |> Links.qualified_links_query(vault.id, @basename, @bare)
      |> select([l], l.id)

    # Setup's 10 non-bare rows plus this batch's 10.
    assert Repo.with_tenant!(user.id, fn -> Repo.all(query, skip_tenant_check: true) end)
           |> length() == 20

    {sql, params} = Repo.to_sql(:all, query)
    %{custom: custom, generic: generic} = QueryPlan.rls_plans(user.id, sql, params)

    for {mode, plan} <- [custom: custom, generic: generic] do
      assert plan =~ "note_links_basename_idx", "#{mode} plan:\n#{plan}"
      refute plan =~ "Seq Scan", "#{mode} plan:\n#{plan}"
      refute plan =~ "notes_user_vault_live", "#{mode} plan:\n#{plan}"
      refute plan =~ "note_links_vault_id_index", "#{mode} plan:\n#{plan}"
      IO.puts("plan-proof qualified_links hot #{mode} buffers=#{QueryPlan.buffers(plan)}")
      # Measured 20 here (the rows sit on a few heap pages; staging's
      # scattered rows read 368). 3x margin: a scan of the vault's 3,628
      # links reads several times this.
      assert QueryPlan.buffers(plan) <= 60, "#{mode}:\n#{plan}"
    end
  end
end
