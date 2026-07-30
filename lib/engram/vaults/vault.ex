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

  # Slugs that would make a vault unreachable. Three failure modes:
  #   - Route-shadowed (sign-in..settings): some of these have a top-level
  #     static React Router route that beats `/:slug` (e.g. `/link`), making a
  #     same-named vault unreachable by URL. Others (`search`, `billing`) have
  #     NO such static route (`billing` only exists nested under
  #     `/onboard/billing`; `search` is a rail-toggled panel, not a route), so
  #     `/:slug` would actually match them; what actually stops a vault
  #     from ever holding one of these slugs is `validate_exclusion` below,
  #     not routing.
  #   - Backend-denied (api..socket): Task 7's Phoenix deny-list 404s these
  #     prefixes before the SPA ever loads, so a vault slugged `assets` is
  #     completely broken, not just awkward.
  #   - Backend-forwarded (metrics): router.ex mounts `forward "/metrics",
  #     PromEx.Plug` behind bearer auth, ahead of the vault route, so
  #     `/metrics` and everything under it 401s before the SPA loads. No
  #     deny-list entry needed for this one, the forward already wins by
  #     declaration order.
  # Keep in sync with frontend/src/api/reserved-slugs.ts.
  @reserved_slugs ~w(
    sign-in sign-up waitlist link oauth onboard reset-password
    note search billing settings api webhooks .well-known
    assets email socket metrics
  )

  @doc "Exposes the reserved-slug list so slug generation can dedup around it, same as a taken slug."
  def reserved_slugs, do: @reserved_slugs

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
    |> validate_required([
      :slug,
      :user_id,
      :name_ciphertext,
      :name_nonce,
      :name_hmac
    ])
    |> update_change(:slug, &(&1 |> String.trim() |> String.downcase()))
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved")
    |> unique_constraint([:user_id, :slug], name: :vaults_user_id_slug_index)
    |> unique_constraint([:user_id, :client_id], name: :vaults_user_id_client_id_index)
  end
end
