defmodule Engram.Notes.Note do
  @moduledoc false
  use Engram.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "notes" do
    # Phase B.3 + B.4: path/folder/tags/content/title are virtual — only
    # ciphertext + HMAC columns are persisted. Engram.Crypto.maybe_decrypt_note_fields/2
    # populates these so callers can still read note.path / note.content etc.
    # after a read.
    field :path, :string, virtual: true
    field :folder, :string, virtual: true
    field :tags, {:array, :string}, virtual: true, default: []
    field :title, :string, virtual: true
    field :content, :string, virtual: true

    field :version, :integer, default: 1
    # Sync change-log backbone (PR A): per-row latest change sequence, allocated
    # from `vaults.change_seq` via `Engram.Vaults.next_seq!/1` on every write.
    # Nullable until the backfill migration populates pre-existing rows.
    field :seq, :integer
    field :kind, :string, default: "note"
    # T3.4 / H5 — DEK version this row's ciphertext was wrapped under.
    # Default 1 today; future rotation campaigns stamp the new version on
    # rewritten rows. Read path consumers key off this column once T3.5 /
    # T3.7 introduce a `users.dek_version > 1` cohort.
    field :dek_version, :integer, default: 1
    field :content_hash, :string
    field :embed_hash, :string
    # Poison-loop guard: when a note exhausts its EmbedNote attempts, the worker
    # stamps a cooldown timestamp here. ReconcileEmbeddings skips notes whose
    # cooldown hasn't elapsed, so a permanently-failing note re-bills Voyage at
    # most once per cooldown window instead of every 15-minute cron tick. Cleared
    # on the next successful embed. Only gates the cron — direct user-action
    # enqueues (upsert/rename) always run.
    field :embed_retry_after, :utc_datetime_usec
    field :mtime, :float
    field :deleted_at, :utc_datetime_usec
    field :content_ciphertext, :binary
    field :content_nonce, :binary
    field :title_ciphertext, :binary
    field :title_nonce, :binary
    field :tags_ciphertext, :binary
    field :tags_nonce, :binary
    field :path_ciphertext, :binary
    field :path_nonce, :binary
    field :path_hmac, :binary
    field :folder_ciphertext, :binary
    field :folder_nonce, :binary
    field :folder_hmac, :binary
    field :tags_hmac, {:array, :binary}, default: []

    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault
    has_many :chunks, Engram.Notes.Chunk

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @encryption_fields [
    :content_ciphertext,
    :content_nonce,
    :title_ciphertext,
    :title_nonce,
    :tags_ciphertext,
    :tags_nonce,
    :path_ciphertext,
    :path_nonce,
    :path_hmac,
    :folder_ciphertext,
    :folder_nonce,
    :folder_hmac,
    :tags_hmac
  ]

  def changeset(note, attrs) do
    note
    |> cast(
      attrs,
      [
        # `:id` is cast so callers that build the changeset on a bare
        # `%Note{}` (instead of `%Note{id: minted_id}`) can still supply
        # the app-minted UUIDv7 via `attrs`. The PK is `autogenerate: false`
        # under `Engram.Schema`; without this `:id` is silently dropped and
        # Postgres rejects the INSERT for a missing PK.
        :id,
        :seq,
        :version,
        :dek_version,
        :content_hash,
        :mtime,
        :user_id,
        :vault_id,
        :deleted_at,
        :kind
      ] ++ @encryption_fields,
      empty_values: []
    )
    |> validate_inclusion(:kind, ["note", "folder"])
    |> validate_required_for_kind()
    |> validate_format(:id, ~r/^[0-9a-f-]{36}$/i)
    |> unique_constraint([:user_id, :vault_id, :path_hmac],
      name: :notes_user_vault_path_v2
    )
    |> unique_constraint([:user_id, :vault_id, :folder_hmac],
      name: :notes_user_vault_folder_marker
    )
  end

  defp validate_required_for_kind(changeset) do
    required_note = [
      :user_id,
      :vault_id,
      :path_hmac,
      :path_ciphertext,
      :path_nonce,
      :folder_hmac,
      :folder_ciphertext,
      :folder_nonce,
      :content_ciphertext,
      :content_nonce,
      :title_ciphertext,
      :title_nonce,
      :tags_ciphertext,
      :tags_nonce
    ]

    required_folder = [
      :user_id,
      :vault_id,
      :folder_hmac,
      :folder_ciphertext,
      :folder_nonce
    ]

    required =
      case get_field(changeset, :kind) || "note" do
        "folder" -> required_folder
        _ -> required_note
      end

    validate_required(changeset, required)
  end
end
