# Turing Pi 2 — K3s Cluster Architecture

Architecture-specific reference for **this** cluster: every component in the mix, how it's
wired, and where it runs. Credentials are **not** in this repo — they live in the local
`turing-cluster/turing-build-doc.md`.

> Snapshot: 2026-08-08. Regenerate the topology with `dot -Tpng docs/topology.dot -o docs/topology.png -Gdpi=150`.

## Topology

![Cluster topology](topology.png)

*Logical topology — GitOps flow, nodes, namespaces/workloads, storage, and external access.*

## Physical architecture

![Physical architecture](architecture.png)

*Physical layer — Turing Pi 2 board, node slots, and the LAN.*

---

## 1. Physical layer

The **Turing Pi 2 (v2.4)** carrier board holds 4 compute modules over an on-board Gigabit switch
(single RJ45 uplink) and a BMC for out-of-band management. The NUC hangs off the same LAN.

| Node | IP | Slot | SoC / CPU | GPU / accel | Arch | RAM | Role · capability |
|------|----|------|-----------|-------------|------|-----|-------------------|
| turingpi (BMC) | 192.168.1.100 | board | Turing Pi 2 v2.4 BMC (fw 2.0.5) | — | — | — | Out-of-band mgmt: per-node power, USB routing, flashing, UART, on-board GbE switch. |
| rk1-cp | 192.168.1.101 | N1 | Rockchip RK3588 (4×A76 + 4×A55) | 6-TOPS NPU (unused) | arm64 | 16 GB | **K3s control plane** — API/scheduler/etcd; hosts the monitoring stack. |
| jetson-gpu | 192.168.1.102 | N2 | NVIDIA Tegra186 Parker (2×Denver2 + 4×A57) | **256-core Pascal GPU, CC 6.2** | arm64 | 4 GB | **GPU worker** — CUDA compute, advertises `nvidia.com/gpu`; CUDA raytracer/fractal renders. |
| rk1-w1 | 192.168.1.103 | N3 | Rockchip RK3588 (8-core) | 6-TOPS NPU (unused) | arm64 | 16 GB | General ARM64 worker. |
| rk1-w2 | 192.168.1.104 | N4 | Rockchip RK3588 (8-core) | 6-TOPS NPU (unused) | arm64 | 16 GB | General ARM64 worker. |
| nuc-flasher | 192.168.1.105 | ext | Intel i7-8559U (4c/8t) | Iris Plus 655 (QuickSync, OpenVINO) | amd64 | 31 GB | x86 worker · **NFS server** (458 GB RWX) · **KubeVirt VM host** · Jetson flash host. |
| zullx | 192.168.1.216 | ext | AMD Ryzen 7 3700X (8c/16t) | **RTX 2070 SUPER (8 GB, TU104)** | amd64 | 62 GB | **x86 GPU worker** — `nvidia.com/gpu` (CUDA/SD/TensorRT); 1 TB M.2 NVMe → `nvme-local` SC. Ubuntu 24.04 / kernel 6.8 (cgroup v2). |

Off-cluster but part of the mix:

| Device | IP | Role |
|--------|----|------|
| AmpliFi router | 192.168.1.1 | gateway · DHCP · hands out Pi-hole as DNS |
| workstation | 192.168.1.110 | Windows daily-driver · **RTX 5090 (32 GB)** running Ollama (LLM API) |
| pihole | 192.168.1.180 | Raspberry Pi 3 · Pi-hole DNS **primary** |
| pihole2 | 192.168.1.181 | Raspberry Pi 3 · Pi-hole DNS **backup** (nebula-sync nightly) |

All infrastructure is statically addressed on 192.168.1.0/24. The Turing Pi 2 board has an
on-board Gigabit switch with a single RJ45 uplink; the four modules share it.

## 2. K3s cluster

