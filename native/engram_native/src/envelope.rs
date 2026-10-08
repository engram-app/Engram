//! The envelope engine: optional zstd + AES-256-GCM in one call. AES-GCM is
//! `ring` (BoringSSL's assembly, ~1.8x RustCrypto `aes-gcm` here; see the
//! microbench below and docs/context/native-nifs.md). Its key schedule is not
//! zeroized on drop; `aes-gcm`'s was.
//!
//! Format 0: 12-byte nonce field, AAD as given, body = plaintext. Byte for
//! byte what OpenSSL `:crypto` wrote before this engine.
//! Format 1: nonce field `<<1, nonce::12>>`, AAD = caller AAD ++ "|f1" (so
//! the format byte is authenticated), body = `<<codec, payload>>` where
//! codec 0 = raw, 1 = one zstd frame (content size + checksum on).
//!
//! Assumes no caller AAD ends in "|f1", or more exactly that no AAD equals
//! another one ++ "|f1"; otherwise a format-0 AAD `x|f1` would equal format
//! 1's AAD for `x`. Row AADs are `table <> 0 <> column <> 0 <> 16 raw uuid
//! bytes` (`Crypto.aad_prefix/2` ++ the id), fixed length per column, so
//! one minus its last 3 bytes is never another row's AAD even when the uuid
//! happens to end in "|f1". The rest are structured (`dek:...`,
//! `qdrant:...`) or the legacy empty AAD.
use ring::aead::{Aad, LessSafeKey, Nonce, Tag, UnboundKey, AES_256_GCM};
use std::borrow::Cow;
use std::cell::RefCell;
use std::ops::DerefMut;
use zstd::zstd_safe::{self, DCtx, DParameter, InBuffer, OutBuffer, ResetDirective};

pub const TAG: usize = 16;
const NONCE: usize = 12;
const FORMAT_1: u8 = 1;
const CODEC_RAW: u8 = 0;
const CODEC_ZSTD: u8 = 1;
const LEVEL: i32 = 3;
// Decode refuses frames whose window exceeds 8 MB (zstd's default allows
// 128 MB). Level 3 writes a window of at most 2^21, so only a crafted frame
// sealed under a real key could ask for more. The cap bites when zstd
// buffers (declared size past the output's room); a frame that fits the
// output decodes straight into it and needs no separate window.
const WINDOW_LOG_MAX: u32 = 23;
// :auto compresses a sample first; incompressible media skips the full pass.
const SAMPLE: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Mode {
    None,
    Zstd,
    Auto,
}

thread_local! {
    // One context per scheduler thread: creating one costs ~0.3 ms (spike).
    static CCTX: RefCell<Option<zstd::bulk::Compressor<'static>>> = const { RefCell::new(None) };
    static DCTX: RefCell<Option<DCtx<'static>>> = const { RefCell::new(None) };
}

fn compress(data: &[u8]) -> Option<Vec<u8>> {
    CCTX.with(|c| {
        let mut c = c.borrow_mut();
        if c.is_none() {
            let mut z = zstd::bulk::Compressor::new(LEVEL).ok()?;
            z.include_checksum(true).ok()?;
            z.include_contentsize(true).ok()?;
            *c = Some(z);
        }
        c.as_mut()?.compress(data).ok()
    })
}

