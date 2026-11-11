"""Fail if a wasm module imports anything outside ALLOWED, or does not
export EXPORT (without it, the linker could drop the code under test and the
import check would pass vacuously).

Usage: python3 imports.py module.wasm

The clients will run engram_core as wasm32 with nothing from their host but
memory: callers draw nonces, so no entropy import (were ring's RNG to become
reachable, getrandom's unregistered custom hook would surface here as one),
and no WASI. Reads the import section by hand; no wasm toolchain needed.
"""

import sys

ALLOWED = set()  # (module, name) pairs; none today.
EXPORT = "guard_roundtrip"


def leb(b, i):
    n = shift = 0
    while True:
        byte = b[i]
        i += 1
        n |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return n, i


def name(b, i):
    n, i = leb(b, i)
    return b[i : i + n].decode(), i + n


def limits(b, i):
    flags = b[i]
    _, i = leb(b, i + 1)
    if flags & 1:
        _, i = leb(b, i)
    return i


def sections(b):
    assert b[:4] == b"\0asm", "not a wasm module"
    i = 8
    while i < len(b):
        sid = b[i]
        size, i = leb(b, i + 1)
        yield sid, i
        i += size


def exports(b):
    for sid, i in sections(b):
        if sid == 7:
            count, j = leb(b, i)
            for _ in range(count):
                field, j = name(b, j)
                _, j = leb(b, j + 1)  # kind byte, then index
                yield field


def imports(b):
    for sid, i in sections(b):
        if sid == 2:
            count, j = leb(b, i)
            for _ in range(count):
                mod, j = name(b, j)
                field, j = name(b, j)
                kind = b[j]
                j += 1
                if kind in (0, 4):  # func: typeidx; tag: attribute, typeidx
                    j = j + 1 if kind == 4 else j
                    _, j = leb(b, j)
                elif kind == 1:  # table: reftype, limits
                    j = limits(b, j + 1)
                elif kind == 2:  # memory: limits
                    j = limits(b, j)
                elif kind == 3:  # global: valtype, mutability
                    j += 2
                else:
                    raise ValueError(f"unknown import kind {kind}")
                yield mod, field


if __name__ == "__main__":
    wasm = open(sys.argv[1], "rb").read()
    if EXPORT not in exports(wasm):
        sys.exit(f"::error::{sys.argv[1]} does not export {EXPORT}")
    found = list(imports(wasm))
    bad = [imp for imp in found if imp not in ALLOWED]
    print(f"exports {EXPORT}; {len(found)} import(s): {found}")
    if bad:
        sys.exit(f"::error::{sys.argv[1]} imports from its host: {bad}")
