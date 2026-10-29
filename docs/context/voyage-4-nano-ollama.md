# voyage-4-nano on Ollama (staging, dev, opt-in self-host)

voyage-4-nano is the open-weights (Apache 2.0, 340M params, 32k context) member
of the voyage-4 family. Its vectors share one space with the Voyage API's
voyage-4-large and voyage-4-lite, so a staging collection can mix nano points
with points prod's models made, and any of them can query the rest. Issue
Engram#2127.

## Only the official GGUF is in the space

`ollama pull hf.co/MongoDB/voyage-4-nano-GGUF:Q8_0` (374 MB; `:F16` is 699 MB
and closest to the original). Needs Ollama 0.40.7 or newer (older fails with
`wrong number of tensors`). Community GGUF/ONNX conversions made before
llama.cpp supported the model load fine but are NOT in the voyage-4 space
(causal attention, no final 1024 -> 2048 projection). Source: the model cards
at huggingface.co/MongoDB/voyage-4-nano-GGUF and huggingface.co/voyageai/voyage-4-nano
(read 2026-10-29).

## What the adapter does for nano

`Engram.Embedders.Ollama` applies these only when `Engram.EmbedModels.nano?/1`
matches the model name (any tag containing `voyage-4-nano`). Other Ollama
models are untouched.

- Purpose prompt: `:query` gets `Represent the query for retrieving supporting documents: `,
  every other purpose (`:index`, `:maintenance`) gets `Represent the document for retrieval: `.
  The Voyage API adds these server-side from `input_type`; Ollama does not.
- NFC normalisation: llama.cpp's tokenizer skips it, so NFD text (macOS file
  names) would embed differently.
- `dimensions` from `EMBED_DIMS`: the model emits 2048-d; Ollama truncates
  (Matryoshka) and re-normalises. Our collection is 1024-d, so set `EMBED_DIMS=1024`.
- `options: {num_ctx, num_batch}` from `OLLAMA_NUM_CTX`: bidirectional
  attention means one input must fit one batch, so both are equal. Unset, the
  repo's params reserve 32k (~6 GB); 8192 is ~1.3 GB. Changing it reloads
  the model, so set it once per deployment.
  - The ceiling: chunks are ~2.5 KB, but merged inputs reach `@max_merged_tokens`
    (7,500 estimated = ~30 KB), and dense text runs ~1.4 bytes/token, so a
    merged input can exceed 8192 real tokens. Ollama's `/api/embed` truncates
    over-length input by default (no error), so at 8192 such an input embeds
    its prefix only. Only 32768 (unset) rules that out. Fine for staging;
    revisit before recommending nano to self-hosters.

The per-plan doc model and the query model reach Ollama as the `:model` opt,
same as Voyage; before this change the Ollama adapter ignored it.

## Staging env (billing on, so per-plan models apply)

```
EMBED_BACKEND=ollama
OLLAMA_URL=http://<fastraid-ollama>:11434
OLLAMA_NUM_CTX=8192
EMBED_DIMS=1024
EMBED_MODEL=hf.co/MongoDB/voyage-4-nano-GGUF:Q8_0
DOC_EMBED_MODEL / QUERY_EMBED_MODEL: same value, or unset
DOC_EMBED_MODEL_{FREE,STARTER,PRO}=hf.co/MongoDB/voyage-4-nano-GGUF:Q8_0
QUERY_EMBED_MODEL_{FREE,STARTER,PRO}=hf.co/MongoDB/voyage-4-nano-GGUF:Q8_0
```

The per-plan vars matter: with billing on, unset plan vars default to
voyage-4-lite/large, and Ollama would be asked for a model it does not have.

## Switching self-heals

`EmbedModels.price/1` is 0 for nano. With every plan on nano,
`acceptable/1` is `[nano]`, so notes stamped `voyage-4-lite`/`voyage-4-large`
are `version_stale?` and the reconcile sweep re-embeds them with nano. No
backfill, no operator step. Switching back to the API re-embeds the other way.

## Self-host default NOT changed

Self-host still defaults to `nomic-embed-text` at 768-d (`.env.example`,
`docker-compose.yml`). `Qdrant.ensure_collection` never checks an existing
collection's vector size, so flipping the default to 1024-d nano would make
every upsert into an existing 768-d collection fail. A safe switch needs a
dims-mismatch migration (new collection + re-embed) first. Self-hosters can opt
in on a fresh install by setting the vars above.

## Stale elsewhere

The workspace doc `docs/context/embedding-optimization.md` predates this and
says nothing about nano; treat this doc as the source for nano.
