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

    # OKF v0.1 fields (spec 2026-07-02). type/description/resource are
    # encrypted (virtuals below); the two dates are the ONLY plaintext
    # frontmatter columns (range queries need real values).
    field :type, :string, virtual: true
    field :description, :string, virtual: true
    field :resource, :string, virtual: true
    field :fm_timestamp, :utc_datetime
    field :fm_created, :utc_datetime

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

    # CRDT (Yjs) document state for posture-C file-level sync. The full v1
    # `Yex.encode_state_as_update` snapshot, AES-256-GCM encrypted under the
    # per-user DEK with AAD `aad_for_row(:notes, :crdt_state, id)`. NULL until
    # a note's first CRDT-aware write seeds it from an empty Y.Doc.
    field :crdt_state_ciphertext, :binary
    field :crdt_state_nonce, :binary

    # Head marker of the canonical CRDT doc: sha256(state_vector) url-b64 (see
    # CrdtTransport.head_marker/1). INVALIDATE-and-self-heal, not maintained: it
    # is NULLed on every CRDT-state change (update_v1 on a tail append; a DB
    # trigger on any crdt_state_ciphertext write), and vault_heads self-heals a
    # NULL by rebuilding the doc once and storing the result — so a non-NULL
    # value is a lazily-cached head, refreshed on the next poll after any edit.
    # BackfillCrdtHead warms existing NULLs. Not encrypted: a hash of clock
    # counts carries no note content.
    field :crdt_head, :string

    field :type_ciphertext, :binary
    field :type_nonce, :binary
    field :type_hmac, :binary
    field :description_ciphertext, :binary
    field :description_nonce, :binary
    field :resource_ciphertext, :binary
    field :resource_nonce, :binary

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
    :tags_hmac,
    :crdt_state_ciphertext,
    :crdt_state_nonce,
    :type_ciphertext,
    :type_nonce,
    :type_hmac,
    :description_ciphertext,
    :description_nonce,
    :resource_ciphertext,
    :resource_nonce
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
        :kind,
        :fm_timestamp,
        :fm_created
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
