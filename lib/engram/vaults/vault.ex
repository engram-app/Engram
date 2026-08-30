defmodule Engram.Vaults.Vault do
  @moduledoc false
  use Engram.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "vaults" do
    # Phase B.3: name is virtual — populated by maybe_decrypt_vault_fields/2.
    # Persisted form is name_ciphertext + name_nonce + name_hmac.
    field :name, :string, virtual: true
    field :description, :string
    field :slug, :string
    field :client_id, :string
    field :is_default, :boolean, default: false
    field :deleted_at, :utc_datetime
    field :name_ciphertext, :binary
    field :name_nonce, :binary
    field :name_hmac, :binary
    # T3.4 / H5 — DEK version this row's ciphertext was wrapped under.
    field :dek_version, :integer, default: 1
    # Sync change-log backbone — per-vault monotonic seq allocator counter.
    # Deliberately NOT in changeset cast: only the migration default (0) and
    # Vaults.next_seq!/1's raw UPDATE may set it, so no client-supplied attr
    # can clobber the counter and break monotonicity.
    field :change_seq, :integer, default: 0

    belongs_to :user, Engram.Accounts.User

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  # No reserved-slug list. Vault routes live under `/v/:slug` (see
  # router.ex), so a slug cannot collide with a top-level app route,
  # a Plug.Static mount, a Phoenix scope, or a Cloudflare rule. The former
  # list -- and its mirror in frontend/src/api/reserved-slugs.ts -- were
  # both deleted along with the root-level `/:slug` route that made them
  # necessary.
  #
  # What replaces it is a SHAPE check, not a name list. Deleting the
  # exclusion left `:slug` with no value-level validation at all, resting
  # the whole "a slug is safe in a URL" claim on `Vaults.slugify/1` being
  # well-behaved -- and at the time it was not: it emitted invalid UTF-8
  # for any non-ASCII name. `slugify/1` is fixed, and this makes its
  # contract enforceable at the boundary rather than merely intended.
  # Exactly the codomain of `Vaults.slugify/1`: alphanumeric groups joined by
  # single hyphens. Deliberately tighter than "starts alphanumeric" -- that
  # looser form admitted "trailing-" and "double--hyphen", which slugify
  # cannot produce, so it would have validated a shape no caller should send.
  @slug_format ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/

  def changeset(vault, attrs) do
    vault
    |> cast(attrs, [
      :description,
      :slug,
      :client_id,
      :is_default,
      :user_id,
      :deleted_at,
      :name_ciphertext,
      :name_nonce,
      :name_hmac,
      :dek_version
    ])
    |> validate_required([:slug, :user_id])
    # Normalize BEFORE validating: callers pass a raw-ish slug and the
    # trim/downcase is part of accepting it, not a post-validation tidy.
    # With these the other way round, "  Work  " failed the format check.
    |> update_change(:slug, &(&1 |> String.trim() |> String.downcase()))
    # Length BEFORE format: `:slug` is an unbounded text column, so running a
    # regex first means a multi-megabyte value is scanned before it is
    # rejected for being too long.
    |> validate_length(:slug, max: 120)
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens, starting with a letter or digit"
    )
    |> validate_encrypted_name()
    |> unique_constraint([:user_id, :slug], name: :vaults_user_id_slug_index)
    |> unique_constraint([:user_id, :client_id], name: :vaults_user_id_client_id_index)
  end

  # Phase B invariant: a vault row must carry the encrypted-name trio. The trio
  # is populated by inject_name_phase_b/3 from the client-supplied `name`, so a
  # missing trio means the caller omitted `name` — error on the public virtual
  # field rather than leaking internal column names into 422 bodies.
  defp validate_encrypted_name(changeset) do
    if Enum.all?(
         [:name_ciphertext, :name_nonce, :name_hmac],
         &(get_field(changeset, &1) not in [nil, ""])
       ) do
      changeset
    else
      add_error(changeset, :name, "can't be blank", validation: :required)
    end
  end
end
