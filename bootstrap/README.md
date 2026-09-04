# Bootstrap

Everything here exists because it **cannot** be reconciled by Argo CD. If you are
rebuilding the cluster, the repository alone is not sufficient — this directory
is the rest of the procedure.

## Why out-of-band resources exist at all

Argo CD ships a default `resource.exclusions` list in `argocd-cm` that excludes
`Endpoints` and `EndpointSlice` cluster-wide, to cut watch churn and UI clutter.

The consequence is nastier than it sounds: an Application whose manifests include
an `Endpoints` object reports **Synced and Healthy while never creating it**. The
only trace is an `ExcludedResourceWarning` buried in `.status.conditions`.

For `ai/ollama` that produces a perfect silent failure — the Service exists,
in-cluster DNS resolves, LiteLLM connects happily, and every request goes nowhere.
Local inference is simply gone, with nothing in any dashboard to say why.

```bash
# how to see it
kubectl get application ollama-endpoint -n argocd -o jsonpath='{.status.conditions}'
```

## Rebuild procedure

```bash
# 1. Argo CD itself (installed out-of-band; not managed by any Application)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Secrets - never committed to this public repo
kubectl create secret generic litellm-secrets -n ai \
    --from-literal=ANTHROPIC_API_KEY=... \
    --from-literal=LITELLM_MASTER_KEY=...
# RDP login password for the disposable Kali VM (vms/pentest)
kubectl create namespace vms
kubectl create secret generic pentest-rdp -n vms --from-literal=password=...

# 3. The app-of-apps root; Argo takes over from here
kubectl apply -f bootstrap/root.yaml

# 4. Everything Argo cannot manage, plus a verification pass
./bootstrap/apply-out-of-band.sh
```

## Checking an existing cluster

```bash
./bootstrap/apply-out-of-band.sh verify
```

Changes nothing. Confirms `ai/ollama` actually has backing addresses, the Service
and secret exist, and reports any Application carrying an excluded-resource
warning — so a new instance of this class of problem shows up as a warning rather
than as a mystery outage months later.

Worth running after any cluster surgery, and whenever local models stop
responding for no visible reason.

## The alternatives, and why they were not taken

**Remove `Endpoints` from `resource.exclusions`.** The complete fix: the manifest
under `manifests/` would then be applied normally and self-heal like everything
else. It edits Argo's own cluster-wide configuration, which governs reconciliation
for the entire cluster, so it is a deliberate decision rather than a default.
Keeping `EndpointSlice` excluded would retain most of the churn benefit, since
that is the one Kubernetes auto-creates per Service.

**Use an `ExternalName` Service pointing at `nullx.lan`.** Fully Argo-managed, no
excluded resources, and it would follow DHCP if the workstation's address changed.
Rejected because it makes local inference depend on LAN DNS: a Pi-hole outage
would take the inference path down with it. The hardcoded address keeps those two
failure domains independent.

**Drop the Service indirection and point LiteLLM at the address directly.**
Simplest of all, and genuinely tempting — but it discards the stable in-cluster
name that any future consumer of the GPU would use.

## This has a shelf life

Kubernetes reports `v1 Endpoints is deprecated in v1.33+; use
discovery.k8s.io/v1 EndpointSlice`. This cluster is already past that, so the
object works but is on borrowed time.

The migration is not a straight swap, because **Argo excludes `EndpointSlice`
too** — moving to it changes nothing about the problem this directory exists to
solve. When `Endpoints` is finally removed, the realistic options narrow to:

- removing `EndpointSlice` from `resource.exclusions` so the manifest can live
  under `manifests/` and self-heal, or
- keeping a hand-applied `EndpointSlice` here and carrying on as now.

Worth deciding before the API disappears rather than during an upgrade.
