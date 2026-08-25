# Dashboards

`cluster-overview.json` is the Grafana home dashboard — everything worth seeing
about the cluster on one page, at a glance.

## Why it is here

Grafana stores dashboards in its own database on a node-local volume. If that
volume is lost or Grafana is redeployed, hand-made dashboards go with it.
Keeping the JSON in Git makes it recoverable.

## Re-import after a rebuild

```bash
PW=$(kubectl get secret monitoring-grafana -n monitoring \
      -o jsonpath='{.data.admin-password}' | base64 -d)
printf '{"dashboard":' > /tmp/p.json
cat dashboards/cluster-overview.json >> /tmp/p.json
printf ',"overwrite":true,"folderId":0}' >> /tmp/p.json
curl -u "admin:$PW" -H 'Content-Type: application/json' \
     -X POST -d @/tmp/p.json http://<node>:32300/api/dashboards/db
```

Then set it as home:

```bash
curl -u "admin:$PW" -H 'Content-Type: application/json' -X PUT \
  -d '{"homeDashboardUID":"cluster-overview","theme":"dark","timezone":"browser"}' \
  http://<node>:32300/api/org/preferences
```

## Making it fully declarative (optional)

The monitoring chart's Grafana runs a sidecar that loads any ConfigMap labelled
`grafana_dashboard: "1"`. Wrapping this JSON in such a ConfigMap would make it
survive rebuilds with no manual step — at the cost of the dashboard becoming
**read-only in the UI**, since provisioned dashboards cannot be saved over.
Left as a manual import deliberately, so panels stay editable.

## Panel notes

- **Temperature** carries real thresholds (65 / 75 / 85 °C). ARM modules throttle
  around 85 °C, and thermal headroom is the practical ceiling on this hardware far
  more often than CPU capacity.
- **Persistent volume used** matters more than it looks: RWX volumes are served by
  a single NFS node with no replication.
- **Jetson GPU utilisation** is the only GPU panel. The discrete GPU on the x86
  node exports no metrics — see below.
- Node-exporter scrapes **8 hosts**, not 6: the six cluster nodes plus both DNS
  sinkholes, which is why they appear in the per-node panels.

## Known gap

There is no exporter for the discrete GPU on the x86 worker, so its utilisation,
memory and temperature are invisible. Deploying DCGM exporter would close this
and give that node the same coverage the Jetson already has.

## RTX 5090 row

The workstation GPU doing local inference is scraped by `nvidia_gpu_exporter`
running on the workstation itself (`E:\tools\nvidia_gpu_exporter`, port 9835,
launched from the user's Startup folder). Prometheus reaches it via the
ScrapeConfig in `manifests/gpu-workstation-exporter/`.

Two gotchas worth remembering:

- **The `job` label is `scrapeConfig/monitoring/gpu-workstation`**, not
  `gpu-workstation`. Filtering on `job="gpu-workstation"` silently matches
  nothing. Use `host="gpu-workstation"`, which the ScrapeConfig sets explicitly.
- **The target being down is normal.** The workstation is a desktop that sleeps
  and reboots. Down means local inference is unavailable, not that something has
  broken — hosted models keep working. The panels read "workstation offline"
  rather than showing zero, so an absent GPU is never mistaken for an idle one.
