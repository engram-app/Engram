defmodule Engram.Notes.FrontmatterKeys do
  @moduledoc """
  The per-user frontmatter key dictionary (2026-10-20 ruling): every key a
  note's frontmatter uses gets a small integer `key_id`, which is what the
  Qdrant payload (`fa[].k`) and `note_attrs.key_id` store instead of a
  32-byte key HMAC. The key is matched only by that HMAC
  (`FilterId.key_hmac/2`: case-insensitive, under the per-user filter key);
  its display name (first-seen casing) is stored encrypted under the per-user
  DEK, AAD `aad_for_row(:frontmatter_keys, "name:<key_id>", user_id)`, for a
  per-vault field catalog.

  The named fields have reserved ids (`named/0`, constants in code, never in
  the table); user-added keys are allocated from 64 up, densely per user,
  so a new named field can take a reserved id later without a remap.

  `key_id` does not derive from the DEK, so a DEK rotation keeps every id and
  only rewrites `key_hmac` and the name envelope (`rotate/4`). At most `cap/0` user keys per user
  (default 1,000): a key past the cap is not allocated, `resolve/2` reports
  it as skipped, and the indexing pass leaves it out (never an error).
  """

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Notes.FrontmatterKey
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.Vector.FilterId

  @named %{
    type: 0,
    tags: 1,
    status: 2,
    author: 3,
    reviewed_by: 4,
    source: 5,
    project: 6,
    created: 7,
    updated: 8,
    reviewed: 9,
    expires: 10,
    due: 11,
    priority: 12
  }

  @first_user_id 64

  @doc "Reserved `key_id`s of the named fields."
  def named, do: @named

  @doc "The reserved id of a named field. Raises on an unknown name."
  @spec named_id(atom()) :: non_neg_integer()
  def named_id(field), do: Map.fetch!(@named, field)

  @doc "The first id a user-added key can get."
  def first_user_id, do: @first_user_id

  @doc "Most user-added keys one user can have."
  @spec cap() :: pos_integer()
  def cap, do: ServiceConfig.get(:frontmatter_key_cap, 1000)

  @doc """
  The ids of `names` (`%{key_hmac => name as written}`) for `user_id`,
  allocating the missing ones with the name encrypted under `dek`:
  `{%{key_hmac => key_id}, skipped}`, where `skipped` counts the new keys
  left out because the user is at `cap/0`.

  Race-safe: an allocation takes a per-user transaction advisory lock, reads
  again, then inserts with `ON CONFLICT DO NOTHING` and reads the ids back,
  so two passes allocating the same keys get the same ids and no id is used
  twice. A pass whose keys all exist takes no lock (one SELECT).
  """
  @spec resolve(Ecto.UUID.t(), <<_::256>>, %{binary() => String.t()}) ::
          {%{binary() => integer()}, non_neg_integer()}
  def resolve(_user_id, _dek, names) when names == %{}, do: {%{}, 0}

  def resolve(user_id, dek, names) do
    wanted = Map.keys(names)

    {:ok, result} =
      Repo.with_tenant(user_id, fn ->
        known = select_ids(user_id, wanted)

        if Enum.all?(wanted, &Map.has_key?(known, &1)),
          do: {known, 0},
          else: allocate(user_id, dek, names)
      end)

    result
  end

  defp allocate(user_id, dek, names) do
    :ok = Repo.advisory_lock!("frontmatter_keys:" <> user_id)

    wanted = Map.keys(names)
    known = select_ids(user_id, wanted)
    missing = wanted |> Enum.reject(&Map.has_key?(known, &1)) |> Enum.sort()

    {count, max_id} =
      Repo.one(
        from(k in FrontmatterKey,
          where: k.user_id == ^user_id,
          select: {count(k.key_id), max(k.key_id)}
        )
      )

    {kept, dropped} = Enum.split(missing, max(cap() - count, 0))
    next = if max_id, do: max_id + 1, else: @first_user_id

    rows =
      kept
      |> Enum.with_index(next)
      |> Enum.map(fn {hmac, id} ->
        {ct, nonce} = Envelope.encrypt(names[hmac], dek, name_aad(user_id, id))
        %{user_id: user_id, key_id: id, key_hmac: hmac, name_ct: ct, name_nonce: nonce}
      end)

    _ = Repo.insert_all(FrontmatterKey, rows, on_conflict: :nothing)

    if dropped != [],
      do: :telemetry.execute([:engram, :frontmatter_keys, :skipped], %{count: length(dropped)})

    {select_ids(user_id, wanted), length(dropped)}
  end

  @doc "The display name of a dictionary row, decrypted under `dek`."
  @spec name(FrontmatterKey.t(), <<_::256>>) :: {:ok, String.t()} | :error
  def name(%FrontmatterKey{} = key, dek),
    do: Envelope.decrypt(key.name_ct, key.name_nonce, dek, name_aad(key.user_id, key.key_id))

  defp name_aad(user_id, key_id),
    do: Crypto.aad_for_row(:frontmatter_keys, "name:#{key_id}", user_id)

  @doc """
  The ids of the `key_hmacs` `user_id` already has (one query, no
  allocation): what a search resolves filter key names with. A key absent
  from the result is unknown to this user.
  """
  @spec lookup(Ecto.UUID.t(), [binary()]) :: %{binary() => integer()}
  def lookup(_user_id, []), do: %{}

  def lookup(user_id, key_hmacs) do
    {:ok, ids} = Repo.with_tenant(user_id, fn -> select_ids(user_id, Enum.uniq(key_hmacs)) end)
    ids
  end

  @doc """
  DEK rotation: every row's name is decrypted under `old_dek`, re-encrypted
  under `new_dek` and its `key_hmac` recomputed under `new_filter_key`. The
  ids stay, so every payload and `note_attrs` row keeps pointing at the same
  key. Covers keys no live note uses any more too. Idempotent: a row already
  under the new DEK fails the old-DEK decrypt and is left as is.
  """
  @spec rotate(Ecto.UUID.t(), <<_::256>>, <<_::256>>, binary()) :: :ok
  def rotate(user_id, old_dek, new_dek, new_filter_key) do
    {:ok, _} =
      Repo.with_tenant(user_id, fn ->
        for key <- Repo.all(from(k in FrontmatterKey, where: k.user_id == ^user_id)),
            {:ok, name} <- [name(key, old_dek)] do
          {ct, nonce} = Envelope.encrypt(name, new_dek, name_aad(user_id, key.key_id))

          Repo.update_all(
            from(k in FrontmatterKey,
              where: k.user_id == ^user_id and k.key_id == ^key.key_id
            ),
            set: [
              key_hmac: FilterId.key_hmac(new_filter_key, name),
              name_ct: ct,
              name_nonce: nonce
            ]
          )
        end
      end)

    :ok
  end

  defp select_ids(user_id, hmacs) do
    from(k in FrontmatterKey,
      where: k.user_id == ^user_id and k.key_hmac in ^hmacs,
      select: {k.key_hmac, k.key_id}
    )
    |> Repo.all()
    |> Map.new()
  end
end
