# Staged apps (not yet under Argo control)

These Applications are **declared but intentionally not in `apps/`**, so the app-of-apps
root does NOT sync them yet. They represent the rest of the running cluster, to be adopted
into GitOps one at a time — safely, after verifying the desired manifest matches live.

## How to adopt one
1. For a **Helm** app, capture the exact live values first so adoption causes no churn:
   `helm get values <release> -n <ns> -o yaml` → put under `helm.valuesObject` in its Application.
2. For a **raw** app, export & clean the live manifests into `manifests/<app>/`.
3. Move the Application YAML from `staged/` into `apps/`, commit, push.
4. Watch it in Argo; sync manually the first time; only then enable `automated` sync.

## Remaining inventory to adopt
| App | Type | Namespace | Notes |
|-----|------|-----------|-------|
| monitoring (kube-prometheus-stack 88.1.3) | Helm | monitoring | capture values; Grafana admin pw stays an in-cluster Secret (do NOT commit) |
| nfs-subdir-external-provisioner 4.0.18 | Helm | nfs-provisioner | set NFS server .105 + path in values |
| KubeVirt v1.9.0 + CDI v1.66.0 | raw/operator | kubevirt / cdi | includes the CR patch excluding the Jetson (gpu=true) — capture the CR |
| open-webui | raw | ai | has a PVC + WEBUI_SECRET_KEY Secret — keep secret out of git |
| desktop-vm (KubeVirt VM) | raw | vms | cloud-init contains a lab password; commit only if acceptable |
| pihole-exporter | raw | monitoring | needs Pi-hole password Secret — use Sealed Secrets before committing |
| tegrastats-exporter | raw | monitoring | Jetson GPU metrics; safe to codify (no secret) |

## Secrets policy
No plaintext credentials in this repo. Adopt secret-bearing apps only after installing
**Sealed Secrets** (or External Secrets), or leave their Secrets applied out-of-band and
have Argo manage only the non-secret resources.
