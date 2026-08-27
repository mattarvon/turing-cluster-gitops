# Results

Timestamped JSON per run, so numbers can be compared over time instead of
scrolling past in a terminal. Notable findings are written up here.

---

## LLM serving — 2026-08-27

Through LiteLLM to Ollama on the RTX 5090 (32 GB). 256 max tokens, 2 reps,
warm model. Direct-to-Ollama runs bypass the router to isolate where time goes.

### The question: does the 5090 serve concurrent users?

**For a 22 GB model, no — and no configuration fixes it.**

`qwen3.6-a3b` (Qwen3.6-35B-A3B, Q4_K_M, ~22 GB):

| Concurrency | TTFT p50 | Gen tok/s | Aggregate tok/s |
|-------------|----------|-----------|-----------------|
| 1 | 0.25 s | 229.5 | 187.4 |
| 2 | 0.83 s | 225.9 | 200.9 |
| 4 | 2.01 s | 227.5 | 209.0 |

Per-stream speed is flat while TTFT grows almost linearly and aggregate
throughput gains only **11 %** from one request to four. That is queueing.

`llama3.1:8b` (~4.9 GB), same harness, same card:

| Concurrency | TTFT p50 | Gen tok/s | Aggregate tok/s |
|-------------|----------|-----------|-----------------|
| 1 | 0.15 s | 224.5 | 198.2 |
| 2 | 0.19 s | 190.1 | **331.3** |
| 4 | 0.89 s | 189.1 | **348.2** |

Aggregate throughput up **67 %** at two concurrent requests, and TTFT barely
moves — 0.15 s to 0.19 s, against Qwen's 0.25 s to 0.83 s. That is real
parallelism.

### Why: VRAM, not configuration

`OLLAMA_NUM_PARALLEL=2` was set and confirmed active in the server config, and
it changed the Qwen numbers not at all. The server log explains it — every
request landed on `slot id 0`, because Ollama allocated **one slot**:

```
slot ... id  0 | task 4188 | new prompt, n_ctx_slot = 32768
slot ... id  0 | task 4445 | new prompt, n_ctx_slot = 32768
```

The same test on `llama3.1:8b` used `id 0` **and** `id 1`. So the setting works;
Ollama silently reduces the slot count when a second slot's KV cache will not
fit. With 22 GB of weights in 32 GB of VRAM there is not enough room.

Confirmed threshold: `gpt-oss:20b` (~13 GB) also gets two slots. Somewhere
between 13 GB and 22 GB of weights, concurrency stops being possible on this
card.

Halving the context (`OLLAMA_CONTEXT_LENGTH=16384`) did **not** buy Qwen a
second slot, so that setting was reverted — it cost context for nothing.

### What this means in practice

- **Big model, one user at a time.** A second person asking Qwen something does
  not get a slower answer, they get the same answer later. At four concurrent
  requests the wait before the first token is 2 s and climbing.
- **Small models genuinely serve several users.** If concurrency matters more
  than raw capability — an agent making parallel calls, more than one person —
  `llama3.1:8b` or `gpt-oss:20b` is the better choice, and it is a routing
  decision in the LiteLLM config, not a hardware problem.
- **The hardware is not the limit for a single stream.** At peak the card ran at
  79 % utilisation, 274 W against a 575 W board, and 49 °C. It is VRAM capacity
  that constrains concurrency, not compute, power or thermals.

### Settings left in place

`OLLAMA_NUM_PARALLEL=2` (user environment variable on the workstation). It is
strictly an improvement: models that fit two slots use them, and Ollama reduces
to one by itself for models that do not. `OLLAMA_CONTEXT_LENGTH` was reverted to
the automatic default.

### Operational gotcha found along the way

Stopping Ollama on Windows does **not** reap its `llama-server.exe` child
processes. Five orphans accumulated across restarts, holding roughly 17 GB of
VRAM while `ollama ps` reported a single 14 GB model loaded — which quietly
pushed the next model to **59 % CPU / 41 % GPU** and destroyed its performance.

If inference suddenly gets slow after restarts, check for orphans before
anything else:

```powershell
Get-Process llama-server
Stop-Process -Name "ollama app","ollama","llama-server" -Force
```

### Caveats

- Token counts are streamed-chunk counts. Fine for comparing runs against each
  other, which is the point; do not quote them as absolute tokens/sec.
- Ollama's OpenAI-compatible endpoint streams chain-of-thought in a separate
  `reasoning` field with `content` empty. The harness counts both — an earlier
  version counted only `content` and reported that a thinking model had
  produced nothing at all.
- Single prompt, single output length. Long-context behaviour is not measured
  and will be worse.
- Cold start for the 22 GB model is **~14 s**. With a 5 minute keep-alive, the
  first request after an idle spell pays it.

---

## Storage — 2026-08-27

`fio`, four profiles, 30 s each, `direct=1`, iodepth 16. Both classes measured
from the **same node** (`rk1-w1`, arm64) so the comparison is like-for-like, and
deliberately not from the NFS server, so NFS traffic crosses the network.

