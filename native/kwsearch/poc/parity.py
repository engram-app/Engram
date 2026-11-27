"""Quality parity of kwsearch runs vs the keyword bench (engram-workspace
reports/2026-11-24-keyword-storage). Reuses that bench's loaders and metrics.
usage: KW=<bench data dir with corpus.jsonl + runs/> BENCH=<bench dir> python parity.py run.json [run.json...]"""
import json, os, sys
import numpy as np
sys.path.insert(0, os.environ["BENCH"])
from common import corpus, notes_top, note_rel, per_query, queries  # noqa: E402
from evaluate import boot  # noqa: E402

note_of = {c["id"]: c["note"] for c in corpus()}
qs = queries()
for q in qs:
    if q["crel"] is not None:
        q["nrel"] = note_rel(q["crel"], note_of)
runs_dir = os.path.join(os.environ["KW"], "runs")
BASE = json.load(open(f"{runs_dir}/qdrant_chunk.json"))["runs"]
TV = json.load(open(f"{runs_dir}/tantivy_freq.json"))["runs"]


def metrics(runs):
    m = {}
    sub = lambda p: [q for q in qs if q["set"].startswith(p)]
    note = lambda q: notes_top(runs.get(q["qid"], []), note_of)
    m["exact_note_s5"] = np.array([per_query(note(q), q["nrel"])["s5"] for q in sub("exact")])
    m["exact_chunk_s5"] = np.array([per_query(runs.get(q["qid"], []), q["crel"])["s5"] for q in sub("exact")])
    m["natural_note_ndcg10"] = np.array([per_query(note(q), q["nrel"])["ndcg10"] for q in sub("natural")])
    m["keyword_note_r10"] = np.array([per_query(note(q), q["nrel"])["r10"] for q in sub("natural:keyword")])
    return m


def overlap(a, b):
    """mean top-10 chunk overlap between two runs, over every query."""
    return float(np.mean([len(set(a.get(q["qid"], [])[:10]) & set(b.get(q["qid"], [])[:10])) /
                          max(1, min(10, len(b.get(q["qid"], [])))) for q in qs]))


mb, mt = metrics(BASE), metrics(TV)
out = {"bench_tantivy": {k: round(float(v.mean()), 4) for k, v in mt.items()}}
for f in sys.argv[1:]:
    runs = json.load(open(f))["runs"]
    m = metrics(runs)
    row = {k: round(float(v.mean()), 4) for k, v in m.items()}
    row.update({k + "_ratio_vs_qdrant": boot(v, mb[k]) for k, v in m.items()})
    row["top10_overlap_vs_bench_tantivy"] = round(overlap(runs, TV), 4)
    out[os.path.basename(f)[:-5]] = row
if len(sys.argv) > 2:
    a, b = (json.load(open(f))["runs"] for f in sys.argv[1:3])
    out["top10_overlap_first_two"] = round(overlap(a, b), 4)
print(json.dumps(out, indent=1))