/// One whole frame, or None if it is corrupt, truncated, has trailing
/// bytes, or needs a window past `WINDOW_LOG_MAX`. The header's content size is checked by zstd at the end of the
/// frame but never trusted for an allocation: the output grows as bytes
/// actually decode (from a start sized off the frame), capped by the
/// declared size, so a lying header cannot force a huge allocation.
fn decompress(frame: &[u8]) -> Option<Vec<u8>> {
    let declared = usize::try_from(zstd_safe::get_frame_content_size(frame).ok()??).ok()?;
    let start = frame.len().saturating_mul(8).max(64 * 1024);
    let mut out = Vec::with_capacity(declared.min(start));
    DCTX.with(|d| {
        let mut d = d.borrow_mut();
        if d.is_none() {
            let mut fresh = DCtx::try_create()?;
            fresh
                .set_parameter(DParameter::WindowLogMax(WINDOW_LOG_MAX))
                .ok()?;
            *d = Some(fresh);
        }
        let d = d.as_mut()?;
        d.reset(ResetDirective::SessionOnly).ok()?;
        let mut input = InBuffer::around(frame);
        loop {
            if out.len() == out.capacity() {
                // Doubling, and while under the declared size never past it
                // (a truthful frame ends at exactly its size). zstd checks the
                // size only at the frame's end, so an overrun keeps doubling
                // until then; that is real decoded data, not a header's claim.
                let room = out.capacity().max(1);
                let more = match declared.checked_sub(out.len()) {
                    Some(gap) if gap > 0 => room.min(gap),
                    _ => room,
                };
                out.reserve_exact(more);
            }
            let pos = out.len();
            let mut buf = OutBuffer::around_pos(&mut out, pos);
            let left = d.decompress_stream(&mut buf, &mut input).ok()?;
            let full = buf.pos() == buf.capacity();
            if left == 0 {
                return (input.pos() == frame.len()).then_some(out);
            }
            // All input read and output room to spare: the frame is cut short.
            if input.pos() == frame.len() && !full {
                return None;
            }
        }
    })
}

fn cipher(key: &[u8]) -> Result<LessSafeKey, ()> {
    UnboundKey::new(&AES_256_GCM, key)
        .map(LessSafeKey::new)
        .map_err(|_| ())
}

fn f1_aad(aad: &[u8]) -> Vec<u8> {
    let mut a = Vec::with_capacity(aad.len() + 3);
    a.extend_from_slice(aad);
    a.extend_from_slice(b"|f1");
    a
}

/// `head ++ body` sealed into ONE buffer from `alloc` (the NIF passes a BEAM
/// binary): the input is copied once, encrypted in place, the tag appended.
fn seal_parts<B: DerefMut<Target = [u8]>>(
    c: &LessSafeKey,
    nonce: [u8; NONCE],
    aad: &[u8],
    head: &[u8],
    body: &[u8],
    alloc: impl FnOnce(usize) -> Option<B>,
) -> Result<B, ()> {
    let n = head.len() + body.len();
    let mut buf = alloc(n + TAG).ok_or(())?;
    buf[..head.len()].copy_from_slice(head);
    buf[head.len()..n].copy_from_slice(body);
    let tag = c
        .seal_in_place_separate_tag(
            Nonce::assume_unique_for_key(nonce),
            Aad::from(aad),
            &mut buf[..n],
        )
        .map_err(|_| ())?;
    buf[n..].copy_from_slice(tag.as_ref());
    Ok(buf)
}

/// `{ct_with_tag, nonce_field}`; `alloc` gives the ciphertext buffer.
pub fn seal<B: DerefMut<Target = [u8]>>(
    plain: &[u8],
    key: &[u8],
    aad: &[u8],
    mode: Mode,
    alloc: impl FnOnce(usize) -> Option<B>,
) -> Result<(B, Vec<u8>), ()> {
    let mut nonce = [0u8; NONCE];
    getrandom::getrandom(&mut nonce).map_err(|_| ())?;
    seal_with_nonce(plain, key, aad, mode, nonce, alloc)
}

pub fn seal_with_nonce<B: DerefMut<Target = [u8]>>(
    plain: &[u8],
    key: &[u8],
    aad: &[u8],
    mode: Mode,
    nonce: [u8; NONCE],
    alloc: impl FnOnce(usize) -> Option<B>,
) -> Result<(B, Vec<u8>), ()> {
    let c = cipher(key)?;
    // Empty input stays format 0: revisions' has_content? reads "ct is only a tag".
    if mode == Mode::None || plain.is_empty() {
        let ct = seal_parts(&c, nonce, aad, &[], plain, alloc)?;
        return Ok((ct, nonce.to_vec()));
    }

    // :auto keeps zstd only if it saves 10%. Under SAMPLE the sample IS the
    // input, so its compression is the result: compress once, not twice.
    let worth = |z: &Vec<u8>, of: usize| z.len() * 10 <= of * 9;
    let zipped = match mode {
        Mode::Auto if plain.len() > SAMPLE => compress(&plain[..SAMPLE])
            .filter(|z| worth(z, SAMPLE))
            .and_then(|_| compress(plain)),
        Mode::Auto => compress(plain).filter(|z| worth(z, plain.len())),
        _ => compress(plain),
    };
    let (codec, payload) = match &zipped {
        Some(z) if z.len() < plain.len() => (CODEC_ZSTD, z.as_slice()),
        _ => (CODEC_RAW, plain),
    };
    let ct = seal_parts(&c, nonce, &f1_aad(aad), &[codec], payload, alloc)?;

    let mut field = Vec::with_capacity(1 + NONCE);
    field.push(FORMAT_1);
    field.extend_from_slice(&nonce);
    Ok((ct, field))
}