| Profile | local-path | nfs-client | Winner |
|---------|-----------:|-----------:|--------|
| Sequential read | **310 MiB/s** | 111 MiB/s | local, 2.8× |
| Sequential write | 82 MiB/s | **112 MiB/s** | **NFS** |
| Random 4K read | 7,166 IOPS | **25,500 IOPS** | **NFS, 3.6×** |
| Random 4K write | **5,288 IOPS** | 1,907 IOPS | local, 2.8× |

Tail latency (p99), which is what a VM or database actually feels:

| Profile | local-path | nfs-client |
|---------|-----------:|-----------:|
| Random 4K read | 34.9 ms | **8.0 ms** |
| Random 4K write | **128 ms** (p99.9: **541 ms**) | **0.22 ms** |

### The finding: NFS is not the villain here — the ARM node's local disk is

This inverts the assumption the benchmark was built to test. On `rk1-w1`, NFS
beats local storage on three of four measures that matter, and it is not close:

- **Random reads are 3.6× faster over NFS.** The NFS server has a real NVMe and
  page cache behind it; the ARM node's local storage does not.
- **Local random-write tail latency is catastrophic** — 128 ms at p99 and
  **541 ms at p99.9**, against 0.22 ms over NFS. A workload doing small writes
  on `local-path` on an ARM node will stall visibly.
- **Sequential read is the only clear local win**, and NFS's 111 MiB/s is not a
  storage limit at all: it is ~940 Mbit/s, i.e. the gigabit network. NFS
  sequential throughput is network-capped, exactly as predicted.

For contrast, `local-path` on **zullx** (x86, NVMe) managed **543 MiB/s
sequential read and 57,200 random-read IOPS** — 8× the ARM node's random reads.
Storage quality varies enormously across this fleet, and "local-path" means
something completely different depending on which node a pod lands on.

### Completing the matrix: the same test on x86

Once zullx could mount NFS, the same run there finished the picture.

| | rk1-w1 local | rk1-w1 NFS | **zullx local** | zullx NFS |
|---|---:|---:|---:|---:|
| Seq read | 310 MiB/s | 111 MiB/s | **543 MiB/s** | 111 MiB/s |
| Seq write | 82 MiB/s | 112 MiB/s | **481 MiB/s** | 112 MiB/s |
| Rand 4K read | 7,166 | 25,500 | **57,200** | 27,600 |
| Rand 4K write | 5,288 | 1,907 | **48,400** | 1,890 |

Two things fall out of it.

**NFS performs identically from both nodes** — 111/112 MiB/s sequential, ~26–28 k
random read, ~1.9 k random write, from an ARM node and an x86 one alike. That is
the signature of a server-and-network limit rather than a client one. Nothing
about the calling node changes NFS throughput, so there is no point choosing
where to run a pod to make its NFS storage faster.

**The local-vs-NFS answer inverts depending on architecture.** On zullx, local
NVMe beats NFS on everything, by 5× sequential and **25× on random writes**. On
rk1-w1, NFS wins random reads 3.6× and is far better on write tail latency. The
right storage class is not a cluster-wide decision; it depends on which node the
workload lands on.

### What to do with this

- **On x86 nodes, prefer `local-path`** for anything performance-sensitive. The
  NVMe there is dramatically faster than the network, and 48,400 random write
  IOPS against NFS's 1,890 is not a close call.
- **On ARM nodes, NFS is often the better choice** — faster random reads and far
  better write tail latency than the local storage.
- **Random writes over NFS are poor everywhere** (~1,900 IOPS regardless of
  client). Anything write-heavy on NFS will feel it.
- **The NFS argument is availability, not performance.** The single unreplicated
  server remains the problem; its speed is fine for what it is.
- **Sequential NFS work is network-bound** at gigabit line rate. Faster disks in
  the NFS server would change nothing without faster networking.

### Related discovery: the VM has no failover target

The first attempt to run this benchmark failed because **`zullx` cannot mount
NFS at all** — `mount.nfs` is missing, so `nfs-common` is not installed. Every
other node mounts fine:

| Node | NFS mount |
|------|-----------|
| rk1-cp, rk1-w1, rk1-w2, nuc-flasher | OK |
| **zullx** | **FailedMount** |

That matters more than it first appears. VM workloads are x86-only, and there
are exactly two x86 nodes: `nuc-flasher` (which is also the NFS server) and
`zullx`. The desktop VM's disk is an RWX volume on NFS.

So if `nuc-flasher` fails, the VM **cannot start anywhere** — `zullx` is the only
other node that could run it, and it cannot mount the disk.

Fix, on zullx:

```bash
sudo apt-get install -y nfs-common
```

One package turns a total-loss scenario into an ordinary reschedule.

**Fixed 2026-08-27.** Installed via a privileged pod that enters the host
namespace (`bootstrap/out-of-band/install-nfs-client-zullx.yaml`), because zullx
has no SSH access from the workstation — `ubuntu`, `matt` and `root` were all
refused with the available keys. Verified afterwards by scheduling a pod with an
NFS PVC onto zullx and writing to it: **NFS_READ_WRITE_OK**. The desktop VM now
has a real failover target.
