//! The envelope engine: optional zstd + AES-256-GCM in one call.
//!
//! Format 0: 12-byte nonce field, AAD as given, body = plaintext. Byte for
//! byte what OpenSSL `:crypto` wrote before this engine.
//! Format 1: nonce field `<<1, nonce::12>>`, AAD = caller AAD ++ "|f1" (so
//! the format byte is authenticated), body = `<<codec, payload>>` where
//! codec 0 = raw, 1 = one zstd frame (content size + checksum on).
use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce, Tag};
use std::cell::RefCell;

pub const TAG: usize = 16;
const NONCE: usize = 12;
const FORMAT_1: u8 = 1;
const CODEC_RAW: u8 = 0;
const CODEC_ZSTD: u8 = 1;
const LEVEL: i32 = 3;
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
    static DCTX: RefCell<Option<zstd::bulk::Decompressor<'static>>> = const { RefCell::new(None) };
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

fn decompress(frame: &[u8]) -> Option<Vec<u8>> {
    let size = zstd::zstd_safe::get_frame_content_size(frame).ok()??;
    DCTX.with(|d| {
        let mut d = d.borrow_mut();
        if d.is_none() {
            *d = Some(zstd::bulk::Decompressor::new().ok()?);
        }
        d.as_mut()?.decompress(frame, size as usize).ok()
    })
}

fn cipher(key: &[u8]) -> Result<Aes256Gcm, ()> {
    Aes256Gcm::new_from_slice(key).map_err(|_| ())
}

fn f1_aad(aad: &[u8]) -> Vec<u8> {
    let mut a = Vec::with_capacity(aad.len() + 3);
    a.extend_from_slice(aad);
    a.extend_from_slice(b"|f1");
    a
}

pub fn seal(plain: &[u8], key: &[u8], aad: &[u8], mode: Mode) -> Result<(Vec<u8>, Vec<u8>), ()> {
    let mut nonce = [0u8; NONCE];
    getrandom::getrandom(&mut nonce).map_err(|_| ())?;
    seal_with_nonce(plain, key, aad, mode, nonce)
}

pub fn seal_with_nonce(
    plain: &[u8],
    key: &[u8],
    aad: &[u8],
    mode: Mode,
    nonce: [u8; NONCE],
) -> Result<(Vec<u8>, Vec<u8>), ()> {
    let c = cipher(key)?;
    // Empty input stays format 0: revisions' has_content? reads "ct is only a tag".
    if mode == Mode::None || plain.is_empty() {
        let mut buf = Vec::with_capacity(plain.len() + TAG);
        buf.extend_from_slice(plain);
        let tag = c
            .encrypt_in_place_detached(Nonce::from_slice(&nonce), aad, &mut buf)
            .map_err(|_| ())?;
        buf.extend_from_slice(&tag);
        return Ok((buf, nonce.to_vec()));
    }

    let try_zstd = match mode {
        Mode::Auto => {
            let sample = &plain[..plain.len().min(SAMPLE)];
            matches!(compress(sample), Some(z) if z.len() * 10 <= sample.len() * 9)
        }
        _ => true,
    };
    let (codec, payload) = match try_zstd.then(|| compress(plain)).flatten() {
        Some(z) if z.len() < plain.len() => (CODEC_ZSTD, z),
        _ => (CODEC_RAW, plain.to_vec()),
    };

    let mut buf = Vec::with_capacity(1 + payload.len() + TAG);
    buf.push(codec);
    buf.extend_from_slice(&payload);
    let tag = c
        .encrypt_in_place_detached(Nonce::from_slice(&nonce), &f1_aad(aad), &mut buf)
        .map_err(|_| ())?;
    buf.extend_from_slice(&tag);

    let mut field = Vec::with_capacity(1 + NONCE);
    field.push(FORMAT_1);
    field.extend_from_slice(&nonce);
    Ok((buf, field))
}

pub fn open(ct: &[u8], nonce_field: &[u8], key: &[u8], aad: &[u8]) -> Result<Vec<u8>, ()> {
    let c = cipher(key)?;
    if ct.len() < TAG {
        return Err(());
    }
    let (body, tag) = ct.split_at(ct.len() - TAG);
    let mut buf = body.to_vec();
    match nonce_field.len() {
        NONCE => {
            c.decrypt_in_place_detached(
                Nonce::from_slice(nonce_field),
                aad,
                &mut buf,
                Tag::from_slice(tag),
            )
            .map_err(|_| ())?;
            Ok(buf)
        }
        l if l == NONCE + 1 && nonce_field[0] == FORMAT_1 => {
            c.decrypt_in_place_detached(
                Nonce::from_slice(&nonce_field[1..]),
                &f1_aad(aad),
                &mut buf,
                Tag::from_slice(tag),
            )
            .map_err(|_| ())?;
            match buf.split_first() {
                Some((&CODEC_RAW, rest)) => Ok(rest.to_vec()),
                Some((&CODEC_ZSTD, rest)) => decompress(rest).ok_or(()),
                _ => Err(()),
            }
        }
        _ => Err(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const K: [u8; 32] = [7; 32];

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
}