/// What `open` decrypted: the plaintext is `buf[skip..]` of the buffer from
/// `alloc` (format 0 and raw format 1, no further copy), or a zstd frame's
/// decoded output.
pub enum Opened<B> {
    InPlace(B, usize),
    Inflated(Vec<u8>),
}

pub fn open<B: DerefMut<Target = [u8]>>(
    ct: &[u8],
    nonce_field: &[u8],
    key: &[u8],
    aad: &[u8],
    alloc: impl FnOnce(usize) -> Option<B>,
) -> Result<Opened<B>, ()> {
    let c = cipher(key)?;
    if ct.len() < TAG {
        return Err(());
    }
    let (body, tag) = ct.split_at(ct.len() - TAG);
    let (nonce, aad, f1) = match nonce_field.len() {
        NONCE => (nonce_field, Cow::Borrowed(aad), false),
        l if l == NONCE + 1 && nonce_field[0] == FORMAT_1 => {
            (&nonce_field[1..], Cow::Owned(f1_aad(aad)), true)
        }
        _ => return Err(()),
    };
    let nonce = Nonce::try_assume_unique_for_key(nonce).map_err(|_| ())?;
    let tag = Tag::try_from(tag).map_err(|_| ())?;
    let mut buf = alloc(body.len()).ok_or(())?;
    buf.copy_from_slice(body);
    c.open_in_place_separate_tag(nonce, Aad::from(&*aad), tag, &mut buf, 0..)
        .map_err(|_| ())?;
    if !f1 {
        return Ok(Opened::InPlace(buf, 0));
    }
    match buf.first().copied() {
        Some(CODEC_RAW) => Ok(Opened::InPlace(buf, 1)),
        Some(CODEC_ZSTD) => decompress(&buf[1..]).map(Opened::Inflated).ok_or(()),
        _ => Err(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const K: [u8; 32] = [7; 32];

    // Vec-backed versions of the engine's API (the NIF passes BEAM binaries).
    // Local items shadow the glob import above.
    fn vec(n: usize) -> Option<Vec<u8>> {
        Some(vec![0; n])
    }

    fn seal(plain: &[u8], key: &[u8], aad: &[u8], mode: Mode) -> Result<(Vec<u8>, Vec<u8>), ()> {
        super::seal(plain, key, aad, mode, vec)
    }

    fn seal_with_nonce(
        plain: &[u8],
        key: &[u8],
        aad: &[u8],
        mode: Mode,
        nonce: [u8; NONCE],
    ) -> Result<(Vec<u8>, Vec<u8>), ()> {
        super::seal_with_nonce(plain, key, aad, mode, nonce, vec)
    }

    fn open(ct: &[u8], nonce: &[u8], key: &[u8], aad: &[u8]) -> Result<Vec<u8>, ()> {
        match super::open(ct, nonce, key, aad, vec)? {
            Opened::InPlace(buf, skip) => Ok(buf[skip..].to_vec()),
            Opened::Inflated(v) => Ok(v),
        }
    }

    fn rt(plain: &[u8], mode: Mode) -> (Vec<u8>, Vec<u8>) {
        let (ct, n) = seal(plain, &K, b"notes:content:x", mode).unwrap();
        assert_eq!(open(&ct, &n, &K, b"notes:content:x").unwrap(), plain);
        (ct, n)
    }

    #[test]
    fn round_trips_every_mode_and_size() {
        let text = "Some markdown with [[links]] and #tags.\n".repeat(5_000);
        for p in [&b""[..], b"x", text.as_bytes()] {
            for m in [Mode::None, Mode::Zstd, Mode::Auto] {
                rt(p, m);
            }
        }
    }

    #[test]
    fn formats() {
        let text = "repeat ".repeat(1_000);
        assert_eq!(rt(text.as_bytes(), Mode::None).1.len(), 12);
        assert_eq!(rt(b"", Mode::Zstd).1.len(), 12);
        let (ct, n) = rt(text.as_bytes(), Mode::Zstd);
        assert_eq!(n.len(), 13);
        assert!(ct.len() < text.len());
    }

    #[test]
    fn incompressible_auto_stays_raw_but_versioned() {
        let mut noise = vec![0u8; 200_000];
        getrandom::getrandom(&mut noise).unwrap();
        let (ct, n) = rt(&noise, Mode::Auto);
        assert_eq!(n[0], 1);
        assert_eq!(ct.len(), noise.len() + 1 + TAG);
    }

    #[test]
    fn tamper_fails_closed() {
        let text = "abc ".repeat(500);
        let (ct, n) = seal(text.as_bytes(), &K, b"a", Mode::Zstd).unwrap();
        let mut bad_format = n.clone();
        bad_format[0] = 2;
        assert!(open(&ct, &bad_format, &K, b"a").is_err());
        assert!(open(&ct, &n[1..], &K, b"a").is_err()); // format byte dropped
        assert!(open(&ct, &n, &K, b"b").is_err()); // wrong AAD
        assert!(open(&ct, &n, &[8; 32], b"a").is_err()); // wrong key
        let mut flipped = ct.clone();
        flipped[0] ^= 1;
        assert!(open(&flipped, &n, &K, b"a").is_err());
        assert!(open(&ct[..10], &n, &K, b"a").is_err());
        assert!(open(&ct, &n, &K[..31], b"a").is_err());
    }

    #[test]
    fn format_zero_matches_known_answer() {
        // NIST-style KAT: all-zero key and nonce, empty plaintext and AAD.
        let (ct, _) = seal_with_nonce(b"", &[0; 32], b"", Mode::None, [0; 12]).unwrap();
        assert_eq!(hex(&ct), "530f8afbc74536b9a963b4f1c4cb738b");
    }

    #[test]
    fn format_zero_matches_known_answer_with_aad() {
        // From OTP :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, pt, aad, true):
        // key = 0..=31, iv = 0xa0..=0xab. Pins CTR over a non-empty body and
        // GHASH over a non-empty AAD.
        let key: Vec<u8> = (0..32).collect();
        let iv: [u8; 12] = core::array::from_fn(|i| 0xa0 + i as u8);
        let pt = b"Engram envelope known-answer vector, non-empty.";
        let (ct, n) =
            seal_with_nonce(pt, &key, b"notes:content:0b7e2b1c-kat", Mode::None, iv).unwrap();
        assert_eq!(n, iv);
        assert_eq!(
            hex(&ct),
            "a3761b5f24a622da0c13e2bf680aa5fe1bc23667fc9a2302ef7943f45fdd1062\
             a61935d38f4c3c5372f969b87d03adb93135b8b442f9de866b87442e9b456c"
        );
    }

    /// A format-1 ciphertext over an arbitrary body, sealed with the real
    /// cipher and AAD, so `open` gets past authentication.
    fn seal_f1_body(body: &[u8], aad: &[u8]) -> (Vec<u8>, Vec<u8>) {
        let nonce = [9u8; NONCE];
        let buf = seal_parts(&cipher(&K).unwrap(), nonce, &f1_aad(aad), &[], body, vec).unwrap();
        let mut field = vec![FORMAT_1];
        field.extend_from_slice(&nonce);
        (buf, field)
    }

    #[test]
    fn authenticated_but_malformed_format_one_bodies_fail_closed() {
        let frame = compress(&b"abc ".repeat(500)).unwrap();
        let mut junk_frame = frame.clone();
        let mid = junk_frame.len() / 2;
        junk_frame[mid] ^= 0xff;
        let bodies = vec![
            vec![],                                                  // no codec byte
            vec![2, 1, 2, 3],                                        // unknown codec
            vec![CODEC_ZSTD],                                        // empty frame
            [&[CODEC_ZSTD][..], &frame[..frame.len() / 2]].concat(), // truncated
            [&[CODEC_ZSTD][..], &junk_frame].concat(),               // corrupt (checksum)
            [&[CODEC_ZSTD][..], b"not a zstd frame at all"].concat(),
            [&[CODEC_ZSTD][..], &frame, b"trailing"].concat(),
        ];
        for body in bodies {
            let (ct, n) = seal_f1_body(&body, b"a");
            assert!(open(&ct, &n, &K, b"a").is_err(), "{body:?}");
        }
        // The harness itself is sound: a well-formed body opens.
        let (ct, n) = seal_f1_body(&[&[CODEC_ZSTD][..], &frame].concat(), b"a");
        assert_eq!(open(&ct, &n, &K, b"a").unwrap(), b"abc ".repeat(500));
    }

    /// A hand-built zstd frame: no checksum, 1 KB window, an 8-byte content
    /// size of `claimed`, and one raw last block holding `data`.
    fn raw_frame(claimed: u64, data: &[u8]) -> Vec<u8> {
        let mut f = vec![0x28, 0xb5, 0x2f, 0xfd, 0b1100_0000, 0x00];
        f.extend_from_slice(&claimed.to_le_bytes());
        let block = (data.len() as u32) << 3 | 1; // raw, last
        f.extend_from_slice(&block.to_le_bytes()[..3]);
        f.extend_from_slice(data);
        f
    }

    #[test]
    fn a_frame_that_lies_about_its_size_fails_without_allocating_it() {
        use crate::memory;
        let open_body = |frame: &[u8]| {
            let (ct, n) = seal_f1_body(&[&[CODEC_ZSTD][..], frame].concat(), b"a");
            memory::measured(|| open(&ct, &n, &K, b"a"))
        };
        // Truthful: the hand-built frame is valid.
        assert_eq!(open_body(&raw_frame(5, b"hello")).0.unwrap(), b"hello");
        // Claims 1 TiB. The bulk decoder reserved the claim up front, which
        // aborts the node; the stream decodes 5 bytes and zstd rejects it.
        let (out, peak) = open_body(&raw_frame(1 << 40, b"hello"));
        assert!(out.is_err());
        assert!(peak < 1 << 20, "peak {peak}");
        // Claims less than it holds.
        assert!(open_body(&raw_frame(2, b"hello")).0.is_err());
        assert!(open_body(&raw_frame(0, b"hello")).0.is_err());
    }

    /// A real frame of `size` zeros compressed with a `2^window_log` window.
    /// zstd shrinks the window to the source, so `size` must exceed it.
    fn frame_with_window(window_log: u32, size: usize) -> Vec<u8> {
        let mut z = zstd::bulk::Compressor::new(LEVEL).unwrap();
        z.include_contentsize(true).unwrap();
        z.window_log(window_log).unwrap();
        z.compress(&vec![0u8; size]).unwrap()
    }

    #[test]
    fn a_frame_demanding_a_window_past_the_cap_is_rejected() {
        let size = 40 << 20;
        // At the cap: decodes. Past it (and zstd's 2^27 default): refused at
        // the header, before the window buffer is allocated.
        let ok = frame_with_window(WINDOW_LOG_MAX, size);
        assert_eq!(decompress(&ok).unwrap().len(), size);
        for log in [WINDOW_LOG_MAX + 1, 25] {
            let frame = frame_with_window(log, size);
            assert!(decompress(&frame).is_none(), "{log}");
            let (ct, n) = seal_f1_body(&[&[CODEC_ZSTD][..], &frame].concat(), b"a");
            assert!(open(&ct, &n, &K, b"a").is_err(), "{log}");
        }
        // What `seal` writes at level 3 stays under the cap: 1-3 MB notes,
        // half random so they do not collapse to a tiny frame.
        for size in [1 << 20, 2 << 20, 3 << 20] {
            let mut plain = vec![0u8; size];
            getrandom::getrandom(&mut plain[..size / 2]).unwrap();
            rt(&plain, Mode::Zstd);
        }
    }

    #[test]
    fn decodes_past_the_starting_buffer() {
        // Highly compressible, so the output must grow many times over the
        // frame-sized start: exercises the reserve loop.
        let plain = vec![b'z'; 3 << 20];
        let frame = compress(&plain).unwrap();
        assert!(frame.len() * 8 < plain.len() / 8);
        assert_eq!(decompress(&frame).unwrap(), plain);
    }

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    #[test]
    fn open_never_panics_on_garbage() {
        let mut seed = 1u64;
        for _ in 0..20_000 {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            let len = (seed % 64) as usize;
            let junk: Vec<u8> = (0..len).map(|i| (seed >> (i % 8)) as u8).collect();
            let nlen = [0usize, 11, 12, 13, 14][(seed % 5) as usize];
            let _ = open(&junk, &junk[..nlen.min(junk.len())], &K, b"a");
        }
    }

    /// AES-256-GCM microbench, RustCrypto `aes-gcm` vs `ring`, no BEAM:
    /// `cargo test --release bench_aes_gcm -- --ignored --nocapture`.
    /// Each iteration copies the input into the work buffer, as the NIF does.
    #[test]
    #[ignore]
    fn bench_aes_gcm_vs_ring() {
        use aes_gcm::aead::{AeadInPlace, KeyInit};
        use aes_gcm::{Aes256Gcm, Nonce as ANonce};
        use std::time::Instant;
        fn best(mut f: impl FnMut()) -> f64 {
            let n = 50;
            (0..15)
                .map(|_| {
                    let t = Instant::now();
                    for _ in 0..n {
                        f();
                    }
                    t.elapsed().as_secs_f64() * 1e6 / n as f64
                })
                .fold(f64::MAX, f64::min)
        }
        let aad = b"notes:content:x";
        let nonce = [3u8; NONCE];
        let rc = Aes256Gcm::new_from_slice(&K).unwrap();
        let rk = cipher(&K).unwrap();
        println!("size   | aes-gcm seal | aes-gcm open | ring seal | ring open | MB/s open a/r | open speedup | copy only");
        for (label, sz) in [
            ("2KB", 2048),
            ("10KB", 10240),
            ("100KB", 102_400),
            ("1MB", 1 << 20),
        ] {
            let plain: Vec<u8> = (0..sz).map(|i| (i * 31 % 251) as u8).collect();
            let mut buf = Vec::with_capacity(sz + TAG);
            let mut ct = plain.clone();
            let tag = rc
                .encrypt_in_place_detached(ANonce::from_slice(&nonce), aad, &mut ct)
                .unwrap();
            let a_seal = best(|| {
                buf.clear();
                buf.extend_from_slice(&plain);
                let t = rc
                    .encrypt_in_place_detached(ANonce::from_slice(&nonce), aad, &mut buf)
                    .unwrap();
                let _ = std::hint::black_box(t);
            });
            let a_open = best(|| {
                buf.clear();
                buf.extend_from_slice(&ct);
                rc.decrypt_in_place_detached(ANonce::from_slice(&nonce), aad, &mut buf, &tag)
                    .unwrap();
            });
            let r_seal = best(|| {
                buf.clear();
                buf.extend_from_slice(&plain);
                let t = rk
                    .seal_in_place_separate_tag(
                        Nonce::assume_unique_for_key(nonce),
                        Aad::from(aad),
                        &mut buf,
                    )
                    .unwrap();
                let _ = std::hint::black_box(t);
            });
            let r_open = best(|| {
                buf.clear();
                buf.extend_from_slice(&ct);
                buf.extend_from_slice(&tag);
                let out = rk
                    .open_in_place(
                        Nonce::assume_unique_for_key(nonce),
                        Aad::from(aad),
                        &mut buf,
                    )
                    .unwrap();
                assert_eq!(out.len(), sz);
            });
            // The one copy the NIF keeps (input into the output binary).
            let copy = best(|| {
                buf.clear();
                buf.extend_from_slice(std::hint::black_box(&ct));
                std::hint::black_box(&buf);
            });
            let mbs = |us: f64| sz as f64 / us;
            println!(
                "{label:6} | {a_seal:12.1} | {a_open:12.1} | {r_seal:9.1} | {r_open:9.1} | {:5.0}/{:5.0} | {:.2}x | {copy:.1}",
                mbs(a_open),
                mbs(r_open),
                a_open / r_open
            );
        }
    }
}
