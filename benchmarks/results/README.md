# Results

Timestamped JSON per run, so numbers can be compared over time instead of
scrolling past in a terminal. Notable findings are written up here.

---

## LLM serving — 2026-08-27

`qwen3.6-a3b` (Qwen3.6-35B-A3B, Q4_K_M, ~22 GB) through LiteLLM to Ollama on the
RTX 5090. 256 max tokens, 2 reps per level, warm model.

| Concurrency | TTFT p50 | Gen tok/s | **Aggregate tok/s** | Latency p50 | Latency max |
|-------------|----------|-----------|---------------------|-------------|-------------|
| 1 | 0.25 s | 229.5 | 187.4 | 1.4 s | 1.4 s |
| 2 | 0.83 s | 225.9 | 200.9 | 2.0 s | 2.6 s |
| 4 | 2.01 s | 227.5 | 209.0 | 3.1 s | 4.9 s |

GPU during the run: **79 % peak utilisation, 274 W, 49 °C, 24.2 GB VRAM**.

### The finding: requests are serialised

Per-stream generation is flat at ~227 tok/s regardless of load, while TTFT grows
almost linearly — 0.25 s → 0.83 s → 2.01 s — and aggregate throughput barely
moves, up only 11 % going from one request to four.

That is the signature of queueing, not parallelism. Each request runs at full
speed *when it is its turn*, and waits the rest of the time. The cause is
`OLLAMA_NUM_PARALLEL=1` on the workstation.

### Why this matters

The hardware is not the limit. At peak the card was at 79 % utilisation, 274 W
against a 575 W board, and 49 °C — nowhere near thermal or power limits, with
roughly 8 GB of VRAM unused.

So a second concurrent user does not get a slower answer, they get the same
answer later. For one person that is invisible. For two people, or an agent
issuing parallel calls, it is the whole experience.

### Worth trying

Raise `OLLAMA_NUM_PARALLEL` to 2 and re-run. Each parallel slot needs its own KV
cache, so VRAM is the constraint: ~8 GB spare against a 22 GB model suggests two
slots is plausible and four is not. If aggregate throughput roughly doubles,
that is a free doubling of serving capacity from a configuration change.

Re-run with `CONCURRENCY=1,2,4 REPS=3` and compare against this table.

### Caveats

- Token counts are streamed-chunk counts, near enough to tokens for comparing
  runs against each other, which is the point. Do not quote them as absolute.
- Single prompt, single output length. Long-context behaviour is not measured
  here and will be worse.
- The warm-up request cost **13.9 s** — a cold 22 GB model load. With a 5 minute
  keep-alive, the first request after an idle period pays that.
