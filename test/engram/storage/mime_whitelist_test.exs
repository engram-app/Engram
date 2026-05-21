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
  end
end
