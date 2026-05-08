defmodule Engram.Crypto do
  @moduledoc """
  Public API for encryption. Wraps the KeyProvider behaviour and DekCache.

  Lazy DEK provisioning: users get a DEK only when encryption is first needed.
  """

  require Logger

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Crypto.{DekCache, Envelope, KeyProvider.Resolver}

  @doc """
  Ensures the user has a wrapped DEK stored. Idempotent — returns the user
  untouched if `encrypted_dek` is already present.
  """
  @spec ensure_user_dek(User.t()) :: {:ok, User.t()} | {:error, term()}
  def ensure_user_dek(%User{encrypted_dek: blob} = user) when is_binary(blob), do: {:ok, user}

  def ensure_user_dek(%User{} = user) do
    # The in-memory struct has no DEK, but the DB might already have one from
    # an earlier write that the caller's struct didn't pick up. Reload before
    # generating — without this, every caller holding a stale user struct
    # silently rotates the DEK and corrupts every existing ciphertext.
    case Accounts.get_user(user.id) do
      %User{encrypted_dek: blob} = reloaded when is_binary(blob) ->
        {:ok, reloaded}

      _ ->
        provider = Resolver.provider_for(user.id)
        dek = provider.generate_dek()

        with {:ok, wrapped} <- provider.wrap_dek(dek, %{user_id: user.id}),
             {:ok, user} <-
               Accounts.update_user_encryption(user, %{
                 encrypted_dek: wrapped,
                 dek_version: 1,
                 key_provider: Atom.to_string(provider.name())
               }) do
          DekCache.put(user.id, dek)
          {:ok, user}
        end
    end
  end

  @doc """
  Returns the plaintext DEK for a user, unwrapping via the provider if not cached.
  """
  @spec get_dek(User.t()) :: {:ok, <<_::256>>} | {:error, term()}
  def get_dek(%User{encrypted_dek: nil}), do: {:error, :no_dek}

  def get_dek(%User{id: user_id, encrypted_dek: blob}) do
    case DekCache.get(user_id) do
      {:ok, dek} ->
        {:ok, dek}

      :miss ->
        provider = Resolver.provider_for(user_id)

        case provider.unwrap_dek(blob, %{user_id: user_id}) do
          {:ok, dek} ->
            DekCache.put(user_id, dek)
            {:ok, dek}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Encrypts `content` + `title` from `attrs` and replaces them with
  `_ciphertext` + `_nonce` keys. Phase B.4: encryption is mandatory — there
  is no `vault.encrypted` flag and no passthrough path.

  Phase B.3: `tags` are encrypted into `tags_ciphertext` by every write via
  `Engram.Notes.phase_b_keyword_for/4`. This helper does not touch tags —
  that's a Phase B contract.
  """
  @spec encrypt_note_fields(map(), User.t()) :: {:ok, map()} | {:error, term()}
  def encrypt_note_fields(attrs, %User{} = user) do
    with {:ok, user} <- ensure_user_dek(user),
         {:ok, dek} <- get_dek(user) do
      content = Map.get(attrs, :content) || Map.get(attrs, "content") || ""
      title = Map.get(attrs, :title) || Map.get(attrs, "title") || ""

      {content_ct, content_nonce} = Envelope.encrypt(content, dek)
      {title_ct, title_nonce} = Envelope.encrypt(title, dek)

      {:ok,
       attrs
       |> Map.drop([:content, :title, "content", "title"])
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
           {:ok, note} <- decrypt_phase_b_note_fields(note, dek),
           {:ok, note} <- decrypt_phase_b_tags(note, dek) do
        {:ok, note}
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
    with {:ok, content} <- Envelope.decrypt(note.content_ciphertext, note.content_nonce, dek),
         {:ok, title} <- Envelope.decrypt(note.title_ciphertext, note.title_nonce, dek) do
      {:ok, %{note | content: content, title: title}}
    else
      :error -> {:error, :decrypt_failed}
      {:error, _} = err -> err
    end
  end

  defp decrypt_phase_b_note_fields(%Engram.Notes.Note{path_ciphertext: nil} = note, _dek),
    do: {:ok, note}

  defp decrypt_phase_b_note_fields(%Engram.Notes.Note{} = note, dek) do
    with {:ok, path} <- Envelope.decrypt(note.path_ciphertext, note.path_nonce, dek),
         {:ok, folder} <- Envelope.decrypt(note.folder_ciphertext, note.folder_nonce, dek) do
      {:ok, %{note | path: path, folder: folder}}
    else
      :error -> {:error, :decrypt_failed}
      {:error, _} = err -> err
    end
  end

  # Phase B.3: tags ciphertext is populated for every note (encrypted or
  # unencrypted vault). Decrypts only when the ciphertext is present.
  defp decrypt_phase_b_tags(%Engram.Notes.Note{tags_ciphertext: nil} = note, _dek),
    do: {:ok, note}

  defp decrypt_phase_b_tags(%Engram.Notes.Note{} = note, dek) do
    case Envelope.decrypt(note.tags_ciphertext, note.tags_nonce, dek) do
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
    with {:ok, dek} <- get_dek(user),
         {:ok, path} <- Envelope.decrypt(att.path_ciphertext, att.path_nonce, dek) do
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
    with {:ok, dek} <- get_dek(user),
         {:ok, name} <- Envelope.decrypt(vault.name_ciphertext, vault.name_nonce, dek) do
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
  """
  @spec encrypt_qdrant_payload(map(), User.t()) :: {:ok, map()} | {:error, term()}
  def encrypt_qdrant_payload(payload, %User{} = user) do
    with {:ok, dek} <- get_dek(user) do
      {text_ct, text_nonce} = Envelope.encrypt(Map.get(payload, :text) || "", dek)
      {title_ct, title_nonce} = Envelope.encrypt(Map.get(payload, :title) || "", dek)
      {hp_ct, hp_nonce} = Envelope.encrypt(Map.get(payload, :heading_path) || "", dek)

      {:ok,
       payload
       |> Map.put(:text, Base.encode64(text_ct))
       |> Map.put(:text_nonce, Base.encode64(text_nonce))
       |> Map.put(:title, Base.encode64(title_ct))
       |> Map.put(:title_nonce, Base.encode64(title_nonce))
       |> Map.put(:heading_path, Base.encode64(hp_ct))
       |> Map.put(:heading_path_nonce, Base.encode64(hp_nonce))}
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
  def decrypt_qdrant_candidates([], _user, _vaults_by_id), do: {:ok, []}

  def decrypt_qdrant_candidates(candidates, %User{} = user, vaults_by_id)
      when is_list(candidates) and is_map(vaults_by_id) do
    # Lazy DEK load — only fetch if at least one candidate carries
    # ciphertext. Mocked test traffic that returns plaintext-only
    # candidates against an encrypted-by-default user shouldn't 500.
    case maybe_load_dek(user, candidates) do
      {:ok, dek_or_nil} ->
        decrypted =
          candidates
          |> Enum.flat_map(&decrypt_one(&1, vaults_by_id, dek_or_nil))

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
  defp decrypt_one(candidate, vaults_by_id, dek) do
    vault_id_key = candidate_vault_id(candidate)

    cond do
      is_nil(vault_id_key) ->
        emit_shape_mismatch(nil, candidate, "missing vault_id")
        []

      not Map.has_key?(candidate, :text_nonce) ->
        emit_shape_mismatch(vault_id_key, candidate, "missing text_nonce")
        []

      true ->
        lookup_and_decrypt(candidate, vault_id_key, vaults_by_id, dek)
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

  defp lookup_and_decrypt(candidate, vault_id_key, vaults_by_id, dek) do
    case Map.get(vaults_by_id, vault_id_key) do
      nil ->
        emit_shape_mismatch(vault_id_key, candidate, "vault not in lookup map")
        []

      %Engram.Vaults.Vault{} ->
        do_decrypt_candidate(candidate, dek)
    end
  end

  defp do_decrypt_candidate(candidate, dek) do
    with {:ok, text_ct} <- safe_decode64(Map.get(candidate, :text)),
         {:ok, text_nonce} <- safe_decode64(Map.get(candidate, :text_nonce)),
         {:ok, title_ct} <- safe_decode64(Map.get(candidate, :title)),
         {:ok, title_nonce} <- safe_decode64(Map.get(candidate, :title_nonce)),
         {:ok, hp_ct} <- safe_decode64(Map.get(candidate, :heading_path)),
         {:ok, hp_nonce} <- safe_decode64(Map.get(candidate, :heading_path_nonce)),
         {:ok, text} <- Envelope.decrypt(text_ct, text_nonce, dek),
         {:ok, title} <- Envelope.decrypt(title_ct, title_nonce, dek),
         {:ok, heading_path} <- Envelope.decrypt(hp_ct, hp_nonce, dek) do
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
