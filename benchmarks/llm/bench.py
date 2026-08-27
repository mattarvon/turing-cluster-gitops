#!/usr/bin/env python3
"""
Measure LLM serving performance through the LiteLLM router.

Deliberately benchmarks the router rather than the inference server directly:
that is the path real requests take, so router overhead and model routing are
included rather than assumed away.

Reports, per model and per concurrency level:

  TTFT        time to first token - what a user perceives as responsiveness
  gen rate    output tokens/sec within a single stream
  aggregate   total output tokens/sec across all concurrent streams
  latency     wall clock for the whole request

Stdlib only: this runs on a cluster node with nothing installed.
"""

import argparse
import json
import os
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request

PROMPT = (
    "Explain what a Kubernetes DaemonSet is, when you would choose one over a "
    "Deployment, and give one concrete example. Be thorough."
)


def one_request(base_url, api_key, model, max_tokens, timeout):
    """Fire a single streaming completion. Returns a dict of measurements."""
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": PROMPT}],
        "stream": True,
        "max_tokens": max_tokens,
        "temperature": 0,
    }).encode()

    req = urllib.request.Request(
        f"{base_url}/v1/chat/completions",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )

    start = time.perf_counter()
    ttft = None
    chunks = 0
    text_len = 0

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    obj = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                choices = obj.get("choices") or []
                if not choices:
                    continue
                piece = (choices[0].get("delta") or {}).get("content") or ""
                if piece:
                    if ttft is None:
                        ttft = time.perf_counter() - start
                    chunks += 1
                    text_len += len(piece)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as exc:
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}

    total = time.perf_counter() - start
    if ttft is None:
        return {"ok": False, "error": "no content received"}

    gen_window = max(total - ttft, 1e-6)
    return {
        "ok": True,
        "ttft_s": ttft,
        "total_s": total,
        # One streamed chunk is approximately one token for these models. Close
        # enough for comparing runs against each other, which is the point.
        "tokens": chunks,
        "gen_tok_s": chunks / gen_window,
        "chars": text_len,
    }


def run_level(base_url, api_key, model, concurrency, reps, max_tokens, timeout):
    """Run `reps` rounds of `concurrency` simultaneous requests."""
    results = []
    wall_total = 0.0

    for _ in range(reps):
        out = [None] * concurrency
        threads = []
        round_start = time.perf_counter()

        def worker(idx):
            out[idx] = one_request(base_url, api_key, model, max_tokens, timeout)

        for i in range(concurrency):
            t = threading.Thread(target=worker, args=(i,))
            t.start()
            threads.append(t)
        for t in threads:
            t.join()

        wall_total += time.perf_counter() - round_start
        results.extend(r for r in out if r)

    good = [r for r in results if r.get("ok")]
    bad = [r for r in results if not r.get("ok")]

    if not good:
        return {
            "concurrency": concurrency,
            "ok": False,
            "errors": [r.get("error") for r in bad][:3],
        }

    total_tokens = sum(r["tokens"] for r in good)
    return {
        "concurrency": concurrency,
        "ok": True,
        "requests": len(good),
        "failed": len(bad),
        "ttft_p50": statistics.median(r["ttft_s"] for r in good),
        "ttft_max": max(r["ttft_s"] for r in good),
        "gen_tok_s_median": statistics.median(r["gen_tok_s"] for r in good),
        "latency_p50": statistics.median(r["total_s"] for r in good),
        "latency_max": max(r["total_s"] for r in good),
        # Aggregate is the number that reveals whether concurrency buys anything.
        "aggregate_tok_s": total_tokens / wall_total,
        "errors": [r.get("error") for r in bad][:3],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default=os.environ.get("LITELLM_URL", "http://localhost:32500"))
    ap.add_argument("--api-key", default=os.environ.get("LITELLM_KEY", ""))
    ap.add_argument("--models", default="qwen3.6-a3b")
    ap.add_argument("--concurrency", default="1,2,4")
    ap.add_argument("--reps", type=int, default=2)
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--json-out", default="")
    args = ap.parse_args()

    if not args.api_key:
        sys.exit("No API key. Set LITELLM_KEY or pass --api-key.")

    models = [m.strip() for m in args.models.split(",") if m.strip()]
    levels = [int(c) for c in args.concurrency.split(",") if c.strip()]

    report = {
        "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "base_url": args.base_url,
        "max_tokens": args.max_tokens,
        "reps": args.reps,
        "models": {},
    }

    for model in models:
        print(f"\n=== {model} ===", flush=True)

        # A cold model has to be pulled into VRAM first - tens of seconds for a
        # large one. Measuring that as if it were inference latency would be
        # meaningless, so warm up and discard.
        print("  warming up (model load can take a while) ...", flush=True)
        w = one_request(args.base_url, args.api_key, model, 16, args.timeout)
        if not w.get("ok"):
            print(f"  SKIPPED: {w.get('error')}", flush=True)
            report["models"][model] = {"ok": False, "error": w.get("error")}
            continue
        print(f"  warm. ttft {w['ttft_s']:.2f}s", flush=True)

        print(f"  {'conc':>4}  {'ttft p50':>9}  {'gen tok/s':>10}  "
              f"{'aggregate':>10}  {'lat p50':>8}  {'lat max':>8}", flush=True)

        rows = []
        for c in levels:
            r = run_level(args.base_url, args.api_key, model, c,
                          args.reps, args.max_tokens, args.timeout)
            rows.append(r)
            if r["ok"]:
                print(f"  {c:>4}  {r['ttft_p50']:>8.2f}s  "
                      f"{r['gen_tok_s_median']:>10.1f}  "
                      f"{r['aggregate_tok_s']:>10.1f}  "
                      f"{r['latency_p50']:>7.1f}s  {r['latency_max']:>7.1f}s"
                      + (f"   ({r['failed']} failed)" if r["failed"] else ""),
                      flush=True)
            else:
                print(f"  {c:>4}  FAILED: {r.get('errors')}", flush=True)
        report["models"][model] = {"ok": True, "levels": rows}

    if args.json_out:
        with open(args.json_out, "w") as fh:
            json.dump(report, fh, indent=2)
        print(f"\nWrote {args.json_out}", flush=True)


if __name__ == "__main__":
    main()
