defmodule EngramWeb.AttachmentCompressionTest do
  @moduledoc """
  Bandit compresses ANY response body when the client sends `Accept-Encoding:
  gzip` — `Bandit.Compression.negotiate_content_encoding/2` defaults `compress`
  to true and `new/5` applies no content-type check whatsoever. So a PNG, a PDF
  or a video gets deflated on the way out: CPU spent to produce a payload that
  is usually LARGER than the input.

  A 2026-08-21 prod profile put `:zlib.append_iolist/2` at 8.57s (5.79% of all
  CPU), reached directly from `AttachmentsController.action/2`.

  Bandit skips compression when the response carries `cache-control:
  no-transform` (`response_indicates_no_transform/1`), which is also the
  semantically correct header: RFC 9111 no-transform means intermediaries must
  not re-encode the payload.
  """
  use EngramWeb.ConnCase, async: true

  alias EngramWeb.AttachmentsController, as: C

  describe "precompressed?/1" do
    test "already-compressed binaries are marked no-transform" do
      for mime <- [
            "image/png",
            "image/jpeg",
            "image/gif",
            "image/webp",
            "image/avif",
            "video/mp4",
            "audio/mpeg",
            "application/pdf",
            "application/zip",
            "application/gzip",
            "font/woff2"
          ] do
        assert C.precompressed?(mime), "#{mime} should skip compression"
      end
    end

    test "text-ish payloads still compress — gzip earns its keep there" do
      for mime <- [
            "text/plain",
            "text/markdown",
            "text/csv",
            "image/svg+xml",
            "application/json",
            "application/xml",
            "image/bmp"
          ] do
        refute C.precompressed?(mime), "#{mime} should still be compressed"
      end
    end

    test "an unknown or nil type compresses (the safe default: never lose gzip)" do
      refute C.precompressed?(nil)
      refute C.precompressed?("application/octet-stream")
      refute C.precompressed?("application/x-made-up")
    end

    test "parameters and casing do not defeat the match" do
      assert C.precompressed?("IMAGE/PNG")
      assert C.precompressed?("image/png; charset=binary")
      assert C.precompressed?(" image/jpeg ")
    end
  end

  describe "no_transform directive" do
    test "uses the exact token Bandit looks for" do
      # Bandit: `"no-transform" in Plug.Conn.Utils.list(header)`. If this token
      # ever drifts, compression silently comes back and only the CPU profile
      # would show it.
      assert "no-transform" in Plug.Conn.Utils.list(C.no_transform_directive())
    end

    test "survives being appended to Phoenix's default cache-control" do
      # The directive is appended, never substituted (see append_no_transform/1).
      # Both the pre-existing directives and the new one must parse out.
      appended = "max-age=0, private, must-revalidate, " <> C.no_transform_directive()
      directives = Plug.Conn.Utils.list(appended)

      assert "no-transform" in directives
      assert "private" in directives
    end
  end
end
