defmodule Engram.Storage.MimeWhitelist do
  @moduledoc """
  Pricing v2 §H Phase 1 — attachment MIME / extension gate.

  Two-layer check on every attachment upload:

    1. MIME allowlist (prefix + explicit set). `application/octet-stream`
       and `application/zip` are NOT allowed by default — they are common
       malware delivery vectors and not justified by Obsidian's normal
       attachment use case (images, audio, video, docs, text).
    2. Extension blocklist. Belt-and-braces: a client can lie about
       `mime_type`, but the file's stored extension is what the OS opens.
       Reject known-executable extensions even if MIME claims `image/png`.

  Self-host operators can bypass entirely (`ATTACHMENT_MIME_BYPASS=true`)
  or extend the allowlist (`ATTACHMENT_MIME_ALLOWLIST_EXTRA=mime1,mime2`).
  See `backend/docs/context/paddle-v2-launch-runbook.md` for the deferred
  Phase 2 (PhotoDNA / DMCA) milestone trigger.
  """

  @mime_prefixes ~w(image/ audio/ video/ text/)

  @mime_explicit MapSet.new(~w(
    application/pdf
    application/json
    application/msword
    application/vnd.ms-excel
    application/vnd.ms-powerpoint
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.openxmlformats-officedocument.presentationml.presentation
    application/vnd.oasis.opendocument.text
    application/vnd.oasis.opendocument.spreadsheet
    application/vnd.oasis.opendocument.presentation
    application/rtf
  ))

  @blocked_extensions MapSet.new(~w(
    .exe .dll .com .scr .bat .cmd .vbs .vbe .ps1 .psm1 .msi .msp
    .app .dmg .pkg .deb .rpm .apk .ipa
    .jar .class
    .sh .bash .zsh .fish .so .dylib
    .lnk .reg .hta .cpl .gadget
    .iso
  ))

  @doc """
  Validates an upload's claimed MIME and filename. Returns:

    * `:ok` — upload may proceed.
    * `{:error, {:mime_not_allowed, mime}}` — MIME failed the allowlist.
    * `{:error, {:extension_not_allowed, ext}}` — extension is blocklisted.

  Order: bypass check first, then MIME (cheapest fail-fast), then
  extension. Extension is the second line of defence specifically to
  catch a lying client — running it after the MIME pass is correct.
  """
  @spec check(String.t() | nil, String.t() | nil) ::
          :ok
          | {:error, {:mime_not_allowed, String.t()}}
          | {:error, {:extension_not_allowed, String.t()}}
  def check(mime, filename) do
    cond do
      bypass?() -> :ok
      not mime_allowed?(mime) -> {:error, {:mime_not_allowed, mime || ""}}
      ext = blocked_extension(filename) -> {:error, {:extension_not_allowed, ext}}
      true -> :ok
    end
  end

  defp bypass?, do: Application.get_env(:engram, :attachment_mime_bypass, false) == true

  defp mime_allowed?(nil), do: false

  defp mime_allowed?(mime) when is_binary(mime) do
    mime = String.downcase(mime)

    Enum.any?(@mime_prefixes, &String.starts_with?(mime, &1)) or
      MapSet.member?(@mime_explicit, mime) or
      MapSet.member?(extra_allowlist(), mime)
  end

  defp extra_allowlist do
    case Application.get_env(:engram, :attachment_mime_allowlist_extra) do
      list when is_list(list) -> MapSet.new(Enum.map(list, &String.downcase/1))
      _ -> MapSet.new()
    end
  end

  defp blocked_extension(nil), do: nil

  defp blocked_extension(filename) when is_binary(filename) do
    ext = filename |> Path.extname() |> String.downcase()

    if MapSet.member?(@blocked_extensions, ext), do: ext, else: nil
  end

  @doc """
  Detects MIME type from filename extension. Mirrors the lookup table
  previously private to `Engram.Attachments`. Returns
  `application/octet-stream` for unknown extensions — which then fails
  `check/2` by design (forces client to send an explicit, allowlisted
  `mime_type` for non-standard files).
  """
  @spec detect_mime(String.t() | nil) :: String.t()
  def detect_mime(nil), do: "application/octet-stream"

  def detect_mime(path) when is_binary(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      ".pdf" -> "application/pdf"
      ".mp3" -> "audio/mpeg"
      ".mp4" -> "video/mp4"
      ".wav" -> "audio/wav"
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".json" -> "application/json"
      ".css" -> "text/css"
      ".js" -> "application/javascript"
      ".html" -> "text/html"
      ".zip" -> "application/zip"
      ".tar" -> "application/x-tar"
      ".gz" -> "application/gzip"
      _ -> "application/octet-stream"
    end
  end
end
