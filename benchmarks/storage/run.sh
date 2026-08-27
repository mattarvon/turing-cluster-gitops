#!/usr/bin/env bash
# Run the storage benchmark on a named node.
#
# Node was previously hardcoded in the manifests, which meant editing YAML to
# measure a different machine and made it easy to compare two runs that were
# taken on different hardware. It is a parameter now.
#
#   ./run.sh rk1-w1              # both classes
#   ./run.sh zullx local-path    # one class
#
# Both classes must be measured on the SAME node to be comparable, and ideally
# not on the NFS server itself - there the "network" storage is local and the
# numbers mean something else entirely.
set -uo pipefail

KUBECTL=${KUBECTL:-kubectl}
HERE="$(cd "$(dirname "$0")" && pwd)"
NODE="${1:?usage: $0 <node> [local-path|nfs-client|both]}"
WHICH="${2:-both}"
NS=${NS:-default}

nfs_server_node=$($KUBECTL get deploy -n nfs-provisioner -o jsonpath='{.items[0].spec.template.spec.volumes[0].nfs.server}' 2>/dev/null)
if [ -n "${nfs_server_node:-}" ]; then
    ip=$($KUBECTL get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [ "$ip" = "$nfs_server_node" ]; then
        echo "NOTE: $NODE IS the NFS server. Its 'network' storage is local,"
        echo "      so nfs-client numbers here are not comparable to other nodes."
        echo
    fi
fi

run_one() {
    local cls="$1" file="$2" job="$3"
    echo "=================================================="
    echo " $cls on $NODE"
    echo "=================================================="

    $KUBECTL delete job "$job" -n "$NS" --ignore-not-found >/dev/null 2>&1
    $KUBECTL delete pvc "$job" -n "$NS" --ignore-not-found >/dev/null 2>&1
    sleep 3

    sed "s/kubernetes.io\/hostname: .*/kubernetes.io\/hostname: $NODE/" "$HERE/$file" \
      | $KUBECTL apply -f - >/dev/null 2>&1

    if ! $KUBECTL wait --for=condition=complete "job/$job" -n "$NS" --timeout=480s >/dev/null 2>&1; then
        echo "FAILED or timed out. Recent events:"
        $KUBECTL describe pod -n "$NS" -l job-name="$job" 2>/dev/null \
          | grep -A6 'Events:' | tail -6
        $KUBECTL delete job "$job" pvc "$job" -n "$NS" --ignore-not-found >/dev/null 2>&1
        return 1
    fi

    $KUBECTL logs "job/$job" -n "$NS" 2>&1 \
      | grep -E 'storage class|node |read: IOPS|write: IOPS|99.00th'
    echo
    $KUBECTL delete job "$job" -n "$NS" --ignore-not-found >/dev/null 2>&1
    $KUBECTL delete pvc "$job" -n "$NS" --ignore-not-found >/dev/null 2>&1
}

case "$WHICH" in
    local-path) run_one "local-path"  fio-local-path.yaml fio-local-path ;;
    nfs-client) run_one "nfs-client"  fio-nfs.yaml        fio-nfs ;;
    both)
        run_one "local-path" fio-local-path.yaml fio-local-path
        run_one "nfs-client" fio-nfs.yaml        fio-nfs
        ;;
    *) echo "unknown class: $WHICH" >&2; exit 1 ;;
esac

echo "Reminder: 'read: IOPS' lines are sequential then random, in that order."
