defmodule Engram.Notes.FieldCatalogTest do
  @moduledoc """
  The per-vault field catalog: every frontmatter field a vault uses, derived
  on read from `note_attrs` + `frontmatter_keys` (no stored counters).
  """
  use Engram.DataCase, async: false

  import Engram.FieldCatalogHelpers
  import ExUnit.CaptureLog

  alias Engram.Notes
  alias Engram.Notes.FieldCatalog
  alias Engram.Repo

  setup do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    {:ok, user: user, vault: vault}
  end

  defp field(fields, name), do: Enum.find(fields, &(&1.name == name))

  defp seed!(user, vault) do
    write_indexed!(user, vault, "a.md", """
    ---
    type: Playbook
    tags: [alpha, beta]
    status: draft
    priority: 2
    due: 2026-11-01
    Mood: calm
    rating: 4.5
    flag: true
    launch: 2026-10-01T12:30:00Z
    colors: [red, blue]
    ---
    body
    """)

    write_indexed!(user, vault, "b.md", """
    ---
    tags: [alpha]
    status: draft
    priority: 5
    Mood: tense
    rating: 1
    flag: false
    ---
    body
    """)

    write_indexed!(user, vault, "c.md", """
    ---
    status: done
    mood: calm
    ---
    body
    """)
  end

  test "an empty vault has no fields", %{user: user, vault: vault} do
    assert {:ok, []} = FieldCatalog.list(user, vault)
  end

  test "named and user-added fields with kinds, counts, ranges and top values",
       %{user: user, vault: vault} do
    seed!(user, vault)
    assert {:ok, fields} = FieldCatalog.list(user, vault)

    status = field(fields, "status")
    assert status.kinds == ["string"]
    assert status.note_count == 3
    assert status.list == false
    assert status.values == [%{value: "draft", count: 2}, %{value: "done", count: 1}]

    assert %{kinds: ["string"], note_count: 2, list: true} = tags = field(fields, "tags")
    assert tags.values == [%{value: "alpha", count: 2}, %{value: "beta", count: 1}]

    assert %{values: [%{value: "Playbook", count: 1}]} = field(fields, "type")

    # The display name is the key as first written; the filter matches any case.
    mood = field(fields, "Mood")
    assert mood.note_count == 3
    assert mood.values == [%{value: "calm", count: 2}, %{value: "tense", count: 1}]
    refute field(fields, "mood")

    assert %{kinds: ["number"], number_range: %{min: 2.0, max: 5.0}, values: []} =
             field(fields, "priority")

    assert %{kinds: ["number"], number_range: %{min: 1.0, max: 4.5}} = field(fields, "rating")

    assert %{kinds: ["date"], date_range: %{min: "2026-11-01", max: "2026-11-01"}} =
             field(fields, "due")

    assert %{date_range: %{min: "2026-10-01T12:30:00Z"}} = field(fields, "launch")

    assert %{kinds: ["boolean"], note_count: 2} = flag = field(fields, "flag")
    assert Enum.sort(Enum.map(flag.values, & &1.value)) == ["false", "true"]

    assert %{list: true, note_count: 1} = field(fields, "colors")

    # Most-used first.
    assert hd(fields).note_count == 3
  end

  test "soft-deleted notes do not count", %{user: user, vault: vault} do
    seed!(user, vault)
    :ok = Notes.delete_note(user, vault, "c.md")

    assert {:ok, fields} = FieldCatalog.list(user, vault)
    assert %{note_count: 2, values: [%{value: "draft", count: 2}]} = field(fields, "status")
  end

  test "another vault's notes do not count", %{user: user, vault: vault} do
    seed!(user, vault)
    other = insert(:vault, user: user)
    write_indexed!(user, other, "x.md", "---\nstatus: draft\nonly_there: x\n---\nbody\n")

    assert {:ok, fields} = FieldCatalog.list(user, vault)
    assert field(fields, "status").note_count == 3
    refute field(fields, "only_there")
  end

  test "top values are capped at 50 per field", %{user: user, vault: vault} do
    values = Enum.map_join(1..55, ", ", &"v#{&1}")
    write_indexed!(user, vault, "many.md", "---\nmany: [#{values}]\n---\nbody\n")

    assert {:ok, [many]} = FieldCatalog.list(user, vault)
    assert many.name == "many"
    assert length(many.values) == 50
  end

  test "the cache answers until the vault's change_seq moves", %{user: user, vault: vault} do
    note = seed!(user, vault)
    {:ok, first} = FieldCatalog.list(user, vault)

    # A note_attrs row written without a seq bump (the index pass) is not seen
    # until that pass evicts the entry ...

    Repo.insert_all(
      Engram.Notes.NoteAttr,
      [
        %{
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          key_id: 12,
          ord: 5,
          n: 99.0
        }
      ],
      skip_tenant_check: true,
      on_conflict: :nothing
    )

    assert {:ok, ^first} = FieldCatalog.list(user, vault)

    FieldCatalog.evict(vault.id)
    {:ok, evicted} = FieldCatalog.list(user, vault)
    refute evicted == first

    # ... and a note write moves the seq, so the old entry is never read again.
    write_indexed!(user, vault, "d.md", "---\nfresh: yes\n---\nbody\n")
    {:ok, after_write} = FieldCatalog.list(user, vault)
    assert field(after_write, "fresh")
  end

  test "a new seq replaces the vault's entry instead of adding one", %{user: user, vault: vault} do
    seed!(user, vault)
    {:ok, _} = FieldCatalog.list(user, vault)
    write_indexed!(user, vault, "d.md", "---\nfresh: yes\n---\nbody\n")
    {:ok, _} = FieldCatalog.list(user, vault)

    table = Engram.Cache.Registry.table(:field_catalog)
    assert [_one] = :ets.match_object(table, {{vault.id, :_}, :_, :_})
  end

  test "a catalog built while a decrypt failed is not cached", %{user: user, vault: vault} do
    write_indexed!(user, vault, "a.md", "---\nmood: calm\n---\nbody\n")
    key = Repo.one!(Engram.Notes.FrontmatterKey, skip_tenant_check: true)
    good = Map.take(key, [:name_ct, :name_nonce])

    set = fn fields ->
      Repo.update_all(
        Ecto.Query.where(Engram.Notes.FrontmatterKey, user_id: ^user.id),
        [set: Map.to_list(fields)],
        skip_tenant_check: true
      )
    end

    set.(%{name_ct: "garbage-ciphertext"})
    FieldCatalog.evict(vault.id)

    log = capture_log(fn -> assert {:ok, []} = FieldCatalog.list(user, vault) end)
    assert log =~ "field_catalog_key_decrypt_failed"

    # Repaired without a seq move: the partial result must not be served.
    set.(good)
    assert {:ok, [%{name: "mood"}]} = FieldCatalog.list(user, vault)
  end

  test "a user without a DEK has no fields", %{vault: vault} do
    assert {:ok, []} = FieldCatalog.list(insert(:user), vault)
  end

  test "names and values are never logged", %{user: user, vault: vault} do
    seed!(user, vault)
    FieldCatalog.evict(vault.id)

    log = capture_log([level: :debug], fn -> {:ok, _} = FieldCatalog.list(user, vault) end)
    refute log =~ "calm"
    refute log =~ "Mood"
  end

  # Both aggregates must be index-only scans of the partial note_attrs
  # indexes, as the RLS-enforced app role sees them: the policy reads
  # `user_id`, so an index without it cannot answer from the index alone.
  test "the aggregates are index-only scans under RLS", %{user: user, vault: vault} do
    seed!(user, vault)
    [{stats, params}, {values, params}] = FieldCatalog.explain_queries(vault.id)

    for {sql, indexes} <- [{stats, ~w(h n d)}, {values, ~w(h)}] do
      plan = plan!(user, sql, params)

      for col <- indexes,
          do:
            assert(plan =~ "Index Only Scan using note_attrs_vault_id_key_id_#{col}_index", plan)

      refute plan =~ ~r/(?<!Only )Scan using note_attrs/, plan
    end
  end

  defp plan!(user, sql, params) do
    assert {:returned, plan} =
             Engram.RlsCase.as_prod_role(fn ->
               Repo.query!("SELECT set_config('app.current_tenant', $1, true)", [user.id])
               Repo.query!("SET LOCAL enable_seqscan = off")
               Repo.query!("SET LOCAL enable_bitmapscan = off")
               Repo.query!("EXPLAIN " <> sql, params).rows |> List.flatten() |> Enum.join("\n")
             end)

    plan
  end
end
