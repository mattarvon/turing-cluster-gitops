#!/usr/bin/env bash
# Apply and verify everything Argo CD cannot manage.
#
# Argo excludes core/Endpoints and discovery/EndpointSlice cluster-wide, so any
# Endpoints object committed under manifests/ is silently ignored while the
# Application still reports Synced. That failure mode is invisible: the Service
# exists, DNS resolves, and requests go nowhere.
#
# Run this after a cluster rebuild, and any time `verify` reports a problem.
#
#   ./bootstrap/apply-out-of-band.sh          # apply, then verify
#   ./bootstrap/apply-out-of-band.sh verify   # check only, changes nothing
set -uo pipefail

KUBECTL=${KUBECTL:-kubectl}
DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-apply}"
fail=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  OK    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

if [ "$MODE" != "verify" ]; then
    say "==> Applying out-of-band resources"
    for f in "$DIR"/out-of-band/*.yaml; do
        say "    $(basename "$f")"
        $KUBECTL apply -f "$f" || bad "could not apply $(basename "$f")"
    done
    say
fi

say "==> Verifying"

# The whole point: a Service with no backing addresses.
addrs=$($KUBECTL get endpoints ollama -n ai -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
if [ -n "$addrs" ]; then
    ok "ai/ollama endpoints -> $addrs"
else
    bad "ai/ollama has NO endpoints - local inference will fail silently."
    bad "      run: $0"
fi

# The Service itself is Argo-managed and should always be there.
if $KUBECTL get svc ollama -n ai >/dev/null 2>&1; then
    ok "ai/ollama Service exists"
else
    bad "ai/ollama Service missing - is the ollama-endpoint Application synced?"
fi

# Secrets are also created out of band and are equally invisible when absent.
if $KUBECTL get secret litellm-secrets -n ai >/dev/null 2>&1; then
    ok "litellm-secrets present"
else
    bad "litellm-secrets missing - LiteLLM cannot reach hosted models."
fi

# Catch the general case, not just the one we know about.
say
say "==> Applications carrying an excluded-resource warning"
warned=$($KUBECTL get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[*].type}{"\n"}{end}' 2>/dev/null \
         | grep -i 'ExcludedResourceWarning' | awk '{print $1}')
if [ -n "$warned" ]; then
    for a in $warned; do
        say "  WARN  $a has resources Argo will never apply - they must live in out-of-band/"
    done
else
    ok "none"
fi

say
if [ "$fail" -eq 0 ]; then
    say "All good."
else
    say "Problems found - see FAIL lines above."
    exit 1
fi
