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
  If `vault.encrypted`, encrypts `content`, `title`, `tags`; sets plaintext
  fields to nil; adds `_ciphertext` + `_nonce` fields. Otherwise passes through.
  """
  @spec maybe_encrypt_note_fields(map(), User.t(), Engram.Vaults.Vault.t()) ::
          {:ok, map()} | {:error, term()}
  def maybe_encrypt_note_fields(attrs, _user, %Engram.Vaults.Vault{encrypted: false}),
    do: {:ok, attrs}

  def maybe_encrypt_note_fields(attrs, %User{} = user, %Engram.Vaults.Vault{encrypted: true}) do
    Logger.debug("maybe_encrypt_note_fields auto-provision path for user_id=#{user.id}")

    with {:ok, user} <- ensure_user_dek(user),
         {:ok, dek} <- get_dek(user) do
      content = Map.get(attrs, :content) || Map.get(attrs, "content") || ""
      title = Map.get(attrs, :title) || Map.get(attrs, "title") || ""
      tags = Map.get(attrs, :tags) || Map.get(attrs, "tags") || []

      {content_ct, content_nonce} = Envelope.encrypt(content, dek)
      {title_ct, title_nonce} = Envelope.encrypt(title, dek)
      {tags_ct, tags_nonce} = Envelope.encrypt(:erlang.term_to_binary(tags), dek)

      {:ok,
       attrs
       |> Map.put(:content, nil)
       |> Map.put(:title, nil)
       |> Map.put(:tags, nil)
       |> Map.put(:content_ciphertext, content_ct)
       |> Map.put(:content_nonce, content_nonce)
       |> Map.put(:title_ciphertext, title_ct)
       |> Map.put(:title_nonce, title_nonce)
       |> Map.put(:tags_ciphertext, tags_ct)
       |> Map.put(:tags_nonce, tags_nonce)}
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
        {:ok, note}
      end
    else
      {:ok, note}
    end
  end

  defp needs_note_decrypt?(%Engram.Notes.Note{} = note),
    do: not is_nil(note.content_ciphertext) or not is_nil(note.path_ciphertext)

  defp decrypt_phase_4_note_fields(%Engram.Notes.Note{content_ciphertext: nil} = note, _dek),
    do: {:ok, note}

  defp decrypt_phase_4_note_fields(%Engram.Notes.Note{} = note, dek) do
    with {:ok, content} <- Envelope.decrypt(note.content_ciphertext, note.content_nonce, dek),
         {:ok, title} <- Envelope.decrypt(note.title_ciphertext, note.title_nonce, dek),
         {:ok, tags_bin} <- Envelope.decrypt(note.tags_ciphertext, note.tags_nonce, dek) do
      tags = :erlang.binary_to_term(tags_bin, [:safe])
      {:ok, %{note | content: content, title: title, tags: tags}}
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
  If `vault.encrypted`, encrypts `text`, `title`, `heading_path` in the
  payload map using the user's DEK. Adds `text_nonce`, `title_nonce`,
  `heading_path_nonce` keys; all six crypto fields are base64-encoded
  binaries. Other keys (user_id, vault_id, source_path, folder, tags,
  chunk_index) are untouched. Unencrypted vault → passthrough.

  Unlike `maybe_encrypt_note_fields/3`, this function does NOT call
  `ensure_user_dek/1`. Reason: Qdrant indexing only runs after a note has
  been written through `Notes.upsert_note/3`, which provisions the DEK on
  the first encrypted write. A missing DEK here signals a config bug
  (e.g., a vault manually flipped to `encrypted: true` without using the
  Phase 6 `EncryptVault` toggle worker) — fail-loud via Oban retry +
  telemetry is preferable to silently lazy-provisioning.
  """
  @spec maybe_encrypt_qdrant_payload(map(), User.t(), Engram.Vaults.Vault.t()) ::
          {:ok, map()} | {:error, term()}
  def maybe_encrypt_qdrant_payload(payload, _user, %Engram.Vaults.Vault{encrypted: false}),
    do: {:ok, payload}

  def maybe_encrypt_qdrant_payload(payload, %User{} = user, %Engram.Vaults.Vault{encrypted: true}) do
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
  Decrypts a list of Qdrant search candidates in-place based on each
  candidate's vault's `encrypted` flag (looked up in `vaults_by_id`).

  - Per-candidate decrypt failure → `Logger.error` + telemetry
    `[:engram, :search, :decrypt_failed]` + candidate dropped.
  - Missing vault entry in `vaults_by_id` → telemetry
    `[:engram, :search, :payload_shape_mismatch]` + candidate dropped.
  - All candidates dropped → `{:error, :decrypt_failed}`.
  - Empty input → `{:ok, []}`.
  """
  @spec maybe_decrypt_qdrant_candidates([map()], User.t(), %{
          String.t() => Engram.Vaults.Vault.t()
        }) ::
          {:ok, [map()]} | {:error, :decrypt_failed}
  def maybe_decrypt_qdrant_candidates([], _user, _vaults_by_id), do: {:ok, []}

  def maybe_decrypt_qdrant_candidates(candidates, %User{} = user, vaults_by_id)
      when is_list(candidates) and is_map(vaults_by_id) do
    case get_dek_if_any_encrypted(user, candidates, vaults_by_id) do
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

  # Lazy DEK load — only fetch if at least one candidate is in an encrypted vault.
  defp get_dek_if_any_encrypted(user, candidates, vaults_by_id) do
    if Enum.any?(candidates, fn c -> encrypted_vault?(c, vaults_by_id) end) do
      case get_dek(user) do
        {:ok, dek} ->
          {:ok, dek}

        {:error, reason} ->
          Logger.error(
            "qdrant decrypt: failed to load DEK for user_id=#{user.id} reason=#{inspect(reason)}"
          )

          {:error, :decrypt_failed}
      end
    else
      {:ok, nil}
    end
  end

  defp encrypted_vault?(candidate, vaults_by_id) do
    case candidate_vault_id(candidate) do
      nil ->
        false

      id ->
        case Map.get(vaults_by_id, id) do
          %Engram.Vaults.Vault{encrypted: true} -> true
          _ -> false
        end
    end
  end

  defp candidate_vault_id(candidate) do
    case Map.get(candidate, :vault_id) do
      nil -> nil
      v -> to_string(v)
    end
  end

  # Returns [decrypted_candidate] on success, [] on drop.
  defp decrypt_one(candidate, vaults_by_id, dek) do
    vault_id_key = candidate_vault_id(candidate)

    cond do
      # No vault_id and no ciphertext — legacy / plaintext candidate, pass through.
      is_nil(vault_id_key) and not Map.has_key?(candidate, :text_nonce) ->
        [candidate]

      # No vault_id but ciphertext present — shape mismatch, drop.
      is_nil(vault_id_key) ->
        emit_shape_mismatch(nil, candidate, "missing vault_id with text_nonce present")
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

      %Engram.Vaults.Vault{encrypted: false} ->
        if Map.has_key?(candidate, :text_nonce) do
          emit_shape_mismatch(
            vault_id_key,
            candidate,
            "vault marked unencrypted but payload has text_nonce"
          )

          []
        else
          [candidate]
        end

      %Engram.Vaults.Vault{encrypted: true} ->
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

  @spec encrypt_vault(Engram.Vaults.Vault.t(), Engram.Accounts.User.t()) ::
          {:ok, Engram.Vaults.Vault.t()} | {:error, :cooldown | :bad_status | term()}
  def encrypt_vault(%Engram.Vaults.Vault{} = vault, %Engram.Accounts.User{} = user) do
    Engram.Repo.with_tenant(user.id, fn ->
      locked = Engram.Repo.get!(Engram.Vaults.Vault, vault.id, lock: "FOR UPDATE")

      cond do
        locked.encryption_status != "none" ->
          Engram.Repo.rollback(:bad_status)

        cooldown_active?(locked, user) ->
          Engram.Repo.rollback(:cooldown)

        true ->
          now = DateTime.utc_now()

          updated =
            locked
            |> Ecto.Changeset.change(%{
              encrypted: true,
              encryption_status: "encrypting",
              last_toggle_at: now
            })
            |> Engram.Repo.update!()

          {:ok, _} =
            Engram.Workers.EncryptVault.new(%{
              vault_id: vault.id,
              user_id: user.id,
              cursor: 0
            })
            |> Oban.insert()

          updated
      end
    end)
    |> case do
      {:ok, vault} -> {:ok, vault}
      {:error, reason} -> {:error, reason}
    end
  end

  # Cooldown rules:
  # * No prior toggle → no cooldown.
  # * No per-user cooldown configured (NULL or ≤0) → no cooldown. This is the
  #   default and the self-hosted default; the hosted operator opts users in by
  #   setting users.encryption_toggle_cooldown_days.
  defp cooldown_active?(%Engram.Vaults.Vault{last_toggle_at: nil}, _user), do: false

  defp cooldown_active?(_vault, %Engram.Accounts.User{encryption_toggle_cooldown_days: nil}),
    do: false

  defp cooldown_active?(_vault, %Engram.Accounts.User{encryption_toggle_cooldown_days: days})
       when not is_integer(days) or days <= 0,
       do: false

  defp cooldown_active?(%Engram.Vaults.Vault{last_toggle_at: ts}, %Engram.Accounts.User{
         encryption_toggle_cooldown_days: days
       }) do
    DateTime.diff(DateTime.utc_now(), ts, :day) < days
  end

  @filter_key_info "engram-filter-v1"

  @doc """
  Derives a 32-byte HMAC filter key from the user's DEK using HKDF.

  Used for deterministic fingerprinting of filterable fields (path, folder,
  tags, vault name). The key is HKDF-Expand of the DEK with versioned info
  string `"engram-filter-v1"`. Computed on demand — never stored.

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

  @decrypt_delay_hours 24

  @spec request_decrypt_vault(Engram.Vaults.Vault.t(), Engram.Accounts.User.t()) ::
          {:ok, Engram.Vaults.Vault.t()} | {:error, :cooldown | :bad_status | term()}
  def request_decrypt_vault(%Engram.Vaults.Vault{} = vault, %Engram.Accounts.User{} = user) do
    Engram.Repo.with_tenant(user.id, fn ->
      locked = Engram.Repo.get!(Engram.Vaults.Vault, vault.id, lock: "FOR UPDATE")

      cond do
        locked.encryption_status != "encrypted" ->
          Engram.Repo.rollback(:bad_status)

        cooldown_active?(locked, user) ->
          Engram.Repo.rollback(:cooldown)

        true ->
          now = DateTime.utc_now()
          scheduled_at = DateTime.add(now, @decrypt_delay_hours, :hour)

          updated =
            locked
            |> Ecto.Changeset.change(%{
              encryption_status: "decrypt_pending",
              decrypt_requested_at: now,
              last_toggle_at: now
            })
            |> Engram.Repo.update!()

          {:ok, _} =
            Engram.Workers.DecryptVault.new(
              %{vault_id: vault.id, user_id: user.id, cursor: 0},
              scheduled_at: scheduled_at
            )
            |> Oban.insert()

          :telemetry.execute(
            [:engram, :crypto, :decrypt_requested],
            %{},
            %{vault_id: vault.id, user_id: user.id, scheduled_at: scheduled_at}
          )

          updated
      end
    end)
    |> case do
      {:ok, vault} -> {:ok, vault}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cancel_decrypt_vault(Engram.Vaults.Vault.t(), Engram.Accounts.User.t()) ::
          {:ok, Engram.Vaults.Vault.t()} | {:error, :bad_status}
  def cancel_decrypt_vault(%Engram.Vaults.Vault{} = vault, %Engram.Accounts.User{} = user) do
    Engram.Repo.with_tenant(user.id, fn ->
      locked = Engram.Repo.get!(Engram.Vaults.Vault, vault.id, lock: "FOR UPDATE")

      if locked.encryption_status != "decrypt_pending" do
        Engram.Repo.rollback(:bad_status)
      else
        locked
        |> Ecto.Changeset.change(%{
          encryption_status: "encrypted",
          decrypt_requested_at: nil
        })
        |> Engram.Repo.update!()
      end
    end)
    |> case do
      {:ok, vault} -> {:ok, vault}
      {:error, reason} -> {:error, reason}
    end
  end
end