- **6 nodes.** Control plane `rk1-cp` on **v1.36.2+k3s1**; workers match, **except the
  Jetson on v1.34.9** (its kernel 4.9 is cgroup v1, which k8s 1.36 removed — kept within kubelet skew).
- **Mixed architecture:** arm64 (RK1s + Jetson) + amd64 (NUC + **zullx**). Use multi-arch images or
  pin arch with `nodeSelector: kubernetes.io/arch: amd64`.
- **API server:** `https://192.168.1.101:6443`.
- **cgroup notes:** NUC switched to cgroup v2 via GRUB `systemd.unified_cgroup_hierarchy=1`; the
  Jetson can't (kernel 4.9), hence its older K3s.

## 3. Namespaces & workloads (full inventory)

| Namespace | Workloads | Notes |
|-----------|-----------|-------|
| **argocd** | argocd-server, repo-server, application-controller (STS), applicationset-controller, redis, dex, notifications | GitOps control plane — see §4 |
| **monitoring** | prometheus (STS), grafana, alertmanager (STS), kube-state-metrics, kube-prometheus-operator, pihole-exporter, node-exporter (DS), process-exporter (DS) | kube-prometheus-stack 88.1.3 + tegrastats-exporter (systemd on Jetson) |
| **ai** | open-webui (Deploy, on NUC) + selector-less `ollama` Service/Endpoints → .110 | LLM chat backed by the RTX 5090 |
| **vms** | desktop-vm (KubeVirt VMI, on NUC) | Ubuntu XFCE desktop over RDP |
| **kubevirt** | virt-operator, virt-api, virt-controller, virt-exportproxy, virt-template-*, virt-handler (DS) | VM runtime; virt-handler excludes the Jetson (no /dev/kvm) |
| **cdi** | cdi-operator, cdi-apiserver, cdi-deployment, cdi-uploadproxy | disk image import for VMs |
| **nfs-provisioner** | nfs-subdir-external-provisioner | owns StorageClass `nfs-client` |
| **kube-system** | traefik (ingress), coredns, metrics-server, local-path-provisioner, headlamp, **nvidia-gpu-device-plugin (DS)** | cluster services + GPU scheduling |

**Helm-managed releases:** monitoring (kube-prometheus-stack 88.1.3), nfs-provisioner (4.0.18),
traefik + traefik-crd (k3s built-in 40.1.x).

## 4. GitOps (Argo CD) — this repo

- **Argo CD** in ns `argocd`, UI on **NodePort 32700** (`http://192.168.1.101:32700`).
- **Source of truth:** this private repo, **app-of-apps** pattern. Argo pulls it read-only via an
  SSH **deploy key**.
- **Flow:** `bootstrap/root.yaml` (watches `apps/`, non-recursive) → `apps/*.yaml` (Argo
  Applications) → `manifests/<app>/` (raw K8s YAML). `staged/` = declared-but-not-synced backlog.
- **Under management now:** `gpu-device-plugin` (Jetson DaemonSet), `ollama-endpoint` (ai Service),
  `gpu-device-plugin-x86` (zullx NVIDIA plugin + RuntimeClass), `nvme-storage` (zullx `nvme-local` SC + PV).
- **Adoption backlog** (`staged/`): monitoring, nfs-provisioner, KubeVirt/CDI, open-webui,
  desktop-vm, pihole-exporter, tegrastats-exporter.

## 5. Storage

| StorageClass | Provisioner | Backing | Modes |
|--------------|-------------|---------|-------|
| local-path (default) | rancher.io/local-path | per-node SSD | RWO |
| nfs-client | nfs-subdir-external-provisioner | NUC .105 `/srv/nfs/k3s` (~458 GB) | RWX, Retain |
| nvme-local | (static local PV, no-provisioner) | zullx .216 M.2 NVMe `/data` (860 GB) | RWO, Retain |

