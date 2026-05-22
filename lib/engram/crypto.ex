defmodule Engram.Crypto do
  @moduledoc """
  Public API for encryption. Wraps the KeyProvider behaviour and DekCache.

  Lazy DEK provisioning: users get a DEK only when encryption is first needed.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Crypto.{DekCache, Envelope, KeyProvider}
  alias Engram.Crypto.KeyProvider.Resolver
  alias Engram.Repo

  require Logger

  # T3.6 / H1 — per-row encryption format version.
  #   1 = legacy: ciphertext was written with empty AAD (`<<>>`).
  #   2 = AAD-bound: ciphertext is bound to "<table>:<column>:<row_id>"
  #       (or "qdrant:<collection>:<qdrant_id>:<field>" for Qdrant payloads).
  # Writers stamp `:aad_bound` (= 2) on every new row. Reads dispatch on the
  # row's stored value: legacy rows decrypt with empty AAD, AAD-bound rows
  # reconstruct the bind string from the row's identity.
  #
  # Distinct from `users.dek_version` (master-key generation, T3.5) and from
  # the wrap-format byte on `users.encrypted_dek` (0x01 = no AAD,
  # 0x02 = AAD-bound, T3.6). The three version concepts are intentionally
  # orthogonal — a user can hold an AAD-bound wrapped DEK (0x02) while still
  # carrying legacy `dek_version=1` rows pending the rebind backfill, or vice
  # versa during the migration window.
  @row_version_legacy 1
  @row_version_aad_bound 2

  @doc "Per-row encryption format version stamped on AAD-bound writes."
  def row_version_aad_bound, do: @row_version_aad_bound

  @doc "Per-row legacy version (no AAD)."
  def row_version_legacy, do: @row_version_legacy

  @doc """
  Pre-allocates a primary-key id from a table's bigserial sequence. Used
  before AAD-bound INSERT so the row's AAD can include its eventual `row_id`.
  Caller passes the allocated `id` into the changeset; Ecto inserts with
  the explicit id and the sequence already advanced.
  """
  @spec next_row_id(atom() | String.t()) :: pos_integer()
  def next_row_id(table) when is_atom(table), do: next_row_id(Atom.to_string(table))

  def next_row_id(table) when is_binary(table) do
    # Postgrex's typed parameter encoder cannot encode `regclass` from a
    # text bind, so we interpolate the sequence name as a literal. The
    # `table` argument is a fixed atom-list (callers in this codebase
    # pass `:notes`, `:attachments`, `:vaults`) — there is no user input
    # path that reaches this string. The strict whitelist guards the
    # boundary in case a future caller passes something dynamic.
    unless table in ["notes", "attachments", "vaults"] do
      raise ArgumentError,
            "next_row_id: unsupported table #{inspect(table)}. " <>
              "Add to the allowlist in Engram.Crypto."
    end

    seq = table <> "_id_seq"

    %Postgrex.Result{rows: [[id]]} =
      Repo.query!("SELECT nextval('#{seq}')", [])

    id
  end

  @doc "AAD string for a relational row's column. T3.6 / H1."
  @spec aad_for_row(atom() | binary(), atom() | binary(), term()) :: binary()
  def aad_for_row(table, column, row_id) when is_binary(table) and is_binary(column),
    do: table <> ":" <> column <> ":" <> to_string(row_id)

  def aad_for_row(table, column, row_id) when is_atom(table),
    do: aad_for_row(Atom.to_string(table), column, row_id)

  def aad_for_row(table, column, row_id) when is_atom(column),
    do: aad_for_row(table, Atom.to_string(column), row_id)

  @doc "AAD string for a Qdrant payload field. Bound to point UUID, not chunk_index."
  @spec aad_for_qdrant(binary(), binary(), atom() | binary()) :: binary()
  def aad_for_qdrant(collection, qdrant_id, field) when is_atom(field),
    do: aad_for_qdrant(collection, qdrant_id, Atom.to_string(field))

  def aad_for_qdrant(collection, qdrant_id, field)
      when is_binary(collection) and is_binary(qdrant_id) and is_binary(field),
      do: "qdrant:" <> collection <> ":" <> qdrant_id <> ":" <> field

  @doc "AAD string for a wrapped DEK. Binds the wrap to the user it belongs to."
  @spec aad_for_wrapped_dek(term()) :: binary()
  def aad_for_wrapped_dek(user_id), do: "dek:v1:" <> to_string(user_id)

  # Returns the AAD to pass at decrypt time for a given row column. Legacy
  # rows return `<<>>`; AAD-bound rows return the constructed bind string.
  defp decrypt_aad(%_{dek_version: v} = row, table, column) when v >= @row_version_aad_bound,
    do: aad_for_row(table, column, row.id)

  defp decrypt_aad(_row, _table, _column), do: <<>>

  @doc """
  Ensures the user has a wrapped DEK stored. Idempotent — returns the user
  untouched if `encrypted_dek` is already present.
  """
  @spec ensure_user_dek(User.t()) :: {:ok, User.t()} | {:error, term()}
  def ensure_user_dek(%User{encrypted_dek: blob} = user) when is_binary(blob) do
    mark_sensitive()
    {:ok, user}
  end

  def ensure_user_dek(%User{} = user) do
    mark_sensitive()
    # T3.1 / C1 — first-write provisioning runs inside a single transaction
    # with `SELECT ... FOR UPDATE` on the user row. This serializes
    # concurrent first-writes for the same user: the second writer's
    # SELECT blocks until the first commits, then sees the populated
    # `encrypted_dek` and short-circuits to the existing wrapped blob.
    # Without this lock, two parallel callers both observe `encrypted_dek:
    # nil`, both generate a fresh DEK, and last-write-wins permanently
    # corrupts any ciphertext written under the loser's DEK.
    #
    # The `DekCache.put/2` side-effect is deferred until AFTER the
    # transaction commits — a rolled-back transaction must NOT leave a
    # cached plaintext DEK that no longer matches anything in DB.
    txn_result =
      Repo.transaction(fn ->
        locked =
          from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE")
          |> Repo.one!(skip_tenant_check: true)

        case locked do
          %User{encrypted_dek: blob} = u when is_binary(blob) ->
            {:existing, u}

          _ ->
            provider = Resolver.provider_for(user.id)
            dek = provider.generate_dek()

            case provider.wrap_dek(dek, %{user_id: user.id}) do
              {:ok, wrapped} ->
                case Accounts.update_user_encryption(locked, %{
                       encrypted_dek: wrapped,
                       dek_version: 1,
                       key_provider: Atom.to_string(provider.name())
                     }) do
                  {:ok, updated} -> {:provisioned, updated, dek}
                  {:error, changeset} -> Repo.rollback(changeset)
                end

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
      end)

    case txn_result do
      {:ok, {:existing, u}} ->
        {:ok, u}

      {:ok, {:provisioned, u, dek}} ->
        :ok = DekCache.put(u.id, dek)
        {:ok, u}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the plaintext DEK for a user, unwrapping via the provider if not cached.
  """
  @spec get_dek(User.t()) :: {:ok, <<_::256>>} | {:error, term()}
  def get_dek(%User{encrypted_dek: nil}), do: {:error, :no_dek}

  def get_dek(%User{id: user_id, encrypted_dek: blob, dek_version: dek_version}) do
    mark_sensitive()

    case DekCache.get(user_id) do
      {:ok, dek} ->
        {:ok, dek}

      :miss ->
        # Phase 3 — dispatch unwrap by blob tag, not by Resolver.provider/0.
        # Lets mixed-state fleets read seamlessly during Local↔KMS backfill
        # windows. Writes still follow Resolver (see ensure_user_dek/1).
        case KeyProvider.identify_from_blob(blob) do
          {:ok, source_provider} ->
            # T3.5 / M4 — pass user.dek_version + master_key_version so the
            # provider can gate the `_PREVIOUS` fallback (audit M4).
            ctx = %{
              user_id: user_id,
              dek_version: dek_version,
              master_key_version: Engram.Crypto.Config.master_key_version()
            }

            case source_provider.unwrap_dek(blob, ctx) do
              {:ok, dek} ->
                DekCache.put(user_id, dek)
                maybe_enqueue_lazy_migration(user_id, source_provider)
                {:ok, dek}

              {:error, _} = err ->
                err
            end

          {:error, :unrecognised_blob} ->
            {:error, :unrecognised_blob}
        end
    end
  end

  # Phase 3 — fire-and-forget lazy migration. Never blocks the read path,
  # never raises. Oban uniqueness `[:user_id, :target_provider]` collapses
  # duplicate enqueues against the active backfill drain.
  defp maybe_enqueue_lazy_migration(user_id, source_provider) do
    configured = Resolver.provider()

    if source_provider != configured do
      target_atom =
        case configured do
          Engram.Crypto.KeyProvider.Local -> :local
          Engram.Crypto.KeyProvider.AwsKms -> :aws_kms
          _ -> nil
        end

      if target_atom do
        try do
          _ =
            %{"user_id" => user_id, "target_provider" => Atom.to_string(target_atom)}
            |> Engram.Workers.MigrateUserProvider.new()
            |> Oban.insert()

          :ok
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end
    end

    :ok
  end

  # T3.3 / M9 — mark every caller process that touches a plaintext DEK as
  # `:sensitive`, so its heap is excluded from any future BEAM crash dump.
  # Set-once-per-process: process_flag/2 is sticky for the process lifetime.
  # Cost is negligible — Phoenix request handlers and Oban workers process
  # encryption-bearing requests on essentially every job.
  @compile {:inline, mark_sensitive: 0}
  defp mark_sensitive do
    :erlang.process_flag(:sensitive, true)
    :ok
  end

  @doc """
  Encrypts `content` + `title` from `attrs` and replaces them with
  `_ciphertext` + `_nonce` keys. Phase B.4: encryption is mandatory — there
  is no `vault.encrypted` flag and no passthrough path.

  Phase B.3: `tags` are encrypted into `tags_ciphertext` by every write via
  `Engram.Notes.phase_b_keyword_for/4`. This helper does not touch tags —
  that's a Phase B contract.
  """
  @spec encrypt_note_fields(map(), User.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def encrypt_note_fields(attrs, %User{} = user, note_id) when is_integer(note_id) do
    with {:ok, user} <- ensure_user_dek(user),
         {:ok, dek} <- get_dek(user) do
      content = Map.get(attrs, :content) || Map.get(attrs, "content") || ""
      title = Map.get(attrs, :title) || Map.get(attrs, "title") || ""

      content_aad = aad_for_row(:notes, :content, note_id)
      title_aad = aad_for_row(:notes, :title, note_id)
      {content_ct, content_nonce} = Envelope.encrypt(content, dek, content_aad)
      {title_ct, title_nonce} = Envelope.encrypt(title, dek, title_aad)

      {:ok,
       attrs
       |> Map.drop([:content, :title, "content", "title"])
       |> Map.put(:id, note_id)
       |> Map.put(:dek_version, @row_version_aad_bound)
       |> Map.put(:content_ciphertext, content_ct)
       |> Map.put(:content_nonce, content_nonce)
       |> Map.put(:title_ciphertext, title_ct)
       |> Map.put(:title_nonce, title_nonce)}
    end
  end

  @doc """
  If note has ciphertext columns populated, decrypt them into the matching
  plaintext virtual fields. Phase 4 ciphertext (`content` / `title` / `tags`)
  and Phase B ciphertext (`path` / `folder`) are decrypted independently — a
  note can have one set populated and not the other (e.g., legacy unencrypted
  vault that has been B.1-backfilled but not Phase 4-encrypted).

  Returns `{:ok, note}` unchanged when no ciphertext is present.
  """
  @spec maybe_decrypt_note_fields(Engram.Notes.Note.t(), User.t()) ::
          {:ok, Engram.Notes.Note.t()} | {:error, term()}
  def maybe_decrypt_note_fields(%Engram.Notes.Note{} = note, %User{} = user) do
    if needs_note_decrypt?(note) do
      with {:ok, dek} <- get_dek(user),
           {:ok, note} <- decrypt_phase_4_note_fields(note, dek),
           {:ok, note} <- decrypt_phase_b_note_fields(note, dek) do
        decrypt_phase_b_tags(note, dek)
      end
    else
      {:ok, note}
    end
  end

  defp needs_note_decrypt?(%Engram.Notes.Note{} = note) do
    # T3.0.4 — gate on the three independent ciphertext "groups." Sub-helpers
    # short-circuit on each field's own nil, so we only need to check one
    # representative per group: content (with title), path (with folder),
    # and tags (standalone). Any group present → load DEK + run decrypt.
    not is_nil(note.content_ciphertext) or
      not is_nil(note.path_ciphertext) or
      not is_nil(note.tags_ciphertext)
  end

  defp decrypt_phase_4_note_fields(%Engram.Notes.Note{content_ciphertext: nil} = note, _dek),
    do: {:ok, note}

  defp decrypt_phase_4_note_fields(%Engram.Notes.Note{} = note, dek) do
    content_aad = decrypt_aad(note, :notes, :content)
    title_aad = decrypt_aad(note, :notes, :title)

    with {:ok, content} <-
           Envelope.decrypt(note.content_ciphertext, note.content_nonce, dek, content_aad),
         {:ok, title} <-
           Envelope.decrypt(note.title_ciphertext, note.title_nonce, dek, title_aad) do
      {:ok, %{note | content: content, title: title}}
    else
      :error -> {:error, :decrypt_failed}
    end
  end

  defp decrypt_phase_b_note_fields(%Engram.Notes.Note{path_ciphertext: nil} = note, _dek),
    do: {:ok, note}

  defp decrypt_phase_b_note_fields(%Engram.Notes.Note{} = note, dek) do
    path_aad = decrypt_aad(note, :notes, :path)
    folder_aad = decrypt_aad(note, :notes, :folder)

    with {:ok, path} <- Envelope.decrypt(note.path_ciphertext, note.path_nonce, dek, path_aad),
         {:ok, folder} <-
           Envelope.decrypt(note.folder_ciphertext, note.folder_nonce, dek, folder_aad) do
      {:ok, %{note | path: path, folder: folder}}
    else
      :error -> {:error, :decrypt_failed}
    end
  end

  # Phase B.3: tags ciphertext is populated for every note (encrypted or
  # unencrypted vault). Decrypts only when the ciphertext is present.
  defp decrypt_phase_b_tags(%Engram.Notes.Note{tags_ciphertext: nil} = note, _dek),
    do: {:ok, note}

  defp decrypt_phase_b_tags(%Engram.Notes.Note{} = note, dek) do
    tags_aad = decrypt_aad(note, :notes, :tags)

    case Envelope.decrypt(note.tags_ciphertext, note.tags_nonce, dek, tags_aad) do
      {:ok, tags_bin} ->
        {:ok, %{note | tags: :erlang.binary_to_term(tags_bin, [:safe])}}

      :error ->
        {:error, :decrypt_failed}
    end
  end

  @doc """
  Decrypts the Phase B `path_ciphertext` on an attachment into the virtual
  `path` field. No-op when ciphertext is nil (legacy pre-B.1 row).
  """
  @spec maybe_decrypt_attachment_fields(Engram.Attachments.Attachment.t(), User.t()) ::
          {:ok, Engram.Attachments.Attachment.t()} | {:error, term()}
  def maybe_decrypt_attachment_fields(
        %Engram.Attachments.Attachment{path_ciphertext: nil} = att,
        _user
      ),
      do: {:ok, att}

  def maybe_decrypt_attachment_fields(
        %Engram.Attachments.Attachment{} = att,
        %User{} = user
      ) do
    path_aad = decrypt_aad(att, :attachments, :path)

    with {:ok, dek} <- get_dek(user),
         {:ok, path} <- Envelope.decrypt(att.path_ciphertext, att.path_nonce, dek, path_aad) do
      {:ok, %{att | path: path}}
    else
      :error -> {:error, :decrypt_failed}
      {:error, _} = err -> err
    end
  end

  @doc """
  Decrypts `name_ciphertext` on a vault into the virtual `name` field.
  No-op when ciphertext is nil (legacy pre-B.1 row).
  """
  @spec maybe_decrypt_vault_fields(Engram.Vaults.Vault.t(), User.t()) ::
          {:ok, Engram.Vaults.Vault.t()} | {:error, term()}
  def maybe_decrypt_vault_fields(%Engram.Vaults.Vault{name_ciphertext: nil} = vault, _user),
    do: {:ok, vault}

  def maybe_decrypt_vault_fields(%Engram.Vaults.Vault{} = vault, %User{} = user) do
    name_aad = decrypt_aad(vault, :vaults, :name)

    with {:ok, dek} <- get_dek(user),
         {:ok, name} <- Envelope.decrypt(vault.name_ciphertext, vault.name_nonce, dek, name_aad) do
      {:ok, %{vault | name: name}}
    else
      :error -> {:error, :decrypt_failed}
      {:error, _} = err -> err
    end
  end

  @doc """
  Encrypts `text`, `title`, `heading_path` in the Qdrant payload map using
  the user's DEK. Adds `text_nonce`, `title_nonce`, `heading_path_nonce`
  keys; all six crypto fields are base64-encoded binaries. Other keys
  (user_id, vault_id, source_path, folder, tags, chunk_index) are
  untouched.

  Phase B.4: encryption is mandatory. Does NOT call `ensure_user_dek/1` —
  Qdrant indexing only runs after a note has been written through
  `Notes.upsert_note/3`, which provisions the DEK. A missing DEK here
  signals a config bug; fail-loud via Oban retry + telemetry is preferable
  to silent lazy-provisioning.

  T3-audit M4 — the legacy 2-arity form (no AAD) was privatized. All
  production + test callers thread `(collection, qdrant_id)` through this
  4-arity form, ensuring every emitted point is AAD-bound.
  """
  @spec encrypt_qdrant_payload(map(), User.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def encrypt_qdrant_payload(payload, %User{} = user, collection, qdrant_id)
      when is_binary(collection) and is_binary(qdrant_id) do
    with {:ok, dek} <- get_dek(user) do
      text_aad = aad_for_qdrant(collection, qdrant_id, :text)
      title_aad = aad_for_qdrant(collection, qdrant_id, :title)
      hp_aad = aad_for_qdrant(collection, qdrant_id, :heading_path)

      {text_ct, text_nonce} = Envelope.encrypt(Map.get(payload, :text) || "", dek, text_aad)
      {title_ct, title_nonce} = Envelope.encrypt(Map.get(payload, :title) || "", dek, title_aad)
      {hp_ct, hp_nonce} = Envelope.encrypt(Map.get(payload, :heading_path) || "", dek, hp_aad)

      {:ok,
       payload
       |> Map.put(:text, Base.encode64(text_ct))
       |> Map.put(:text_nonce, Base.encode64(text_nonce))
       |> Map.put(:title, Base.encode64(title_ct))
       |> Map.put(:title_nonce, Base.encode64(title_nonce))
       |> Map.put(:heading_path, Base.encode64(hp_ct))
       |> Map.put(:heading_path_nonce, Base.encode64(hp_nonce))
       |> Map.put(:aad_version, @row_version_aad_bound)}
    end
  end

  @doc """
  Decrypts a list of Qdrant search candidates in-place. Phase B.4:
  encryption is mandatory, so every candidate with a known vault is
  expected to carry ciphertext.

  - Per-candidate decrypt failure → `Logger.error` + telemetry
    `[:engram, :search, :decrypt_failed]` + candidate dropped.
  - Missing vault entry in `vaults_by_id` → telemetry
    `[:engram, :search, :payload_shape_mismatch]` + candidate dropped.
  - All candidates dropped → `{:error, :decrypt_failed}`.
  - Empty input → `{:ok, []}`.
  """
  @spec decrypt_qdrant_candidates([map()], User.t(), %{
          String.t() => Engram.Vaults.Vault.t()
        }) ::
          {:ok, [map()]} | {:error, :decrypt_failed}
  def decrypt_qdrant_candidates(candidates, user, vaults_by_id, collection \\ nil)

  def decrypt_qdrant_candidates([], _user, _vaults_by_id, _collection), do: {:ok, []}

  def decrypt_qdrant_candidates(candidates, %User{} = user, vaults_by_id, collection)
      when is_list(candidates) and is_map(vaults_by_id) do
    # Lazy DEK load — only fetch if at least one candidate carries
    # ciphertext. Mocked test traffic that returns plaintext-only
    # candidates against an encrypted-by-default user shouldn't 500.
    case maybe_load_dek(user, candidates) do
      {:ok, dek_or_nil} ->
        decrypted =
          candidates
          |> Enum.flat_map(&decrypt_one(&1, vaults_by_id, dek_or_nil, collection))

        if decrypted == [] and candidates != [] do
          {:error, :decrypt_failed}
        else
          {:ok, decrypted}
        end

      {:error, _} = err ->
        err
    end
  end

  defp maybe_load_dek(user, _candidates) do
    case get_dek(user) do
      {:ok, dek} ->
        {:ok, dek}

      {:error, reason} ->
        Logger.error(
          "qdrant decrypt: failed to load DEK for user_id=#{user.id} reason=#{inspect(reason)}"
        )

        {:error, :decrypt_failed}
    end
  end

  defp candidate_vault_id(candidate) do
    case Map.get(candidate, :vault_id) do
      nil -> nil
      v -> to_string(v)
    end
  end

  # Returns [decrypted_candidate] on success, [] on drop.
  # Phase B.4: every production payload MUST carry vault_id + text_nonce.
  # Anything else is a shape mismatch — dropped + telemetry, no plaintext
  # passthrough that could leak ciphertext-as-plaintext on a malformed point.
  defp decrypt_one(candidate, vaults_by_id, dek, collection) do
    vault_id_key = candidate_vault_id(candidate)

    cond do
      is_nil(vault_id_key) ->
        emit_shape_mismatch(nil, candidate, "missing vault_id")
        []

      not Map.has_key?(candidate, :text_nonce) ->
        emit_shape_mismatch(vault_id_key, candidate, "missing text_nonce")
        []

      true ->
        lookup_and_decrypt(candidate, vault_id_key, vaults_by_id, dek, collection)
    end
  end

  defp emit_shape_mismatch(vault_id_key, candidate, reason) do
    qdrant_id = Map.get(candidate, :qdrant_id)

    :telemetry.execute(
      [:engram, :search, :payload_shape_mismatch],
      %{count: 1},
      %{vault_id: vault_id_key, qdrant_id: qdrant_id}
    )

    Logger.error(
      "qdrant decrypt shape mismatch: vault_id=#{inspect(vault_id_key)} qdrant_id=#{inspect(qdrant_id)} reason=#{reason}"
    )
  end

  defp lookup_and_decrypt(candidate, vault_id_key, vaults_by_id, dek, collection) do
    case Map.get(vaults_by_id, vault_id_key) do
      nil ->
        emit_shape_mismatch(vault_id_key, candidate, "vault not in lookup map")
        []

      %Engram.Vaults.Vault{} ->
        do_decrypt_candidate(candidate, dek, collection)
    end
  end

  # T3.6 — AAD-bound payloads carry `aad_version >= 2`. Older points written
  # before this PR have neither key — fall back to empty AAD. `collection`
  # may be nil when callers haven't been threaded through yet (legacy reads
  # only); empty AAD applies in that case too.
  defp qdrant_aad(candidate, collection, field) do
    aad_version = Map.get(candidate, :aad_version)
    qdrant_id = Map.get(candidate, :qdrant_id)

    if is_binary(collection) and is_binary(qdrant_id) and aad_version_aad_bound?(aad_version),
      do: aad_for_qdrant(collection, qdrant_id, field),
      else: <<>>
  end

  defp aad_version_aad_bound?(v) when is_integer(v) and v >= @row_version_aad_bound, do: true
  defp aad_version_aad_bound?(_), do: false

  defp do_decrypt_candidate(candidate, dek, collection) do
    text_aad = qdrant_aad(candidate, collection, :text)
    title_aad = qdrant_aad(candidate, collection, :title)
    hp_aad = qdrant_aad(candidate, collection, :heading_path)

    with {:ok, text_ct} <- safe_decode64(Map.get(candidate, :text)),
         {:ok, text_nonce} <- safe_decode64(Map.get(candidate, :text_nonce)),
         {:ok, title_ct} <- safe_decode64(Map.get(candidate, :title)),
         {:ok, title_nonce} <- safe_decode64(Map.get(candidate, :title_nonce)),
         {:ok, hp_ct} <- safe_decode64(Map.get(candidate, :heading_path)),
         {:ok, hp_nonce} <- safe_decode64(Map.get(candidate, :heading_path_nonce)),
         {:ok, text} <- Envelope.decrypt(text_ct, text_nonce, dek, text_aad),
         {:ok, title} <- Envelope.decrypt(title_ct, title_nonce, dek, title_aad),
         {:ok, heading_path} <- Envelope.decrypt(hp_ct, hp_nonce, dek, hp_aad) do
      decrypted =
        candidate
        |> Map.put(:text, text)
        |> Map.put(:title, title)
        |> Map.put(:heading_path, heading_path)
        |> Map.drop([:text_nonce, :title_nonce, :heading_path_nonce])

      [decrypted]
    else
      reason ->
        qdrant_id = Map.get(candidate, :qdrant_id)
        vault_id = Map.get(candidate, :vault_id)

        :telemetry.execute(
          [:engram, :search, :decrypt_failed],
          %{count: 1},
          %{
            qdrant_id: qdrant_id,
            vault_id: to_string(vault_id),
            reason: inspect(reason)
          }
        )

        Logger.error(
          "qdrant decrypt: failed for qdrant_id=#{inspect(qdrant_id)} vault_id=#{inspect(vault_id)} reason=#{inspect(reason)}"
        )

        []
    end
  end

  defp safe_decode64(nil), do: :error
  defp safe_decode64(s) when is_binary(s), do: Base.decode64(s)
  defp safe_decode64(_), do: :error

  @filter_key_info "engram-filter-v1"
  @content_hash_info "engram-content-hash-v1"

  @doc """
  Derives a 32-byte HMAC filter key from the user's DEK.

  Used for deterministic fingerprinting of filterable fields (path, folder,
  tags, vault name). Computed as `HMAC-SHA256(DEK, "engram-filter-v1")`,
  i.e. a single-block HMAC PRF with a versioned domain-separation info
  string. Equivalent to one round of HKDF-Expand (RFC 5869, L=32, T(1)
  with a counter byte omitted) — the construction is sound because the
  DEK is already a uniform 32-byte secret, so a full HKDF-Extract step is
  unnecessary. Computed on demand — never stored.

  BYOK-ready: the DEK is always available in plaintext after the configured
  KeyProvider unwraps it, regardless of whether the wrapping CMK is local,
  AWS KMS, or a customer-supplied CMK. Filter key derivation is identical
  across providers.

  Returns `{:ok, filter_key}` or `{:error, reason}` propagated from `get_dek/1`.
  """
  def dek_filter_key(user) do
    with {:ok, dek} <- get_dek(user) do
      {:ok, :crypto.mac(:hmac, :sha256, dek, @filter_key_info)}
    end
  end

  @doc """
  T3.7 — derives filter_key from raw DEK bytes without going through the
  cache. Used by the rotation orchestrator which already holds the new
  plaintext DEK in process heap and must NOT round-trip through `get_dek/1`
  (which returns the old cached DEK during rotation).
  """
  @spec dek_filter_key_from_bytes(<<_::256>>) :: binary()
  def dek_filter_key_from_bytes(<<_::256>> = dek) do
    :crypto.mac(:hmac, :sha256, dek, @filter_key_info)
  end

  @doc """
  Computes an HMAC-SHA256 fingerprint of `value` using `filter_key`.

  Used to produce indexed equality predicates on encrypted-at-rest fields:
  `WHERE folder_hmac = hmac_field(filter_key, "projects/2026-q3")`.

  Always 32 bytes. Deterministic — same inputs always produce the same
  output, which is what makes equality lookups possible. This is also why
  the filter key MUST NOT be reused for content encryption (same-key reuse
  across deterministic and randomized cryptographic operations weakens both).
  """
  @spec hmac_field(binary(), binary()) :: binary()
  def hmac_field(filter_key, value)
      when is_binary(filter_key) and byte_size(filter_key) == 32 and is_binary(value) do
    :crypto.mac(:hmac, :sha256, filter_key, value)
  end

  @doc """
  Derives a 32-byte HMAC content-hash subkey from the user's DEK.

  Computed as `HMAC-SHA256(DEK, "engram-content-hash-v1")` — same single-
  block PRF construction as `dek_filter_key/1`, with a different domain-
  separation info string so that note-content fingerprints share no key
  material with path/folder/tag fingerprints. Replaces the legacy global
  MD5 `content_hash` (Phase A of Tier 2): per-user keying defeats cross-
  user dedup oracles and dictionary attacks against known content.
  """
  def dek_content_hash_key(user) do
    with {:ok, dek} <- get_dek(user) do
      {:ok, :crypto.mac(:hmac, :sha256, dek, @content_hash_info)}
    end
  end

  @doc """
  Computes the HMAC-SHA256 content-hash hex digest using a content-hash key
  from `dek_content_hash_key/1`. Returns 64-char lowercase hex.

  Stored in `notes.content_hash` and used by the embedding pipeline to detect
  body changes. Per-user — same content under different users yields different
  digests, so an attacker with DB access cannot cross-correlate notes by body.
  """
  @spec hmac_content_hash(binary(), binary()) :: String.t()
  def hmac_content_hash(content_key, content)
      when is_binary(content_key) and byte_size(content_key) == 32 and is_binary(content) do
    :crypto.mac(:hmac, :sha256, content_key, content) |> Base.encode16(case: :lower)
  end

  # Phase B.3: vault decryption is retired. At-rest encryption is mandatory
  # for every vault — there is no public path to roll a vault back to
  # plaintext. Per-note read paths still decrypt on demand (see
  # `maybe_decrypt_note_fields/2`); whole-vault decryption is a concept
  # that no longer exists.
end
