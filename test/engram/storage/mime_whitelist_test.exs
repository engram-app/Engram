defmodule Engram.Storage.MimeWhitelistTest do
  # async: false — toggles :attachment_mime_bypass and
  # :attachment_mime_allowlist_extra in app env.
  use ExUnit.Case, async: false

  alias Engram.Storage.MimeWhitelist

  setup do
    prev_bypass = Application.get_env(:engram, :attachment_mime_bypass)
    prev_extra = Application.get_env(:engram, :attachment_mime_allowlist_extra)

    on_exit(fn ->
      restore(:attachment_mime_bypass, prev_bypass)
      restore(:attachment_mime_allowlist_extra, prev_extra)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:engram, key)
  defp restore(key, value), do: Application.put_env(:engram, key, value)

  describe "check/2 — allow by MIME prefix" do
    test "allows any image/* type" do
      assert :ok = MimeWhitelist.check("image/png", "photo.png")
      assert :ok = MimeWhitelist.check("image/jpeg", "p.jpg")
      assert :ok = MimeWhitelist.check("image/svg+xml", "p.svg")
      assert :ok = MimeWhitelist.check("image/webp", "p.webp")
    end

    test "allows any audio/* type" do
      assert :ok = MimeWhitelist.check("audio/mpeg", "song.mp3")
      assert :ok = MimeWhitelist.check("audio/wav", "x.wav")
    end

    test "allows any video/* type" do
      assert :ok = MimeWhitelist.check("video/mp4", "clip.mp4")
      assert :ok = MimeWhitelist.check("video/webm", "x.webm")
    end

    test "allows any text/* type" do
      assert :ok = MimeWhitelist.check("text/plain", "a.txt")
      assert :ok = MimeWhitelist.check("text/markdown", "a.md")
      assert :ok = MimeWhitelist.check("text/csv", "a.csv")
    end
  end

  describe "check/2 — allow by explicit MIME" do
    test "allows application/pdf" do
      assert :ok = MimeWhitelist.check("application/pdf", "doc.pdf")
    end

    test "allows application/json" do
      assert :ok = MimeWhitelist.check("application/json", "data.json")
    end

    test "allows Office document MIME types" do
      assert :ok =
               MimeWhitelist.check(
                 "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                 "doc.docx"
               )

      assert :ok =
               MimeWhitelist.check(
                 "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                 "sheet.xlsx"
               )

      assert :ok =
               MimeWhitelist.check(
                 "application/vnd.openxmlformats-officedocument.presentationml.presentation",
                 "deck.pptx"
               )

      assert :ok = MimeWhitelist.check("application/msword", "doc.doc")
    end
  end

  describe "check/2 — reject MIME" do
    test "rejects Windows executable mime types" do
      assert {:error, {:mime_not_allowed, "application/x-msdownload"}} =
               MimeWhitelist.check("application/x-msdownload", "tool.bin")

      assert {:error, {:mime_not_allowed, "application/x-dosexec"}} =
               MimeWhitelist.check("application/x-dosexec", "tool.bin")
    end

    test "rejects mach-o / ELF binaries" do
      assert {:error, {:mime_not_allowed, _}} =
               MimeWhitelist.check("application/x-mach-binary", "tool.bin")

      assert {:error, {:mime_not_allowed, _}} =
               MimeWhitelist.check("application/x-elf", "tool.bin")
    end

    test "rejects application/octet-stream by default (unknown/binary catch-all)" do
      assert {:error, {:mime_not_allowed, "application/octet-stream"}} =
               MimeWhitelist.check("application/octet-stream", "thing.bin")
    end

    test "rejects application/zip by default" do
      assert {:error, {:mime_not_allowed, "application/zip"}} =
               MimeWhitelist.check("application/zip", "archive.zip")
    end

    test "rejects shell script MIME types" do
      assert {:error, {:mime_not_allowed, _}} =
               MimeWhitelist.check("application/x-sh", "run.sh")
    end
  end

  describe "check/2 — extension belt-and-braces" do
    test "rejects .exe even when MIME claims image/png" do
      assert {:error, {:extension_not_allowed, ".exe"}} =
               MimeWhitelist.check("image/png", "trojan.exe")
    end

    test "rejects .dll, .scr, .bat, .cmd, .com, .vbs, .ps1, .msi" do
      for ext <- ~w(.dll .scr .bat .cmd .com .vbs .ps1 .msi) do
        assert {:error, {:extension_not_allowed, ^ext}} =
                 MimeWhitelist.check("image/png", "f#{ext}"),
               "expected #{ext} to be rejected"
      end
    end

    test "rejects .app, .dmg, .deb, .rpm, .jar, .sh, .so" do
      for ext <- ~w(.app .dmg .deb .rpm .jar .sh .so) do
        assert {:error, {:extension_not_allowed, ^ext}} =
                 MimeWhitelist.check("image/png", "f#{ext}"),
               "expected #{ext} to be rejected"
      end
    end

    test "extension check is case-insensitive" do
      assert {:error, {:extension_not_allowed, ".exe"}} =
               MimeWhitelist.check("image/png", "trojan.EXE")
    end
  end

  describe "check/2 — self-host bypass" do
    test "ATTACHMENT_MIME_BYPASS=true short-circuits all checks" do
      Application.put_env(:engram, :attachment_mime_bypass, true)

      assert :ok = MimeWhitelist.check("application/x-msdownload", "tool.exe")
      assert :ok = MimeWhitelist.check("application/octet-stream", "anything.xyz")
    end

    test "bypass disabled by default" do
      Application.delete_env(:engram, :attachment_mime_bypass)

      assert {:error, _} = MimeWhitelist.check("application/x-msdownload", "tool.bin")
    end
  end

  describe "check/2 — operator extra allowlist" do
    test "ATTACHMENT_MIME_ALLOWLIST_EXTRA permits additional MIMEs" do
      Application.put_env(:engram, :attachment_mime_allowlist_extra, [
        "application/zip",
        "application/x-tar"
      ])

      assert :ok = MimeWhitelist.check("application/zip", "archive.zip")
      assert :ok = MimeWhitelist.check("application/x-tar", "archive.tar")
    end

    test "extras do not unblock dangerous extensions" do
      Application.put_env(:engram, :attachment_mime_allowlist_extra, ["application/x-msdownload"])

      assert {:error, {:extension_not_allowed, ".exe"}} =
               MimeWhitelist.check("application/x-msdownload", "tool.exe")
    end

    test "an extra entry matches regardless of parameters or case" do
      # `extra_allowlist/0` normalizes with the same function as the input side.
      # It used to downcase only, so an operator entry carrying a parameter
      # could never match anything and the setting silently did nothing.
      Application.put_env(:engram, :attachment_mime_allowlist_extra, ["Application/ZIP"])

      assert :ok = MimeWhitelist.check("application/zip", "a.zip")
      assert :ok = MimeWhitelist.check("application/zip; charset=binary", "a.zip")
    end
  end

  describe "normalization at the gate" do
    test "parameters, whitespace and case do not change the verdict" do
      # The gate and the serve path share `normalize/1` so the same media type
      # cannot get opposite answers. Each of these is the same type as the bare
      # form and must be accepted alike.
      for mime <- [
            "application/pdf",
            "application/pdf ",
            " application/pdf",
            "APPLICATION/PDF",
            "application/pdf; charset=utf-8",
            "text/plain; charset=utf-8"
          ] do
        assert :ok = MimeWhitelist.check(mime, "doc.pdf"), "#{inspect(mime)} was rejected"
      end
    end

    test "stripping parameters cannot promote a blocked type" do
      # The security-relevant direction: normalization must not let anything
      # through the allowlist that the bare type would not already pass.
      for mime <- [
            "application/zip",
            "application/zip; charset=binary",
            "application/octet-stream ",
            "APPLICATION/X-MSDOWNLOAD",
            "application/x-sh; x=1"
          ] do
        assert {:error, {:mime_not_allowed, _}} = MimeWhitelist.check(mime, "f.bin"),
               "#{inspect(mime)} was ACCEPTED"
      end
    end

    test "header-illegal bytes are rejected at the gate, not at serve time" do
      # `String.trim/1` strips \n and \r, so normalizing before validating would
      # let these through the gate. The value is stored verbatim and later hits
      # `put_resp_content_type/2`, which raises — turning a clean 415 at upload
      # into a permanent 500 on every read of that attachment.
      for mime <- ["application/pdf\n", "application/pdf\r", "text/plain\0", "image/png\r\n"] do
        assert {:error, {:mime_not_allowed, _}} = MimeWhitelist.check(mime, "f.pdf"),
               "#{inspect(mime)} was ACCEPTED and will 500 on serve"
      end
    end
  end
end
