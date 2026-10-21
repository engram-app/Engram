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
  the table); user-added keys are allocated from 64 up.

  Ids are monotonic and NEVER reused: a payload entry left behind under an
  old id must never match a new key. `reap_unused/1` (daily, in
  `OrphanSweep`) deletes keys no `note_attrs` row uses, which frees cap space,
  but always keeps each user's highest id, so the next id stays above every
  id ever handed out.

  At most `cap/0` keys per user (default 1,000; the reaper keeps that count
  to live keys), and never past the smallint max: a new key past either is
  not allocated, `resolve/3` reports it as skipped, and the indexing pass
  leaves it out (never an error). A search on such a key gets a distinct
  "not indexed" error (`at_limit?/1`).

  `key_id` does not derive from the DEK, so a DEK rotation keeps every id and
  only rewrites `key_hmac` and the name envelope (`put_rotated/4`, driven by
  `UserDekRotation`).
  """

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Notes.FrontmatterKey
  alias Engram.Notes.NoteAttr
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.Vaults.Vault
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
  @max_id 32_767
  # A key allocated this recently may belong to an index pass that has not
  # committed its `note_attrs` rows yet, so the reaper leaves it alone.
  @reap_min_age_s 86_400

  @doc "Reserved `key_id`s of the named fields."
  def named, do: @named

  @doc "The reserved id of a named field. Raises on an unknown name."
  @spec named_id(atom()) :: non_neg_integer()
  def named_id(field), do: Map.fetch!(@named, field)

  @doc "The first id a user-added key can get."
  def first_user_id, do: @first_user_id

  @doc "Most user-added keys one user can have (clamped to what a smallint id can hold)."
  @spec cap() :: pos_integer()
  def cap,
    do: ServiceConfig.get(:frontmatter_key_cap, 1000) |> min(@max_id - @first_user_id + 1)

  @doc """
  The ids of `names` (`%{key_hmac => name as written}`) for `user_id`,
  allocating the missing ones with the name encrypted under `dek`:
  `{%{key_hmac => key_id}, skipped}`, where `skipped` counts the new keys
  left out because the user is at `cap/0` or out of ids.

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
    {count, max_id} = stats(user_id)

    # Monotonic: the next id is above every id this user ever had (the
    # reaper keeps the highest row), and never past the smallint max.
    next = if max_id, do: max_id + 1, else: @first_user_id
    room = min(max(cap() - count, 0), max(@max_id - next + 1, 0))
    {kept, dropped} = Enum.split(missing, room)

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

  defp stats(user_id) do
    Repo.one(
      from(k in FrontmatterKey,
        where: k.user_id == ^user_id,
        select: {count(k.key_id), max(k.key_id)}
      )
    )
  end

  @doc """
  The ids of the `key_hmacs` `user_id` already has (one query, no
  allocation): what a search resolves filter key names with. A key absent
  from the result is unknown to this user, or was skipped (`at_limit?/1`).
  """
  @spec lookup(Ecto.UUID.t(), [binary()]) :: %{binary() => integer()}
  def lookup(_user_id, []), do: %{}

  def lookup(user_id, key_hmacs) do
    {:ok, ids} = Repo.with_tenant(user_id, fn -> select_ids(user_id, Enum.uniq(key_hmacs)) end)
    ids
  end

  @doc """
  True when `user_id` cannot get a new key id (at `cap/0`, or out of ids):
  a key it lacks may then have been skipped, not merely unused.
  """
  @spec at_limit?(Ecto.UUID.t()) :: boolean()
  def at_limit?(user_id) do
    {:ok, {count, max_id}} = Repo.with_tenant(user_id, fn -> stats(user_id) end)
    count >= cap() or (max_id || 0) >= @max_id
  end

  @doc "The display name of a dictionary row, decrypted under `dek`."
  @spec name(FrontmatterKey.t(), <<_::256>>) :: {:ok, String.t()} | :error
  def name(%FrontmatterKey{} = key, dek),
    do: Envelope.decrypt(key.name_ct, key.name_nonce, dek, name_aad(key.user_id, key.key_id))

  @doc "The name envelope's AAD: bound to the user and the key id."
  @spec name_aad(Ecto.UUID.t(), integer()) :: binary()
  def name_aad(user_id, key_id),
    do: Crypto.aad_for_row(:frontmatter_keys, "name:#{key_id}", user_id)

  @doc "Every dictionary row of `user_id`, for the rotation sweep (inside its tenant)."
  @spec all(Ecto.UUID.t()) :: [FrontmatterKey.t()]
  def all(user_id),
    do: Repo.all(from(k in FrontmatterKey, where: k.user_id == ^user_id, order_by: k.key_id))

  @doc """
  DEK rotation, one row: `name` (decrypted by the caller) re-encrypted under
  `new_dek` and `key_hmac` recomputed under `new_filter_key`. The id stays,
  so every payload and `note_attrs` row keeps pointing at the same key.
  """
  @spec put_rotated(FrontmatterKey.t(), String.t(), <<_::256>>, binary()) :: :ok
  def put_rotated(%FrontmatterKey{} = key, name, new_dek, new_filter_key) do
    {ct, nonce} = Envelope.encrypt(name, new_dek, name_aad(key.user_id, key.key_id))

    {1, _} =
      Repo.update_all(
        from(k in FrontmatterKey, where: k.user_id == ^key.user_id and k.key_id == ^key.key_id),
        set: [key_hmac: FilterId.key_hmac(new_filter_key, name), name_ct: ct, name_nonce: nonce]
      )

    :ok
  end

  @doc """
  Delete every user's dictionary rows that no `note_attrs` row uses, older
  than a day, except each user's highest id (so ids stay monotonic). Runs on
  `Repo.maintenance()` (it spans tenants), one short transaction per user.
  Returns the number deleted.

  Per user: the user row is read `FOR SHARE` and a user mid DEK rotation is
  skipped (the rotation sweep rewrites these rows; `RotationLock.acquire/1`
  then waits for this transaction). Candidates are locked `FOR UPDATE`,
  which waits for any index pass holding them `FOR KEY SHARE`
  (`Indexing.hold_key_ids!/2`), and the DELETE re-checks with a fresh
  snapshot, so a key that pass just wrote survives. The "is it used" probe
  is scoped by the user's vault ids and the key, one NOT EXISTS per value
  column, so each is served by its partial `(vault_id, key_id, h|n|d)` index
  instead of a scan of `note_attrs`.
  """
  @spec reap_unused(non_neg_integer()) :: non_neg_integer()
  def reap_unused(min_age_s \\ @reap_min_age_s) do
    repo = Repo.maintenance()

    Repo.cross_tenant(fn ->
      from(k in FrontmatterKey, distinct: true, select: k.user_id)
      |> repo.all()
      |> Enum.reduce(0, fn user_id, acc -> acc + reap_user(repo, user_id, min_age_s) end)
    end)
  end

  defp reap_user(repo, user_id, min_age_s) do
    {:ok, n} =
      repo.transaction(fn ->
        case repo.one(
               from(u in User,
                 where: u.id == ^user_id,
                 select: {u.id, u.dek_rotation_locked_at},
                 lock: "FOR SHARE"
               )
             ) do
          {_id, nil} -> reap_candidates(repo, user_id, min_age_s)
          _rotating_or_gone -> 0
        end
      end)

    n
  end

  defp reap_candidates(repo, user_id, min_age_s) do
    vault_ids = repo.all(from(v in Vault, where: v.user_id == ^user_id, select: v.id))

    max_id =
      repo.one(from(k in FrontmatterKey, where: k.user_id == ^user_id, select: max(k.key_id))) ||
        @first_user_id

    unused =
      from(k in FrontmatterKey,
        as: :key,
        where: k.user_id == ^user_id and k.key_id < ^max_id,
        where: not exists(used(vault_ids, :h)),
        where: not exists(used(vault_ids, :n)),
        where: not exists(used(vault_ids, :d))
      )

    candidates =
      unused
      |> where([k], k.inserted_at < ago(^min_age_s, "second"))
      |> select([k], k.key_id)
      |> lock("FOR UPDATE")
      |> repo.all()

    if candidates == [] do
      0
    else
      {n, _} = unused |> where([k], k.key_id in ^candidates) |> repo.delete_all()
      n
    end
  end

  defp used(vault_ids, col) do
    from(a in NoteAttr,
      where: a.vault_id in ^vault_ids and a.key_id == parent_as(:key).key_id,
      where: not is_nil(field(a, ^col)),
      select: 1
    )
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
