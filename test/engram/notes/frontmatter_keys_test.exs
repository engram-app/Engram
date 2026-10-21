defmodule Engram.Notes.FrontmatterKeysTest do
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Notes.FrontmatterKey
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.Vector.FilterId

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, fk} = Crypto.dek_filter_key(user)
    %{user: user, dek: dek, fk: fk}
  end

  defp names(fk, keys), do: Map.new(keys, &{FilterId.key_hmac(fk, &1), &1})

  defp rows(user_id),
    do:
      Repo.all(from(k in FrontmatterKey, where: k.user_id == ^user_id, order_by: k.key_id),
        skip_tenant_check: true
      )

  test "named fields have reserved constant ids 0..12, user keys start at 64" do
    assert FrontmatterKeys.named() |> Map.values() |> Enum.sort() == Enum.to_list(0..12)
    assert FrontmatterKeys.named_id(:status) == 2
    assert FrontmatterKeys.first_user_id() == 64
  end

  test "allocates densely from 64, stably, and appends new keys", %{user: u, dek: dek, fk: fk} do
    {ids, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ~w(mood rating launch)))
    assert ids |> Map.values() |> Enum.sort() == [64, 65, 66]

    assert {^ids, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ~w(mood rating launch)))

    {more, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ~w(mood phase)))
    assert more[FilterId.key_hmac(fk, "mood")] == ids[FilterId.key_hmac(fk, "mood")]
    assert more[FilterId.key_hmac(fk, "phase")] == 67
  end

  test "the key is case-insensitive; the stored name is the first-seen casing",
       %{user: u, dek: dek, fk: fk} do
    {ids, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ["Mood"]))
    {same, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ["mood"]))
    assert ids == same

    [row] = rows(u.id)
    assert FrontmatterKeys.name(row, dek) == {:ok, "Mood"}
    refute row.name_ct =~ "Mood"
  end

  test "the name is bound to its user and key id", %{user: u, dek: dek, fk: fk} do
    {_, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ["mood"]))
    [row] = rows(u.id)
    assert FrontmatterKeys.name(%{row | key_id: 65}, dek) == :error
    assert FrontmatterKeys.name(%{row | user_id: Ecto.UUID.generate()}, dek) == :error
  end

  test "past the cap new keys are skipped and counted, never an error",
       %{user: u, dek: dek, fk: fk} do
    ServiceConfig.put_override(:frontmatter_key_cap, 2)
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :frontmatter_keys, :skipped]])

    {ids, 1} = FrontmatterKeys.resolve(u.id, dek, names(fk, ~w(a b c)))
    assert map_size(ids) == 2
    assert_received {[:engram, :frontmatter_keys, :skipped], ^ref, %{count: 1}, _}

    {again, 1} = FrontmatterKeys.resolve(u.id, dek, names(fk, ~w(a b c)))
    assert again == ids
  end

  test "lookup resolves known keys in one query and never allocates",
       %{user: u, dek: dek, fk: fk} do
    {ids, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ["mood"]))
    hmacs = Map.keys(names(fk, ~w(mood unknown)))
    assert FrontmatterKeys.lookup(u.id, hmacs) == ids
    assert length(rows(u.id)) == 1
  end

  defp attr!(user, key_id, value \\ %{n: 1.0}) do
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)

    Repo.insert_all(
      Engram.Notes.NoteAttr,
      [
        Map.merge(
          %{note_id: note.id, user_id: user.id, vault_id: vault.id, key_id: key_id, ord: 0},
          value
        )
      ],
      skip_tenant_check: true
    )
  end

  defp age!(user_id) do
    Repo.query!(
      "UPDATE frontmatter_keys SET inserted_at = now() - interval '2 days' WHERE user_id = $1",
      [Ecto.UUID.dump!(user_id)]
    )
  end

  describe "reap_unused/1 (M3: ids never reused, cap counts live keys)" do
    test "deletes old unused keys, keeps used ones, young ones and the highest id",
         %{user: u, dek: dek, fk: fk} do
      {ids, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ~w(a b c d)))
      id = &ids[FilterId.key_hmac(fk, &1)]
      attr!(u, id.("b"))
      age!(u.id)
      {_, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ["young"]))

      # a, c and d go; b is used, and `young` is both too new and the highest.
      assert FrontmatterKeys.reap_unused() == 3
      assert Enum.map(rows(u.id), & &1.key_id) == Enum.sort([id.("b"), 68])
    end

    # N2: one NOT EXISTS per value column (each served by its partial
    # index), so a key used only as h, only as n or only as d all survive.
    test "a key used in any value column survives", %{user: u, dek: dek, fk: fk} do
      {ids, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ~w(h n d top)))
      id = &ids[FilterId.key_hmac(fk, &1)]
      top = Enum.max(Map.values(ids))
      used = Enum.reject(~w(h n d), &(id.(&1) == top))
      values = %{"h" => %{h: "x"}, "n" => %{n: 1.0}, "d" => %{d: 1}}
      for name <- used, do: attr!(u, id.(name), values[name])
      age!(u.id)

      assert FrontmatterKeys.reap_unused() == 4 - 1 - length(used)
      kept = Enum.map(rows(u.id), & &1.key_id)
      for name <- used, do: assert(id.(name) in kept, name)
    end

    # N3: a user mid DEK rotation is skipped; the rotation sweep owns the rows.
    test "a user mid rotation is skipped", %{user: u, dek: dek, fk: fk} do
      {_, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ~w(a b)))
      age!(u.id)

      Repo.query!("UPDATE users SET dek_rotation_locked_at = now() WHERE id = $1", [
        Ecto.UUID.dump!(u.id)
      ])

      assert FrontmatterKeys.reap_unused() == 0
      assert length(rows(u.id)) == 2
    end

    test "a reaped id is never handed out again", %{user: u, dek: dek, fk: fk} do
      {ids, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ~w(a b)))
      [reaped] = for name <- ~w(a b), ids[FilterId.key_hmac(fk, name)] == 64, do: name
      age!(u.id)
      assert FrontmatterKeys.reap_unused() == 1
      assert Enum.map(rows(u.id), & &1.key_id) == [65]

      {again, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, [reaped]))
      assert again[FilterId.key_hmac(fk, reaped)] == 66
    end

    test "reaping frees cap space", %{user: u, dek: dek, fk: fk} do
      ServiceConfig.put_override(:frontmatter_key_cap, 2)
      {_, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ~w(a b)))
      assert {_, 1} = FrontmatterKeys.resolve(u.id, dek, names(fk, ["c"]))
      assert FrontmatterKeys.at_limit?(u.id)

      age!(u.id)
      assert FrontmatterKeys.reap_unused() == 1
      refute FrontmatterKeys.at_limit?(u.id)
      assert {ids, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ["c"]))
      assert map_size(ids) == 1
    end
  end

  test "at the smallint max new keys are skipped and counted", %{user: u, dek: dek, fk: fk} do
    {ct, nonce} =
      Engram.Crypto.Envelope.encrypt("top", dek, FrontmatterKeys.name_aad(u.id, 32_767))

    Repo.insert_all(
      FrontmatterKey,
      [%{user_id: u.id, key_id: 32_767, key_hmac: "top", name_ct: ct, name_nonce: nonce}],
      skip_tenant_check: true
    )

    assert {ids, 1} = FrontmatterKeys.resolve(u.id, dek, names(fk, ["new"]))
    assert ids == %{}
    assert FrontmatterKeys.at_limit?(u.id)
  end

  test "the cap is clamped to what a smallint id can hold" do
    ServiceConfig.put_override(:frontmatter_key_cap, 1_000_000)
    assert FrontmatterKeys.cap() == 32_767 - 64 + 1
  end
end
