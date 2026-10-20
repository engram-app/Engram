defmodule Engram.Storage.MimeWhitelistTest do
  # async: false — toggles :attachment_mime_bypass in app env.
  use ExUnit.Case, async: false

  alias Engram.Storage.MimeWhitelist

  setup do
    prev_bypass = Application.get_env(:engram, :attachment_mime_bypass)

    on_exit(fn ->
      restore(:attachment_mime_bypass, prev_bypass)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:engram, key)
  defp restore(key, value), do: Application.put_env(:engram, key, value)

  describe "check/2 — any non-executable file is accepted" do
    test "common archive, document, font and binary types pass" do
      for {mime, file} <- [
            {"application/zip", "a.zip"},
            {"application/epub+zip", "a.epub"},
            {"application/xml", "a.xml"},
            {"font/ttf", "a.ttf"},
            {"application/octet-stream", "a.bin"},
            {"application/pdf", "doc.pdf"},
            {"text/plain", "a.txt"},
            {"image/png", "photo.png"},
            {nil, "a.unknownext"},
            {"application/x-msdownload", "tool.bin"}
          ] do
        assert :ok = MimeWhitelist.check(mime, file), "#{mime} #{file} was refused"
      end
    end

    test "scripting-language source files are not blocked" do
      assert :ok = MimeWhitelist.check("text/javascript", "a.js")
      assert :ok = MimeWhitelist.check("text/x-python", "a.py")
    end
  end

  describe "check/2 — executable extensions" do
    test "rejects the last extension, case-insensitively, whatever the MIME" do
      assert {:error, {:extension_not_allowed, ".exe"}} =
               MimeWhitelist.check("text/plain", "run.EXE")

      assert {:error, {:extension_not_allowed, ".sh"}} =
               MimeWhitelist.check("image/png", "x.png.sh")
    end

    test "rejects every blocked extension" do
      for ext <- MimeWhitelist.blocked_extensions() do
        assert {:error, {:extension_not_allowed, ^ext}} =
                 MimeWhitelist.check("image/png", "f#{ext}"),
               "expected #{ext} to be rejected"
      end
    end

    test "rejects installer and package formats" do
      for ext <- ~w(.msix .msixbundle .appx .appxbundle .appimage .run .xpi .crx) do
        assert {:error, {:extension_not_allowed, ^ext}} =
                 MimeWhitelist.check("application/octet-stream", "setup#{ext}")
      end
    end

    test "blocked_extensions/0 is sorted, lowercase, dotted" do
      list = MimeWhitelist.blocked_extensions()
      assert ".exe" in list
      refute ".js" in list
      refute ".py" in list
      assert list == Enum.sort(list)
      assert Enum.all?(list, &(&1 == String.downcase(&1) and String.starts_with?(&1, ".")))
    end
  end

  describe "check/2 — self-host bypass" do
    test "ATTACHMENT_MIME_BYPASS=true skips the blocklist" do
      Application.put_env(:engram, :attachment_mime_bypass, true)

      assert :ok = MimeWhitelist.check("application/x-msdownload", "tool.exe")
    end

    test "the bypass still refuses a header-illegal mime" do
      Application.put_env(:engram, :attachment_mime_bypass, true)

      # The bypass is about the blocklist; a mime with CR/LF is stored
      # verbatim and would inject into (or 500) every response header.
      assert {:error, :invalid_mime} = MimeWhitelist.check("image/png\r\nx-evil: 1", "a.png")
    end

    test "bypass disabled by default" do
      Application.delete_env(:engram, :attachment_mime_bypass)

      assert {:error, _} = MimeWhitelist.check("application/x-msdownload", "tool.exe")
    end
  end

  describe "check/2 — header-illegal mime" do
    test "rejected at the gate, not at serve time" do
      # `String.trim/1` strips \n and \r, so normalizing before validating would
      # let these through; the value is stored verbatim and later hits
      # `put_resp_content_type/2`, which raises (permanent 500 on every read).
      for mime <- [
            "application/pdf\n",
            "application/pdf\r",
            "text/plain\0",
            "image/png\r\n",
            "text/plain\r\nx: y"
          ] do
        assert {:error, :invalid_mime} = MimeWhitelist.check(mime, "a.txt"),
               "#{inspect(mime)} was ACCEPTED and will 500 on serve"
      end
    end
  end

  # Detection comes from the `mime` library (plus the audio types Obsidian
  # recorders produce, registered in config). A file it cannot name is
  # application/octet-stream, which is accepted unless the extension is blocked.
  describe "detect_mime/1" do
    test "names the formats Obsidian vaults commonly hold" do
      for {file, mime} <- [
            {"a.png", "image/png"},
            {"a.HEIC", "image/heic"},
            {"a.avif", "image/avif"},
            {"a.webm", "video/webm"},
            {"a.mov", "video/quicktime"},
            {"a.m4a", "audio/mp4"},
            {"a.ogg", "audio/ogg"},
            {"a.flac", "audio/flac"},
            {"a.wav", "audio/wav"},
            {"a.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"},
            {"a.csv", "text/csv"},
            {"a.md", "text/markdown"}
          ] do
        assert MimeWhitelist.detect_mime(file) == mime, file
        assert MimeWhitelist.check(mime, file) == :ok, file
      end
    end

    test "unknown extensions and nil are octet-stream, which is now accepted" do
      assert MimeWhitelist.detect_mime("a.unknownext") == "application/octet-stream"
      assert MimeWhitelist.detect_mime(nil) == "application/octet-stream"
      assert :ok = MimeWhitelist.check("application/octet-stream", "a.bin")
    end
  end
end
