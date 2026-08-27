# Benchmarks

Measurements that would change a decision. Anything that only produces an
impressive number is deliberately absent.

| # | What | Why it earns its place | Status |
|---|------|------------------------|--------|
| 1 | [LLM serving](llm/) | The flagship workload, and a baseline that makes regressions visible | **run** |
| 2 | [Storage](storage/) | RWX volumes are on one NFS node; nobody has measured what that costs | ready |
| 3 | [Network](network/) | Bounds NFS and tells you what the CNI costs | ready |
| 4 | [Thermal](thermal/) | The architecture claims thermal is the real ARM ceiling. That is a belief, not a measurement | ready |

Results land in `results/` as timestamped JSON so runs are comparable over time
rather than being numbers that scrolled past in a terminal.

## Before running anything

These are not free. Storage and network tests disturb whatever else is running,
and the thermal soak makes the ARM nodes genuinely hot for the best part of an
hour. Decide whether you want a quiet cluster first.

Every run should record what else was happening — the LLM harness captures GPU
busy state before it starts, for exactly this reason. A benchmark taken while
something else was using the hardware is not comparable to one taken on an idle
box, and six months later you will not remember which it was.

---

## 1 · LLM serving

```bash
./llm/run.sh                                        # default sweep
MODELS=qwen3.6-a3b,llama3.1-local ./llm/run.sh      # compare models
CONCURRENCY=1,2,4,8 REPS=3 ./llm/run.sh             # push harder
```

Runs from a cluster node and reads the LiteLLM key straight out of the Secret,
so no credential is passed on a command line or copied off the cluster.

It measures the **router** path rather than the inference server directly,
because that is the path real requests take. Router overhead is included rather
than assumed away.

**Reading the output.** Compare `gen tok/s` (speed of one stream) against
`aggregate` (total across all streams). If aggregate climbs with concurrency,
requests are genuinely running in parallel. If aggregate stays flat while TTFT
grows, they are queueing. See [results/README.md](results/README.md) for what
this cluster actually does.

The harness always warms the model first and discards that request: pulling a
large model into VRAM takes tens of seconds and is not inference latency.

---

## 2 · Storage

```bash
kubectl apply -f storage/fio-local-path.yaml
kubectl apply -f storage/fio-nfs.yaml
kubectl logs -n default job/fio-local-path -f
```

Same four profiles against each storage class: sequential read, sequential
write, 4K random read, 4K random write. The question being answered is what NFS
actually costs versus node-local disk, which decides whether replicated block
storage is overdue or merely nice to have.

Pay attention to **random 4K latency** rather than sequential throughput. That
is what a VM disk and a database feel, and it is where network storage hurts.

---

## 3 · Network

```bash
kubectl apply -f network/iperf3-server.yaml
# edit the client's nodeSelector, then:
kubectl apply -f network/iperf3-client.yaml
kubectl logs -n default job/iperf3-client -f
```

Pod-to-pod across nodes, which includes CNI overhead. Run it against the node
running the NFS server to get the ceiling that storage numbers sit under — if
the network tops out at 940 Mbit/s, no amount of NFS tuning beats that.

---

## 4 · Thermal

```bash
./thermal/soak.sh rk1-w1 30      # node, minutes
```

Loads every core and watches the temperature climb, then reports whether clocks
fell. Watch the **Temperature by node** panel on the Cluster Overview dashboard
while it runs.

What you are looking for is the point where sustained throughput diverges from
burst throughput. That difference is the real capacity of the node, and it is
the number worth scheduling against.
