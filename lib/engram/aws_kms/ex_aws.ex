defmodule Engram.AwsKms.ExAws do
  @moduledoc """
  Production implementation of `Engram.AwsKms`. Thin wrapper over
  `ExAws.KMS.{encrypt,decrypt,re_encrypt,describe_key}` that normalises
  AWS error codes to atom classes the rest of the system pattern-matches on.

  `KeyId` is read from `:engram, :aws_kms_key_id`. Region + creds are
  read from the standard `:ex_aws` config keys.

  ## Binary encoding

  AWS KMS JSON API expects base64-encoded blobs. Plaintext and ciphertext
  are base64-encoded before being handed to ExAws.KMS, and the returned
  base64 blobs are decoded back to raw binaries before returning to callers.

  ## Error shape

  ExAws.request/1 returns `{:error, {type_string, message_string}}` for
  decoded 4xx errors (after ExAws's internal retry / aws_unhandled unwrap).
  `classify/1` handles that tuple as well as network-level errors.

  ## Retry policy

  ExAws retries ThrottlingException internally by default (up to 10 attempts).
  We disable ExAws-level client retries (`client_error_max_attempts: 1`) so
  transient throttling surfaces immediately as `{:error, :throttled}`. The
  caller (Oban worker) is responsible for retry scheduling.
  """

  @behaviour Engram.AwsKms

  @event_request [:engram, :crypto, :kms, :request]
  @event_failure [:engram, :crypto, :kms, :failure]

  # Do not retry client errors at the ExAws level — let callers (Oban) handle
  # retry scheduling. Server errors (5xx) retain the ExAws default retry.
  @ex_aws_opts [
    retries: [
      client_error_max_attempts: 1,
      max_attempts: 3,
      base_backoff_in_ms: 10,
      max_backoff_in_ms: 1_000
    ]
  ]

  @impl true
  def encrypt(plaintext, enc_ctx) when is_binary(plaintext) and is_map(enc_ctx) do
    instrument(:encrypt, fn ->
      key_id = key_id!()

      key_id
      |> ExAws.KMS.encrypt(Base.encode64(plaintext), encryption_context: enc_ctx)
      |> ExAws.request(@ex_aws_opts)
      |> case do
        {:ok, %{"CiphertextBlob" => ct_b64}} -> {:ok, Base.decode64!(ct_b64)}
        {:error, reason} -> {:error, classify(reason)}
      end
    end)
  end

  @impl true
  def decrypt(ciphertext, enc_ctx) when is_binary(ciphertext) and is_map(enc_ctx) do
    instrument(:decrypt, fn ->
      Base.encode64(ciphertext)
      |> ExAws.KMS.decrypt(encryption_context: enc_ctx)
      |> ExAws.request(@ex_aws_opts)
      |> case do
        {:ok, %{"Plaintext" => pt_b64}} -> {:ok, Base.decode64!(pt_b64)}
        {:error, reason} -> {:error, classify(reason)}
      end
    end)
  end

  @impl true
  def re_encrypt(ciphertext, source_ctx, dest_ctx)
      when is_binary(ciphertext) and is_map(source_ctx) and is_map(dest_ctx) do
    instrument(:re_encrypt, fn ->
      key_id = key_id!()

      Base.encode64(ciphertext)
      |> ExAws.KMS.re_encrypt(key_id,
        source_encryption_context: source_ctx,
        destination_encryption_context: dest_ctx
      )
      |> ExAws.request(@ex_aws_opts)
      |> case do
        {:ok, %{"CiphertextBlob" => ct_b64}} -> {:ok, Base.decode64!(ct_b64)}
        {:error, reason} -> {:error, classify(reason)}
      end
    end)
  end

  @impl true
  def describe_key do
    instrument(:describe_key, fn ->
      key_id!()
      |> ExAws.KMS.describe_key()
      |> ExAws.request(@ex_aws_opts)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, classify(reason)}
      end
    end)
  end

  defp key_id! do
    Application.fetch_env!(:engram, :aws_kms_key_id)
  end

  # ExAws decodes 4xx JSON bodies and returns {type_string, message_string}.
  # ThrottlingException is retried internally; after retries exhausted it
  # arrives as {:error, {"ThrottlingException", msg}}.
  defp classify({type, msg}) when is_binary(type) and is_binary(msg),
    do: classify_type(type, msg)

  # Raw :http_error shapes (e.g. non-JSON bodies, network-level 4xx/5xx).
  defp classify({:http_error, _status, %{"__type" => type}}), do: classify_type(type, "")

  defp classify({:http_error, _status, %{body: body}}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"__type" => type} = parsed} ->
        classify_type(type, Map.get(parsed, "message", ""))

      _ ->
        :network_error
    end
  end

  defp classify({:http_error, _status, _other}), do: :network_error
  defp classify(:timeout), do: :network_error
  defp classify({:socket_error, _}), do: :network_error
  defp classify(_other), do: {:aws, "Unknown", "unrecognised_error_shape"}

  defp classify_type(type, msg) do
    case String.split(type, "#", parts: 2) |> List.last() do
      "AccessDeniedException" -> :access_denied
      "ThrottlingException" -> :throttled
      "LimitExceededException" -> :throttled
      "TooManyRequestsException" -> :throttled
      "InvalidCiphertextException" -> :context_mismatch
      "NotFoundException" -> :key_not_found
      other -> {:aws, other, msg}
    end
  end

  defp instrument(op, fun) do
    start = System.monotonic_time()

    try do
      result = fun.()

      duration_us =
        System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

      case result do
        :ok ->
          :telemetry.execute(@event_request, %{duration_us: duration_us}, %{op: op, status: :ok})
          :ok

        {:ok, _} = ok ->
          :telemetry.execute(@event_request, %{duration_us: duration_us}, %{op: op, status: :ok})
          ok

        {:error, reason} = err ->
          error_class = classify_for_telemetry(reason)

          :telemetry.execute(
            @event_request,
            %{duration_us: duration_us},
            %{op: op, status: :error, error_class: error_class}
          )

          :telemetry.execute(
            @event_failure,
            %{count: 1, duration_us: duration_us},
            %{op: op, error_class: error_class}
          )

          err
      end
    rescue
      e ->
        duration_us =
          System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

        :telemetry.execute(
          @event_request,
          %{duration_us: duration_us},
          %{op: op, status: :error, error_class: :exception}
        )

        :telemetry.execute(
          @event_failure,
          %{count: 1, duration_us: duration_us},
          %{op: op, error_class: :exception}
        )

        reraise e, __STACKTRACE__
    end
  end

  defp classify_for_telemetry(reason) when is_atom(reason), do: reason
  defp classify_for_telemetry({:aws, _code, _msg}), do: :other
  defp classify_for_telemetry(_other), do: :other
end
