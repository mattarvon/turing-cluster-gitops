# turing-cluster-gitops

GitOps source of truth for the **Turing Pi 2 K3s cluster**, managed by **Argo CD**
using the *app-of-apps* pattern. (Human docs — architecture, IPs, credentials — live
separately in `C:\Users\matt\turing-cluster\turing-build-doc.md`, which is **not** pushed
here so no plaintext credentials ever land in this repo.)

## Layout
```
bootstrap/root.yaml     app-of-apps root; watches apps/ (recurse=false)
apps/                   Argo Applications that ARE synced (one file per app)
manifests/<app>/        raw Kubernetes YAML each app deploys
staged/                 Applications declared but NOT yet synced (adoption backlog)
```

## Under management now
| App | Kind | Namespace |
|-----|------|-----------|
| gpu-device-plugin | DaemonSet (squat generic-device-plugin) | kube-system |
| ollama-endpoint | selector-less Service + Endpoints → RTX 5090 | ai |

The rest of the cluster (monitoring, NFS, KubeVirt/CDI, Open WebUI, the desktop VM,
exporters) is inventoried in `staged/` and adopted one app at a time — see
`staged/README.md`.

## How it's wired
- Argo CD runs in ns `argocd`, UI on **NodePort 32700** (`http://192.168.1.101:32700`, user `admin`).
- This repo is **private**; Argo pulls it read-only via an SSH **deploy key** (`git@github.com:...`).
- The `root` Application is applied once (bootstrap); everything else flows from git.

## Bootstrap / rebuild
```bash
# 1. install Argo CD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# 2. add this repo's read-only deploy key as an argocd repository secret
# 3. apply the root app-of-apps
kubectl apply -f bootstrap/root.yaml
```

## Add a new app
1. Put its manifests in `manifests/<app>/`.
2. Add an Argo `Application` in `apps/<app>.yaml`.
3. `git push` — Argo syncs it automatically.

## Secrets policy
No plaintext credentials in this repo. Secret-bearing apps are adopted only after
Sealed Secrets / External Secrets is in place, or their Secrets stay applied out-of-band.
