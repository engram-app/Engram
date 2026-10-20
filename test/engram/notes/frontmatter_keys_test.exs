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

  test "rotation keeps every id, rekeys the HMAC and keeps the name readable",
       %{user: u, dek: dek, fk: fk} do
    {ids, 0} = FrontmatterKeys.resolve(u.id, dek, names(fk, ~w(Mood rating)))
    new_dek = :crypto.strong_rand_bytes(32)
    new_fk = Crypto.dek_filter_key_from_bytes(new_dek)

    assert :ok = FrontmatterKeys.rotate(u.id, dek, new_dek, new_fk)
    # Idempotent: a second run (rows already under the new DEK) changes nothing.
    assert :ok = FrontmatterKeys.rotate(u.id, dek, new_dek, new_fk)

    by_id = Map.new(rows(u.id), &{&1.key_id, &1})
    assert Map.keys(by_id) |> Enum.sort() == ids |> Map.values() |> Enum.sort()

    mood = by_id[ids[FilterId.key_hmac(fk, "mood")]]
    assert mood.key_hmac == FilterId.key_hmac(new_fk, "mood")
    assert FrontmatterKeys.name(mood, new_dek) == {:ok, "Mood"}
    assert FrontmatterKeys.name(mood, dek) == :error
  end
end
