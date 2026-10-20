defmodule Engram.Storage.MimeWhitelist do
  @moduledoc """
  Attachment gate: any file type is accepted EXCEPT double-click executables.

  The check is on the file's extension (what the OS opens), not the claimed
  `mime_type`, which a client can set to anything. A header-illegal `mime_type`
  is refused outright (`:invalid_mime`) because it is stored verbatim and would
  500 on every read.

  Self-host operators can bypass the gate entirely (`ATTACHMENT_MIME_BYPASS=true`).
  See `docs/context/attachment-mime-whitelist.md`.
  """

  # Double-click executables only; never source languages (.js, .py).
  @blocked_extensions ~w(
    .exe .dll .com .scr .bat .cmd .vbs .vbe .ps1 .psm1 .msi .msp
    .app .dmg .pkg .deb .rpm .apk .ipa
    .jar .class
    .sh .bash .zsh .fish .so .dylib
    .lnk .reg .hta .cpl .gadget
    .iso
    .msix .msixbundle .appx .appxbundle .appimage .run .xpi .crx
  ) |> Enum.sort()

  @doc """
  Validates an upload's claimed MIME and filename. Returns:

    * `:ok` - upload may proceed.
    * `{:error, :invalid_mime}` - MIME contains header-illegal bytes.
    * `{:error, {:extension_not_allowed, ext}}` - extension is blocklisted.
  """
  @spec check(String.t() | nil, String.t() | nil) ::
          :ok | {:error, :invalid_mime} | {:error, {:extension_not_allowed, String.t()}}
  def check(mime, filename) do
    cond do
      bypass?() -> :ok
      invalid_mime?(mime) -> {:error, :invalid_mime}
      ext = blocked_extension(filename) -> {:error, {:extension_not_allowed, ext}}
      true -> :ok
    end
  end

  @doc "Blocked extensions: sorted, lowercase, leading dot."
  @spec blocked_extensions() :: [String.t()]
  def blocked_extensions, do: @blocked_extensions

  defp bypass?, do: Application.get_env(:engram, :attachment_mime_bypass, false) == true

  @doc """
  Canonical form of a `mime_type` value, for DECISIONS only.

  Strips any parameters (`; charset=utf-8`), trims surrounding whitespace and
  downcases, so `"Image/SVG+XML; charset=utf-8 "` and `"image/svg+xml"` are the
  same media type to every check.

  Callers must NOT store or serve this: the parameters are meaningful in a
  response `Content-Type` (dropping `charset` from a `text/*` response changes
  how a browser decodes it). Attachments keep the uploader's exact string and
  normalize only when deciding allow/deny and inline/download.

  Exists because those two decisions used to normalize differently. This
  module downcased only; `AttachmentsController.inline_safe?/1` also stripped
  parameters. The observable split was that `" image/svg+xml"` was rejected at
  upload while `"image/svg+xml "` was accepted and stored — same media type,
  opposite outcomes, and nothing kept the two in sync.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(mime) when is_binary(mime) do
    mime
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  # Checked BEFORE normalizing: `String.trim/1` strips `\n`/`\r`, so normalizing
  # first would let `"application/pdf\n"` through. Mirrors Plug's
  # `validate_header_key_value!` byte set.
  defp invalid_mime?(mime) when is_binary(mime), do: String.contains?(mime, ["\n", "\r", "\0"])
  defp invalid_mime?(_), do: false

  defp blocked_extension(nil), do: nil

  defp blocked_extension(filename) when is_binary(filename) do
    ext = filename |> Path.extname() |> String.downcase()

    if ext in @blocked_extensions, do: ext, else: nil
  end

  @doc """
  Detects MIME type from the filename extension, via the `mime` library
  (Plug's own table) plus the audio types registered in `config :mime`.
  Returns `application/octet-stream` for unknown extensions.
  """
  @spec detect_mime(String.t() | nil) :: String.t()
  def detect_mime(nil), do: "application/octet-stream"

  def detect_mime(path) when is_binary(path) do
    case MIME.from_path(path) do
      # mime 2.x says text/javascript, which the text/ prefix would admit.
      # The table this replaced said application/javascript and refused it;
      # swapping in the library must not change what uploads are allowed.
      "text/javascript" -> "application/javascript"
      mime -> mime
    end
  end
end
