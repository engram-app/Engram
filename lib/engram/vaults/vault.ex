defmodule Engram.Vaults.Vault do
  @moduledoc false
  use Engram.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "vaults" do
    # Phase B.3: name is virtual — populated by maybe_decrypt_vault_fields/2.
    # Persisted form is name_ciphertext + name_nonce + name_hmac.
    field :name, :string, virtual: true, redact: true
    field :description, :string, redact: true
    # Never written with a value: the slug is derived from the decrypted name
    # (`Vaults.derive_slug/2`, set by maybe_decrypt_vault_fields/2) and looked
    # up via slug_hmac. Writes set it to NULL. The
    # contract release drops it (prod had no plaintext slugs left at the
    # 2026-10-06 audit).
    field :slug, :string, redact: true
    # Keyed HMAC of the slug (per-user filter key, like name_hmac): lookup and
    # uniqueness for /v/:slug without the plaintext. `slug_suffixed` records
    # that this vault took the id collision suffix at mint, so the slug is
    # derivable from name + id.
    field :slug_hmac, :binary
    field :slug_suffixed, :boolean, default: false
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

  # No reserved-slug list and no slug shape check: vault routes live under
  # `/v/:slug`, and the slug is only ever `Vaults.slugify/1` output computed
  # server-side, whose contract (alphanumeric groups joined by single
  # hyphens) is tested there. No client value reaches it.

  def changeset(vault, attrs) do
    vault
    # `:description` is not cast: it was a plaintext free-text field no client
    # ever surfaced (0 rows in prod), retired rather than encrypted. The
    # column is dropped in the contract release.
    |> cast(attrs, [
      :slug,
      :slug_hmac,
      :slug_suffixed,
      :client_id,
      :is_default,
      :user_id,
      :deleted_at,
      :name_ciphertext,
      :name_nonce,
      :name_hmac,
      :dek_version
    ])
    |> validate_required([:user_id])
    |> validate_slug_hmac_on_insert()
    |> validate_encrypted_name()
    |> unique_constraint([:user_id, :slug_hmac], name: :vaults_user_id_slug_hmac_index)
    |> unique_constraint([:user_id, :client_id], name: :vaults_user_id_client_id_index)
  end

  # Required on insert only: an update must never be blocked by a legacy row
  # the reconciler has not reached (delete/restore/set-default of such a row
  # would otherwise fail).
  defp validate_slug_hmac_on_insert(%{data: %{__meta__: %{state: :built}}} = cs),
    do: validate_required(cs, [:slug_hmac])

  defp validate_slug_hmac_on_insert(cs), do: cs

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