| PVC | Namespace | Class | Size |
|-----|-----------|-------|------|
| prometheus-db | monitoring | local-path | 15 Gi |
| monitoring-grafana | monitoring | local-path | 4 Gi |
| open-webui-data | ai | nfs-client | 5 Gi |
| desktop-vm-disk | vms | nfs-client | 25 Gi |
| big-nfs-pvc | default | nfs-client | 300 Gi (spare RWX) |

 NFS lives on a single disk in the NUC — shared, not replicated; the NUC is a SPOF for RWX volumes.

## 6. GPU

- **Jetson (in-cluster):** `nvidia-gpu-device-plugin` (squat generic-device-plugin) advertises
  `nvidia.com/gpu: 10` on the Jetson (stock NVIDIA plugin can't detect JetPack 4.6). Use with
  `runtimeClassName: nvidia` + `resources.limits: {nvidia.com/gpu: 1}`. **GitOps-managed.**
- **zullx — RTX 2070 SUPER (in-cluster):** official NVIDIA `k8s-device-plugin` (DaemonSet, runs under
  RuntimeClass `nvidia`) advertises `nvidia.com/gpu: 1` on zullx. Real x86 CUDA — Stable Diffusion,
  TensorRT, bigger models than the Jetson. **GitOps-managed** (`gpu-device-plugin-x86`).
- **RTX 5090 (GPU-as-a-service):** the workstation runs Ollama on the LAN; the cluster consumes it
  via the selector-less `ai/ollama` Service → `192.168.1.110:11434`. The rig is **not** a node
  (decoupled from Windows reboots). Open WebUI (ns `ai`) is the front-end. **GitOps-managed** (Service).

## 7. Virtualization

- **KubeVirt v1.9.0** (ns `kubevirt`) + **CDI v1.66.0** (ns `cdi`). `virt-handler` runs on
  KVM-capable nodes (RK1s + NUC) only — the Jetson is excluded via the `kubevirt` CR
  `spec.workloads.nodePlacement` (kernel 4.9 has no `/dev/kvm`).
- **desktop-vm** (ns `vms`): Ubuntu 24.04 XFCE + xrdp, pinned amd64 (NUC), NFS-backed 25 Gi disk,
  reached via **RDP 192.168.1.105:32389**.

## 8. Monitoring

kube-prometheus-stack (ns `monitoring`): Prometheus (15-day / 15 Gi), Grafana (:32300),
Alertmanager, kube-state-metrics. Plus **pihole-exporter** (both Pi-holes), **node-exporter** +
**process-exporter** on every host, and a custom **tegrastats-exporter** (systemd on the Jetson,
:9101) for GPU util/temps. Grafana dashboards: Node Exporter Full, Pi-hole, K8s Views, Named
processes, and a custom *Jetson TX2 NX — GPU & Thermals*.

## 9. Networking & external access

DNS for the whole LAN is served by the redundant Pi-holes (.180 primary, .181 backup, auto-synced
nightly by nebula-sync); the AmpliFi hands out both. In-cluster ingress is **Traefik** (k3s
built-in). Services are exposed via **NodePort** (reachable on any node IP, e.g. .101):

| Service | NodePort |
|---------|----------|
| Argo CD | 32700 |
| Grafana | 32300 |
| Headlamp | 32650 |
| Open WebUI | 32400 |
| desktop-vm (RDP) | 32389 |
| Traefik ingress | 32289 (web) / 30145 (websecure) |

## 10. Component → node placement

- **Control plane** on rk1-cp (.101).
- **Heavy stateful pods** (Prometheus, Grafana, Alertmanager) kept **off** the 4 GB Jetson via
  nodeAffinity (`gpu NotIn true`).
- **amd64-only / VM / NFS-consuming workloads** (open-webui, desktop-vm) pinned to the **NUC**.
- **GPU workloads** land on the **Jetson** (`nvidia.com/gpu`).
- **DaemonSets** (node-exporter, process-exporter, device-plugin, virt-handler) span the
  appropriate node sets.
