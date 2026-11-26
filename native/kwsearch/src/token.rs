//! Signed per-request tokens (security F7, F14).
//!
//! `token = b64url(payload) "." b64url(HMAC-SHA256(key, b64url(payload)))`,
//! no padding. The app signs with its current key; kwsearch accepts any key
//! in its list (current, then next), so a key rolls without a lockstep
//! restart: add the next key here, switch the app, drop the old one here.
//! A search token names the user and the vaults, so the request body cannot
//! widen them.

use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use base64::Engine;
use hmac::{KeyInit, Mac};
use serde::Deserialize;
use uuid::Uuid;

type HmacSha256 = hmac::Hmac<sha2::Sha256>;

/// A token may not live longer than this past its signing (the app uses 60 s).
pub const MAX_TTL_S: u64 = 300;

#[derive(Deserialize, Debug, PartialEq)]
#[serde(tag = "s", rename_all = "lowercase")]
pub enum Claims {
    Search { u: Uuid, v: Vec<Uuid>, exp: u64 },
    Ops { exp: u64 },
}

impl Claims {
    fn exp(&self) -> u64 {
        match self {
            Claims::Search { exp, .. } | Claims::Ops { exp } => *exp,
        }
    }
}

pub struct Keys(Vec<Vec<u8>>);

impl Keys {
    /// One key per non-empty line: current first, then the optional next.
    pub fn parse(file: &str) -> Result<Keys, String> {
        let keys: Vec<Vec<u8>> = file
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .map(|l| l.as_bytes().to_vec())
            .collect();
        match keys.len() {
            0 => Err("token key file holds no key".into()),
            1 | 2 if keys.iter().all(|k| k.len() >= 32) => Ok(Keys(keys)),
            1 | 2 => Err("token keys must be at least 32 bytes".into()),
            _ => Err("token key file holds more than two keys (current, next)".into()),
        }
    }

    /// The claims of a token that verifies under any key and has not
    /// expired at `now` (unix seconds). None on anything else.
    pub fn verify(&self, token: &str, now: u64) -> Option<Claims> {
        let (payload, sig) = token.split_once('.')?;
        let sig = B64.decode(sig).ok()?;
        let ok = self.0.iter().any(|k| {
            let mut m = HmacSha256::new_from_slice(k).expect("hmac takes any key length");
            m.update(payload.as_bytes());
            m.verify_slice(&sig).is_ok() // constant time
        });
        if !ok {
            return None;
        }
        let claims: Claims = serde_json::from_slice(&B64.decode(payload).ok()?).ok()?;
        let exp = claims.exp();
        (exp > now && exp <= now + MAX_TTL_S).then_some(claims)
    }
}

/// Signs `payload` (JSON) with `key`. Test and harness use; the app has
/// its own signer (`Engram.KeywordStore.Tantivy`).
pub fn sign(key: &[u8], payload: &str) -> String {
    let p = B64.encode(payload);
    let mut m = HmacSha256::new_from_slice(key).expect("hmac takes any key length");
    m.update(p.as_bytes());
    format!("{p}.{}", B64.encode(m.finalize().into_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::{Rng, SeedableRng};

    const A: &str = "0123456789abcdef0123456789abcdef-current";
    const B: &str = "fedcba9876543210fedcba9876543210-next-key";
    const NOW: u64 = 1_800_000_000;

    fn search(exp: u64) -> String {
        format!(
            r#"{{"s":"search","u":"00000000-0000-4000-8000-000000000001","v":["00000000-0000-4000-8000-000000000002"],"exp":{exp}}}"#
        )
    }

    #[test]
    fn either_key_passes_during_an_overlap_and_a_retired_key_fails() {
        let both = Keys::parse(&format!("{A}\n{B}\n")).unwrap();
        let t_old = sign(A.as_bytes(), &search(NOW + 60));
        let t_new = sign(B.as_bytes(), &search(NOW + 60));
        assert!(both.verify(&t_old, NOW).is_some());
        assert!(both.verify(&t_new, NOW).is_some());
        let retired = Keys::parse(B).unwrap();
        assert!(retired.verify(&t_old, NOW).is_none());
        assert!(retired.verify(&t_new, NOW).is_some());
    }

    #[test]
    fn claims_carry_user_and_vaults() {
        let k = Keys::parse(A).unwrap();
        match k.verify(&sign(A.as_bytes(), &search(NOW + 1)), NOW) {
            Some(Claims::Search { u, v, .. }) => {
                assert_eq!(u.as_u128(), 0x0000_0000_0000_4000_8000_0000_0000_0001);
                assert_eq!(v.len(), 1);
            }
            other => panic!("{other:?}"),
        }
        let ops = sign(A.as_bytes(), &format!(r#"{{"s":"ops","exp":{}}}"#, NOW + 5));
        assert_eq!(k.verify(&ops, NOW), Some(Claims::Ops { exp: NOW + 5 }));
    }

    #[test]
    fn expired_far_future_and_malformed_tokens_fail() {
        let k = Keys::parse(A).unwrap();
        assert!(k.verify(&sign(A.as_bytes(), &search(NOW)), NOW).is_none());
        assert!(k
            .verify(&sign(A.as_bytes(), &search(NOW + MAX_TTL_S + 1)), NOW)
            .is_none());
        assert!(k
            .verify(
                &sign(A.as_bytes(), r#"{"s":"admin","exp":1800000060}"#),
                NOW
            )
            .is_none());
        for bad in ["", ".", "abc", "abc.def", "...."] {
            assert!(k.verify(bad, NOW).is_none(), "{bad}");
        }
        assert!(Keys::parse("").is_err());
        assert!(Keys::parse("short").is_err());
        assert!(Keys::parse(&format!("{A}\n{B}\n{A}")).is_err());
    }

    // Property: flipping any single byte of a valid token, or of its
    // payload before signing it with another key, never verifies.
    #[test]
    fn any_tampered_byte_fails() {
        let k = Keys::parse(A).unwrap();
        let good = sign(A.as_bytes(), &search(NOW + 60));
        let mut rng = rand::rngs::StdRng::seed_from_u64(42);
        for _ in 0..2000 {
            let mut b = good.clone().into_bytes();
            let i = rng.random_range(0..b.len());
            let c = b[i];
            b[i] = loop {
                let n = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_."
                    [rng.random_range(0..65)];
                if n != c {
                    break n;
                }
            };
            let t = String::from_utf8(b).unwrap();
            assert!(k.verify(&t, NOW).is_none(), "{t}");
        }
        let forged = sign(b"some-other-key-0123456789abcdef0123", &search(NOW + 60));
        assert!(k.verify(&forged, NOW).is_none());
    }
}
